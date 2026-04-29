import Foundation
import SwiftUI
import AVFoundation
import WhisperKit
import HumdrumCore

// MARK: - Quality levels (user-facing wrapper around raw Whisper model IDs)

enum QualityLevel: String, CaseIterable, Identifiable {
    case fast, balanced, accurate, best
    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .fast:     return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        case .best:     return "Best"
        }
    }

    var modelId: String {
        switch self {
        case .fast:     return "openai_whisper-tiny.en"
        case .balanced: return "openai_whisper-base.en"
        case .accurate: return "openai_whisper-small.en"
        case .best:     return "openai_whisper-medium.en"
        }
    }

    var sizeDescription: String {
        switch self {
        case .fast:     return "~75 MB"
        case .balanced: return "~145 MB"
        case .accurate: return "~490 MB"
        case .best:     return "~1.5 GB"
        }
    }

    var description: String {
        switch self {
        case .fast:
            return "Near-instant. Good for quick personal notes. Often mangles names, acronyms, and technical terms."
        case .balanced:
            return "Low latency, handles everyday speech well. Decent with common names, still wobbly on unusual ones. A good starting point."
        case .accurate:
            return "Noticeably better with proper nouns, acronyms, and jargon. Uses more CPU / battery. Recommended for work meetings you'll share."
        case .best:
            return "Highest accuracy available locally. Slower to start up and uses significantly more RAM. Reserve for transcripts that really need to be right."
        }
    }
}

// MARK: - Noise filter levels
//
// `NoiseFilterLevel` lives in the pure-logic `HumdrumCore` module so the
// threshold bundles are unit-testable without the full app host. Imported
// at the top of this file.

// MARK: - Transcript commit
//
// A committed slice of transcript with absolute time bounds from the start
// of the recording. These are what the post-stop diarization pass uses to
// attach speaker labels.

struct TranscriptCommit: Identifiable {
    let id = UUID()
    let startTime: Float   // seconds from recording start
    let endTime: Float
    var text: String
    var speakerLabel: String?   // "Speaker 1", "Speaker 2", nil if unlabeled
}

// MARK: - Commit thresholds
//
// How long a Whisper window must grow before we emit a committed chunk.
// Meeting mode prefers fewer chunk boundaries (long monologues read
// better with fewer mid-sentence splits). Dictation mode prefers fast
// feedback so the user sees their words land in the focused field as
// they speak, not in four-second bursts.
//
// These can be swapped at runtime via `TranscriptionManager.commitThresholds`.
struct CommitThresholds: Equatable {
    /// Minimum window duration (seconds) before a commit will fire at
    /// all, regardless of silence. Below this, any "done" signal is
    /// ignored — we'd rather wait for more context than pay the fixed
    /// per-commit cost on a single-word window.
    var minCommitSeconds: Float

    /// Upper bound: when the rolling window reaches this, commit
    /// unconditionally. Caps worst-case latency for a continuous
    /// speaker who never pauses.
    var maxSegmentSeconds: Float

    /// Length of the trailing-silence window we check for "the speaker
    /// just stopped." Shorter = faster commit after a phrase; longer =
    /// fewer mid-phrase cuts.
    var tailSilenceSeconds: Float

    /// Meeting-recording defaults. Biased toward fewer, longer chunks.
    /// `maxSegmentSeconds` was 18 s originally, but a continuous
    /// talker could run the full window between commits and leave a
    /// very large tail for the finalize pass on stop. 12 s is still
    /// comfortably meeting-length but keeps the worst-case tail a
    /// heavier model can reliably finalize inside the 30 s deadline.
    static let meeting = CommitThresholds(
        minCommitSeconds: 2.5,
        maxSegmentSeconds: 12.0,
        tailSilenceSeconds: 1.3
    )

    /// Dictation-mode. Biased toward fast paste feedback — users expect
    /// text to appear within a second or two of finishing a phrase, not
    /// whenever Whisper decides the sentence is "complete."
    static let dictation = CommitThresholds(
        minCommitSeconds: 1.2,
        maxSegmentSeconds: 7.0,
        tailSilenceSeconds: 0.5
    )
}

// MARK: - Manager

@MainActor
final class TranscriptionManager: ObservableObject {

    // MARK: Published state

    @Published var commits: [TranscriptCommit] = []
    @Published var confirmedText: String = ""
    @Published var hypothesisText: String = ""
    @Published var isRecording: Bool = false
    @Published var isLoadingModel: Bool = false
    @Published var isFinalizing: Bool = false
    @Published var status: String = "Initializing…"
    @Published var modelLoaded: Bool = false

    // Settings
    @Published var qualityLevel: QualityLevel = .balanced
    @Published var vocabularyHints: String = ""
    // Off by default: enabling speakers downloads an additional ~80 MB
    // of local diarization models on first use. Opt-in per recording.
    @Published var speakerLabelsEnabled: Bool = false
    @Published var noiseFilterLevel: NoiseFilterLevel = .normal

    // MARK: Audio input selection
    //
    // Global mic choice, shared by meeting recording AND standalone
    // dictation. `nil` means "use the macOS system-default input" —
    // which is the right default behavior for fresh installs and
    // keeps us out of CoreAudio state when the user is happy with
    // their OS setting.
    //
    // The DeviceID type is WhisperKit's alias for CoreAudio's
    // AudioDeviceID (UInt32). We store it in UserDefaults as Int so
    // the plist round-trip is boring.
    @Published var availableInputDevices: [AudioDevice] = []
    @Published var selectedInputDeviceID: DeviceID? = nil {
        didSet {
            let defaults = UserDefaults.standard
            if let id = selectedInputDeviceID {
                defaults.set(Int(id), forKey: Self.selectedInputDeviceKey)
            } else {
                defaults.removeObject(forKey: Self.selectedInputDeviceKey)
            }
        }
    }
    private static let selectedInputDeviceKey = "Humdrum.audio.selectedInputDeviceID"

    @Published var elapsedSeconds: Int = 0

    /// Three audio RMS levels (0...~1.1), with progressively slower smoothing
    /// so the 3-circle visualizer "chases" the current mic energy.
    @Published var audioLevels: [Float] = [0, 0, 0]

    /// Raw (un-boosted, un-smoothed) RMS of the last ~50 ms of audio.
    /// Use this for silence / speech detection — `audioLevels` is the
    /// cosmetic pre-boosted value feeding the visualizer, which is not
    /// comparable against raw-RMS thresholds. Updated by the level loop
    /// at ~30 Hz while recording; reset to 0 on stop/cancel.
    @Published var currentRMS: Float = 0

    /// Fired IMMEDIATELY when recording stops with a speaker-less transcript
    /// plus (if speaker labeling is on) the raw audio + commits needed for
    /// a background diarization job. AppState owns the diarization worker;
    /// the manager is "free" the moment this fires.
    var onSessionCompleted: ((TranscriptSessionSnapshot) -> Void)?

    /// Called after a successful loadModel() completes. Lets the UI
    /// refresh its cached-model state so freshly-downloaded quality
    /// levels flip from "Downloads X MB" → "Cached".
    var onModelLoaded: (() -> Void)?

    /// The last ~one line of transcribed text — used by the floating
    /// recorder widget to show a head-truncated "ticker".
    @Published var currentLine: String = ""

    // MARK: Configuration

    private let sampleRate: Int = 16_000
    private let transcribeIntervalSeconds: TimeInterval = 1.5
    private let tailSilenceRMSThreshold: Float = 0.006

    /// Cadence for "when to flush a committed chunk to `confirmedText`."
    /// Meeting mode uses long, infrequent chunks; dictation mode uses
    /// short, frequent ones so paste feedback lands every ~1–2 s of
    /// speech instead of every 4+ s. `DictationCoordinator` swaps these
    /// on its start/stop boundaries; nothing else should mutate this.
    var commitThresholds: CommitThresholds = .meeting

    /// When false, `start()` skips `startTranscriptionLoop()` — no
    /// live `runStep`/`hitMax` chunked commits during the recording.
    /// Audio still accumulates in the buffer; the level loop and timer
    /// loop still run; `currentRMS` / `audioLevels` still update for the
    /// silence detector and visualizer. The tail finalize on stop
    /// processes the entire buffer as one Whisper pass.
    ///
    /// Used by `DictationCoordinator` for push-to-talk mode: there are
    /// no phase-1 paste commits during a hold, so mid-hold chunking
    /// produces no UX benefit and actively *loses* words at chunk
    /// boundaries (Whisper drops trailing tokens of each 7 s hitMax
    /// chunk because there's no segment-end cue, and the next chunk
    /// starts mid-word). Skipping the loop entirely lets a continuous
    /// 24 s utterance land as one clean transcription on release.
    /// Toggle mode keeps this true so phase-1 commits still flow.
    var liveTranscriptionEnabled: Bool = true

    // MARK: Internal

    private var whisperKit: WhisperKit?
    private var audioProcessor: AudioProcessor?

    private var transcriptionTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?
    /// Timestamp of the last in-place engine restart attempt. Used to
    /// distinguish "config change fired but the engine recovered or
    /// stayed running" from "config change fires repeatedly within the
    /// same second" — the latter signals genuine sustained
    /// reconfiguration (active AirPlay routing, hotplug churn) where a
    /// retry is futile. In that case we surface a status message and
    /// stop instead of fighting the OS.
    private var lastConfigRestartAt: Date?
    private var commitSampleIndex: Int = 0
    private var startedAt: Date?
    private var loadedModelId: String?

    /// The currently-running (or most-recently-completed) tail-pass
    /// finalize task. A new `stop()` schedules one; `start()` /
    /// `loadModel()` await it to keep WhisperKit calls serialized
    /// across session boundaries. Exposed via `pendingFinalize` for
    /// the DictationCoordinator, which needs the tail-pass snapshot
    /// to land before pasting and hiding its overlay (commit-once
    /// pastes the entire transcript in one ⌘V at end of utterance).
    private var lastFinalizeTask: Task<Void, Never>?

    /// Public read-only handle on the in-flight finalize so external
    /// callers (DictationCoordinator) can await it. Nil if nothing
    /// has run yet, or if the last task has already finished.
    var pendingFinalize: Task<Void, Never>? { lastFinalizeTask }

    private var cachedHintText: String = ""
    private var cachedPromptTokens: [Int]?

    // MARK: Init

    init() {
        // Hydrate the persisted mic selection BEFORE the first refresh
        // so the picker lands on the user's last choice on launch. If
        // the stored ID no longer exists (device unplugged since last
        // run), refreshInputDevices() will quietly fall back to nil —
        // meaning "system default" — rather than stranding the user
        // on a phantom device.
        if let raw = UserDefaults.standard.object(forKey: Self.selectedInputDeviceKey) as? Int {
            selectedInputDeviceID = DeviceID(raw)
        }
        refreshInputDevices()
    }

    // MARK: Audio input devices

    /// Re-enumerate the system's audio input devices and prune a
    /// stale selection. Call on init, whenever Settings is opened,
    /// and before starting a recording — CoreAudio doesn't give us a
    /// cheap "device list changed" notification we can rely on, so
    /// re-scanning on demand is the simplest safe option.
    func refreshInputDevices() {
        let devices = AudioProcessor.getAudioDevices()
        availableInputDevices = devices
        // If the previously-selected device is no longer attached
        // (unplugged USB mic, Bluetooth disconnected), drop the
        // selection back to "system default" rather than silently
        // letting WhisperKit fail to find it at start time.
        if let id = selectedInputDeviceID,
           !devices.contains(where: { $0.id == id }) {
            selectedInputDeviceID = nil
        }
    }

    // MARK: Model lifecycle

    func loadModel() async {
        guard !isLoadingModel else { return }
        // Refuse to reload the model while audio is in flight — swapping
        // the underlying WhisperKit instance mid-recording would corrupt
        // the in-progress transcription.
        guard !isRecording else { return }
        // Wait for any in-flight tail-pass finalize to complete before
        // swapping WhisperKit out from under it.
        if let prior = lastFinalizeTask {
            _ = await prior.value
        }
        let targetModel = qualityLevel.modelId
        if modelLoaded && loadedModelId == targetModel { return }

        isLoadingModel = true
        modelLoaded = false
        status = "Preparing “\(qualityLevel.shortLabel)” model… (first run downloads \(qualityLevel.sizeDescription))"

        let loadStart = Date()
        Diagnostics.engine.info("model.load.begin model=\(targetModel, privacy: .public)")

        do {
            let config = WhisperKitConfig(
                model: targetModel,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit
            if self.audioProcessor == nil {
                self.audioProcessor = AudioProcessor()
            }
            self.loadedModelId = targetModel
            self.modelLoaded = true
            self.cachedHintText = ""
            self.cachedPromptTokens = nil
            self.onModelLoaded?()

            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            Diagnostics.engine.info(
                "model.load.ok model=\(targetModel, privacy: .public) ms=\(loadMs)"
            )

            // Exercise the Core ML compute graph with a tiny silent
            // buffer so the user's first real ⌥Space press doesn't pay
            // the cold-ANE tax. Without this, the model is nominally
            // "loaded" but the first transcribe still costs ~1–2 s on a
            // freshly-launched app while Core ML JITs into the ANE
            // caches. Status flips to "Warming up" so the user knows
            // why "Ready" is delayed by another half-second or so.
            self.status = "Warming up the model…"
            await self.prewarmInference()

            self.status = "Ready (\(qualityLevel.shortLabel)). Click Start to record."
        } catch {
            Diagnostics.engine.error(
                "model.load.failed model=\(targetModel, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
            self.status = "Model load failed: \(error.localizedDescription)"
        }
        isLoadingModel = false
    }

    /// Push a tiny silent buffer through WhisperKit so the Core ML
    /// graph for the encoder/decoder is JIT'd into the ANE caches before
    /// the user's first real transcribe. Idempotent — safe to call
    /// repeatedly. Called automatically at the end of `loadModel()` and
    /// again from `HumdrumApp` on `NSWorkspace.didWakeNotification`,
    /// because waking from sleep tends to drop ANE residency.
    ///
    /// Logs elapsed wall time to `Diagnostics.engine`. No-op when no
    /// model is loaded or when a recording is in flight (we don't want
    /// to race a real transcribe). Failures are logged, never surfaced
    /// to the user — a missed warmup means the next real press is a bit
    /// slower, not broken.
    func prewarmInference() async {
        guard let kit = whisperKit, modelLoaded, !isRecording else { return }

        // 1 second of silence. Whisper's encoder pads to 30 s
        // internally, so the actual ANE compute is the same regardless
        // of how short we go — the goal here is just to exercise the
        // graph once. 1 s is the smallest size where WhisperKit reliably
        // produces a result without short-circuiting the pipeline.
        let silentBuffer = [Float](repeating: 0, count: sampleRate)
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )

        let start = Date()
        do {
            _ = try await kit.transcribe(audioArray: silentBuffer, decodeOptions: options)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Diagnostics.engine.info(
                "prewarm.inference.ok model=\(self.loadedModelId ?? "?", privacy: .public) ms=\(ms)"
            )
        } catch {
            Diagnostics.engine.error(
                "prewarm.inference.failed model=\(self.loadedModelId ?? "?", privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Recording lifecycle

    func start() async {
        Diagnostics.engine.info(
            "recording.start.requested modelLoaded=\(self.modelLoaded, privacy: .public) isRecording=\(self.isRecording, privacy: .public) isLoadingModel=\(self.isLoadingModel, privacy: .public) liveTx=\(self.liveTranscriptionEnabled, privacy: .public)"
        )
        guard modelLoaded else {
            Diagnostics.engine.error("recording.start.refused reason=model_not_loaded")
            status = "Model not loaded yet."
            return
        }
        guard !isRecording else {
            Diagnostics.engine.notice("recording.start.refused reason=already_recording")
            return
        }
        guard !isLoadingModel else {
            Diagnostics.engine.notice("recording.start.refused reason=loading_model")
            status = "Still loading model…"
            return
        }
        // The previous session's tail-pass finalize may still be in
        // flight — it runs off the manager's critical path so the UI
        // unlocked immediately. Await it here because (a) we need to
        // serialize WhisperKit calls so the next session's runStep
        // doesn't race the tail transcribe, and (b) on the happy path
        // it completes in a few hundred ms, which is invisible to the
        // user compared to the old behavior of blocking at `stop()`.
        if let prior = lastFinalizeTask {
            Diagnostics.engine.info("recording.start.awaiting_prior_finalize")
            status = "Wrapping up last session…"
            _ = await prior.value
        }

        let granted = await ensureMicrophoneAccess()
        guard granted else {
            Diagnostics.permissions.error("recording.start.refused reason=mic_denied")
            status = "Microphone access denied. Open System Settings → Privacy & Security → Microphone, enable Humdrum, then try again. If it isn't listed, run: tccutil reset Microphone com.aaronellis.humdrum"
            return
        }

        // Recreate the AudioProcessor on every start so its rolling
        // `audioSamples` buffer begins empty. Without this, a second
        // session inherits every float from the previous one — the
        // transcription loop then dutifully re-runs Whisper on all
        // that stale audio before catching up to current speech,
        // which presents to the user as a multi-minute hang on the
        // second (or Nth) recording. Cheap to recreate; WhisperKit's
        // AudioProcessor is a thin AVAudioEngine wrapper.
        audioProcessor?.stopRecording()
        let processor = AudioProcessor()
        self.audioProcessor = processor

        // Re-probe the device list so a stale pick made while the
        // device was unplugged gets cleared before we hand the ID
        // off to AudioProcessor (which would otherwise error out).
        refreshInputDevices()

        do {
            try processor.startRecordingLive(inputDeviceID: selectedInputDeviceID) { _ in }
            commitSampleIndex = 0
            commits = []
            confirmedText = ""
            hypothesisText = ""
            elapsedSeconds = 0
            startedAt = Date()
            isRecording = true
            status = "Recording…"

            if liveTranscriptionEnabled {
                startTranscriptionLoop()
            }
            startTimerLoop()
            startLevelLoop()
            startStallWatchdog()
            lastConfigRestartAt = nil
            installAudioConfigChangeObserver(on: processor.audioEngine)
            // Probe AVAudioEngine state immediately after start so we
            // can tell from a log whether the tap was wired up (engine
            // running, input format reporting a real sample rate +
            // channel count) versus the silent-failure case where
            // start() succeeded but no frames will ever flow.
            let engineRunning = processor.audioEngine?.isRunning ?? false
            let inputFmt = processor.audioEngine?.inputNode.inputFormat(forBus: 0)
            Diagnostics.engine.info(
                "recording.start.ok device=\(self.selectedInputDeviceID.map(String.init) ?? "default", privacy: .public) liveTx=\(self.liveTranscriptionEnabled, privacy: .public) noiseFilter=\(self.noiseFilterLevel.rawValue, privacy: .public) engineRunning=\(engineRunning, privacy: .public) inputSampleRate=\(inputFmt?.sampleRate ?? 0, privacy: .public) inputChannels=\(inputFmt?.channelCount ?? 0, privacy: .public)"
            )
        } catch {
            Diagnostics.engine.error(
                "recording.start.failed err=\(error.localizedDescription, privacy: .public)"
            )
            status = "Could not start mic: \(error.localizedDescription). Grant microphone permission in System Settings → Privacy & Security → Microphone."
        }
    }

    func stop() async {
        guard isRecording else {
            Diagnostics.engine.notice("recording.stop.refused reason=not_recording")
            return
        }
        Diagnostics.engine.info(
            "recording.stop.requested elapsedSec=\(self.elapsedSeconds, privacy: .public) commits=\(self.commits.count, privacy: .public) confirmedChars=\(self.confirmedText.count, privacy: .public)"
        )

        // Tear down the LIVE pipeline immediately so the UI gate
        // (`isBusy`) flips false and the user can start a new session
        // without waiting for the trailing Whisper pass to finish.
        isRecording = false
        transcriptionTask?.cancel()
        timerTask?.cancel()
        levelTask?.cancel()
        watchdogTask?.cancel()
        transcriptionTask = nil
        timerTask = nil
        levelTask = nil
        watchdogTask = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioProcessor?.stopRecording()
        audioLevels = [0, 0, 0]
        currentRMS = 0

        // Capture everything the tail pass + snapshot need so it can
        // run AFTER the manager has already reset its live state.
        // `audioProcessor` and `whisperKit` are retained inside the
        // captured locals but cleared (processor) / shared (kit) on
        // `self` so the next `start()` gets a clean processor and
        // reuses the same model.
        let capturedKit = whisperKit
        let capturedProcessor = audioProcessor
        let capturedCommits = commits
        let capturedCommitSampleIndex = commitSampleIndex
        let capturedStartedAt = startedAt ?? Date()
        let capturedElapsed = elapsedSeconds
        let capturedSpeakers = speakerLabelsEnabled
        let capturedHints = vocabularyHints
        let capturedFilter = noiseFilterLevel
        let capturedQuality = qualityLevel
        let capturedCallback = onSessionCompleted
        // Last live Whisper output that hadn't yet crossed the
        // silence/hitMax commit threshold. Handed to the finalize path
        // as a fallback so a timed-out or failing tail transcribe
        // doesn't silently lose whatever Whisper already produced.
        let capturedHypothesis = hypothesisText

        audioProcessor = nil

        // Live-session view state resets NOW — users see an empty
        // transcript pane while the tail pass runs. The snapshot (when
        // it arrives) contains the complete final text.
        commits = []
        commitSampleIndex = 0
        hypothesisText = ""
        confirmedText = ""
        currentLine = ""
        elapsedSeconds = 0
        startedAt = nil

        // Flag the tail pass as in-flight for status display and for
        // `clear()`. NOT part of `isBusy` — the user can record a new
        // session while this runs. The detached task below will clear
        // the flag when it hops back to main.
        isFinalizing = true
        status = "Finalizing transcript…"

        // Chain after any prior finalize so two back-to-back sessions
        // don't invoke WhisperKit concurrently (its `transcribe` is
        // not documented as reentrant-safe).
        let prior = lastFinalizeTask
        let task = Task.detached { [weak self] in
            _ = await prior?.value
            let result = await Self.runFinalizeOffMain(
                kit: capturedKit,
                processor: capturedProcessor,
                startingCommits: capturedCommits,
                commitSampleIndex: capturedCommitSampleIndex,
                sampleRate: 16_000,
                startedAt: capturedStartedAt,
                elapsedSeconds: capturedElapsed,
                speakerLabelsEnabled: capturedSpeakers,
                vocabularyHints: capturedHints,
                noiseFilter: capturedFilter,
                quality: capturedQuality,
                fallbackHypothesis: capturedHypothesis
            )
            await MainActor.run { [weak self] in
                self?.isFinalizing = false
                // Don't clobber a newer status the user may have set
                // (e.g. they started a new recording while finalize
                // was running — `status` already reads "Recording…").
                // On finalize timeout/failure, surface the reason in
                // status so the user knows why the tail may be the
                // last live hypothesis rather than a fresh pass.
                if self?.status == "Finalizing transcript…" {
                    self?.status = result.warning ?? "Transcript ready."
                }
                capturedCallback?(result.snapshot)
            }
        }
        lastFinalizeTask = task
    }

    // MARK: Off-thread finalize

    /// Value returned by `runFinalizeOffMain`. `warning` is non-nil
    /// when the tail transcribe didn't produce fresh text — either the
    /// 30 s deadline elapsed, or WhisperKit threw — and the stop path
    /// used the captured `hypothesisText` to keep the tail from
    /// vanishing. The main-actor caller surfaces it on `status` so the
    /// user sees why the last sentence may look partial.
    fileprivate struct FinalizeResult {
        let snapshot: TranscriptSessionSnapshot
        let warning: String?
    }

    /// Runs the trailing Whisper pass on the captured audio and builds
    /// the session snapshot. Pure: takes everything by value, touches
    /// no @MainActor state. The caller (a detached Task inside
    /// `stop()`) hops back to main after this returns to flip
    /// `isFinalizing` and fire the onCompleted callback.
    ///
    /// Deadline: the tail transcribe is raced against a 30-second
    /// sleep so a hung WhisperKit call can't strand the user forever.
    /// The earlier 10 s cap was too tight — a long continuous utterance
    /// could leave 10+ seconds of tail audio, which a heavier model on
    /// modest hardware doesn't always finish in under 10 s. When the
    /// deadline fires we fall back to `fallbackHypothesis` (the last
    /// successful live transcribe that hadn't yet committed) so the
    /// user doesn't lose the trailing sentence entirely.
    ///
    /// This function is the whole reason Stop → Start feels instant
    /// now: it runs entirely off-main, the 230 MB audio copy for
    /// diarization happens here (not on main during stop), and the
    /// snapshot construction doesn't hold the main actor either.
    nonisolated fileprivate static func runFinalizeOffMain(
        kit: WhisperKit?,
        processor: AudioProcessor?,
        startingCommits: [TranscriptCommit],
        commitSampleIndex: Int,
        sampleRate: Int,
        startedAt: Date,
        elapsedSeconds: Int,
        speakerLabelsEnabled: Bool,
        vocabularyHints: String,
        noiseFilter: NoiseFilterLevel,
        quality: QualityLevel,
        fallbackHypothesis: String
    ) async -> FinalizeResult {
        var finalCommits = startingCommits
        var warning: String? = nil

        // Snapshot `audioSamples` once — reads from a stopped
        // AudioProcessor are stable. If the processor is nil
        // (shouldn't happen on the stop path) we skip the tail pass
        // and emit whatever commits we already have.
        let allSamples = processor?.audioSamples ?? []

        // Appends a final commit covering the range [commitSampleIndex,
        // allSamples.count). Used both on the happy path (fresh tail
        // transcribe) and the fallback path (captured hypothesis).
        func appendTailCommit(_ text: String) {
            let cleaned = sanitizeStatic(text, noiseFilter: noiseFilter)
            guard !cleaned.isEmpty else { return }
            let startSec = Float(commitSampleIndex) / Float(sampleRate)
            let endSec = Float(allSamples.count) / Float(sampleRate)
            finalCommits.append(TranscriptCommit(
                startTime: startSec,
                endTime: endSec,
                text: cleaned
            ))
        }

        if let kit,
           allSamples.count > commitSampleIndex + sampleRate / 2 {

            let window = Array(allSamples[commitSampleIndex..<allSamples.count])

            // Noise-filter gate — if the tail window is silence under
            // the current filter threshold, skip the whole transcribe.
            var shouldTranscribe = true
            if noiseFilter != .off {
                let floor = noiseFilter.rmsFloor
                if floor > 0, rmsOf(window) < floor {
                    shouldTranscribe = false
                }
            }

            if shouldTranscribe {
                let options = buildDecodingOptionsOffMain(
                    vocabularyHints: vocabularyHints,
                    noiseFilter: noiseFilter,
                    kit: kit
                )

                // Pad with 0.5 s of synthetic silence so Whisper sees
                // a clear segment-end cue. Without this, push-to-talk
                // release runs the tail transcribe on a buffer that
                // ends mid-word — Whisper's segment-boundary heuristic
                // never trips and the call returns empty text, so the
                // user holds ⌥Space, speaks, releases, and nothing
                // pastes. Toggle mode already has 6 s of natural
                // trailing silence in the buffer (auto-stop only fires
                // after that), so the padding is redundant there but
                // harmless: Whisper's encoder pads to 30 s internally
                // and the extra ~8 000 floats cost nothing on the ANE.
                // RMS gating above is computed on the unpadded `window`
                // so the noise floor still rejects pure-silence tails.
                let paddedWindow = window + [Float](
                    repeating: 0,
                    count: sampleRate / 2
                )

                // Three possible outcomes from the raced task group:
                // fresh Whisper text, WhisperKit throw, or 30 s
                // deadline. Distinguishing timed-out vs. failed lets
                // the user-facing warning be specific. `Sendable`
                // because the value crosses task boundaries via the
                // group's return type.
                enum TailOutcome: Sendable {
                    case text(String)
                    case failed
                    case timedOut
                }

                let outcome: TailOutcome = await withTaskGroup(of: TailOutcome.self) { group in
                    group.addTask {
                        do {
                            let results = try await kit.transcribe(
                                audioArray: paddedWindow,
                                decodeOptions: options
                            )
                            if let raw = results.first?.text {
                                return .text(raw)
                            }
                            return .failed
                        } catch {
                            return .failed
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        return .timedOut
                    }
                    let first = await group.next() ?? .failed
                    group.cancelAll()
                    return first
                }

                switch outcome {
                case .text(let raw):
                    appendTailCommit(raw)
                case .timedOut:
                    // Use the last live hypothesis so the trailing
                    // utterance isn't silently dropped. Better to ship
                    // Whisper's most recent best-effort reading of the
                    // tail than to chop the transcript mid-sentence.
                    appendTailCommit(fallbackHypothesis)
                    warning = "Finalize timed out after 30 s — kept the last live partial for the tail."
                case .failed:
                    appendTailCommit(fallbackHypothesis)
                    warning = "Finalize failed — kept the last live partial for the tail."
                }
            }
        }

        // Build the transcript text + audio copy off-main.
        let transcriptText = renderCommitsStatic(finalCommits)
        let audioCopy: [Float] = speakerLabelsEnabled ? Array(allSamples) : []

        let snapshot = TranscriptSessionSnapshot(
            createdAt: startedAt,
            durationSeconds: elapsedSeconds,
            transcriptText: transcriptText,
            quality: quality.rawValue,
            noiseFilter: noiseFilter.rawValue,
            speakerLabelsEnabled: speakerLabelsEnabled,
            vocabularyHints: vocabularyHints,
            audioSamples: audioCopy,
            commits: speakerLabelsEnabled ? finalCommits : []
        )
        return FinalizeResult(snapshot: snapshot, warning: warning)
    }

    /// Nonisolated twin of `buildDecodingOptionsStatic` — same body,
    /// no `self` so it can be called from the detached finalize task
    /// without hopping to main.
    nonisolated private static func buildDecodingOptionsOffMain(
        vocabularyHints: String,
        noiseFilter: NoiseFilterLevel,
        kit: WhisperKit
    ) -> DecodingOptions {
        let prompt = vocabularyHints.trimmingCharacters(in: .whitespacesAndNewlines)
        var promptTokens: [Int]? = nil

        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            let prepared = " " + prompt
            let tokens = tokenizer.encode(text: prepared)
            let specialBegin = tokenizer.specialTokens.specialTokenBegin
            promptTokens = tokens.filter { $0 < specialBegin }
        }

        return DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            suppressBlank: noiseFilter != .off,
            compressionRatioThreshold: noiseFilter.compressionRatioThreshold,
            logProbThreshold: noiseFilter.logProbThreshold,
            noSpeechThreshold: noiseFilter.noSpeechThreshold
        )
    }

    func clear() {
        guard !isRecording && !isFinalizing else { return }
        commits = []
        confirmedText = ""
        hypothesisText = ""
        commitSampleIndex = 0
        elapsedSeconds = 0
    }

    /// Abort the current recording without saving. Skips finalize, does
    /// not emit `onSessionCompleted`, resets manager state so a new
    /// session can start immediately. Fast path — we deliberately don't
    /// run the trailing Whisper pass because the output is about to be
    /// thrown away. Safe to call while `isRecording` is false (no-op).
    ///
    /// Used by the recorder widget's close-X button, where the user has
    /// explicitly chosen to discard.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        transcriptionTask?.cancel()
        timerTask?.cancel()
        levelTask?.cancel()
        watchdogTask?.cancel()
        transcriptionTask = nil
        timerTask = nil
        levelTask = nil
        watchdogTask = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioProcessor?.stopRecording()
        audioLevels = [0, 0, 0]
        currentRMS = 0

        // Drop everything. No snapshot, no callback — the session
        // ceases to exist as far as the rest of the app is concerned.
        commits = []
        commitSampleIndex = 0
        hypothesisText = ""
        confirmedText = ""
        currentLine = ""
        elapsedSeconds = 0
        startedAt = nil
        status = "Recording discarded."
    }

    // MARK: Transcription loop

    private func startTranscriptionLoop() {
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                await self.runStep()
                try? await Task.sleep(nanoseconds: UInt64(self.transcribeIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func startTimerLoop() {
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isRecording {
                if let started = self.startedAt {
                    self.elapsedSeconds = Int(Date().timeIntervalSince(started))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// 30 Hz loop that reads recent mic audio, computes RMS, and feeds three
    /// differently-smoothed levels to the audio visualizer.
    private func startLevelLoop() {
        levelTask = Task { @MainActor [weak self] in
            // Per-circle smoothing (alpha for an exponential moving average).
            // Circle 1 reacts quickly; Circle 3 slowly — creates the chase.
            let alphas: [Float] = [0.55, 0.30, 0.16]
            // One-shot diagnostic flags so we log a single line each
            // time the audio buffer first gains samples and the first
            // time RMS exceeds the noise floor — pinpoints whether
            // AVAudioEngine actually delivered frames after a `.ok`
            // start, without spamming the log every 33 ms tick.
            var loggedFirstSamples = false
            var loggedFirstAudible = false
            let startedTickAt = Date()
            while !Task.isCancelled, let self, self.isRecording {
                if let processor = self.audioProcessor {
                    let samples = processor.audioSamples
                    let windowSize = self.sampleRate / 20   // 50 ms
                    if !loggedFirstSamples && !samples.isEmpty {
                        let waitMs = Int(Date().timeIntervalSince(startedTickAt) * 1000)
                        Diagnostics.engine.info(
                            "audio.first_samples count=\(samples.count, privacy: .public) afterMs=\(waitMs, privacy: .public)"
                        )
                        loggedFirstSamples = true
                    }
                    if samples.count >= windowSize {
                        let tail = samples.suffix(windowSize)
                        var sumSq: Float = 0
                        for x in tail { sumSq += x * x }
                        let rms = (sumSq / Float(tail.count)).squareRoot()
                        // Expose the raw value so callers (e.g. the
                        // dictation silence monitor) can reason about
                        // speech/silence against real mic levels rather
                        // than the boosted visualizer ones.
                        self.currentRMS = rms
                        if !loggedFirstAudible && rms >= 0.005 {
                            Diagnostics.engine.info(
                                "audio.first_audible rms=\(rms, privacy: .public) sampleCount=\(samples.count, privacy: .public)"
                            )
                            loggedFirstAudible = true
                        }
                        // Speech RMS is typically ~0.01–0.15; boost to 0…1 range.
                        let normalized = min(1.1, rms * 14)
                        var updated = self.audioLevels
                        for i in 0..<3 {
                            updated[i] = updated[i] * (1 - alphas[i]) + normalized * alphas[i]
                        }
                        self.audioLevels = updated
                    }
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    /// Detects "engine running but no audio frames are arriving" — the
    /// silent failure mode we hit when AVAudioEngine's tap dies without
    /// surfacing an error. Common triggers: AirPlay starting (system
    /// reroutes audio), input device unplugged, OS-side mic mute.
    /// Notification-based recovery via `installAudioConfigChangeObserver`
    /// catches the explicit cases; this watchdog is the catch-all.
    ///
    /// Polls `audioSamples.count` every 3 s. If the count hasn't grown
    /// across 3 consecutive ticks (~9 s of dead air while we believe
    /// we're recording), logs `audio.stalled`. Doesn't try to auto-
    /// recover yet — the goal here is visibility; the user should see
    /// the failure in logs and we'll add UI surfacing when we have a
    /// repro to validate against.
    private func startStallWatchdog() {
        watchdogTask = Task { @MainActor [weak self] in
            var lastCount: Int = 0
            var stagnantTicks: Int = 0
            var stalledLogged = false
            while !Task.isCancelled, let self, self.isRecording {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.isRecording else { break }
                let current = self.audioProcessor?.audioSamples.count ?? 0
                if current > lastCount {
                    lastCount = current
                    stagnantTicks = 0
                    if stalledLogged {
                        Diagnostics.engine.notice(
                            "audio.recovered samples=\(current, privacy: .public)"
                        )
                        stalledLogged = false
                    }
                    continue
                }
                stagnantTicks += 1
                if stagnantTicks >= 3 && !stalledLogged {
                    let engineRunning = self.audioProcessor?.audioEngine?.isRunning ?? false
                    Diagnostics.engine.error(
                        "audio.stalled samples=\(current, privacy: .public) engineRunning=\(engineRunning, privacy: .public) elapsedSec=\(self.elapsedSeconds, privacy: .public)"
                    )
                    stalledLogged = true
                }
            }
        }
    }

    /// Listen for `AVAudioEngineConfigurationChange` on the active
    /// engine. macOS posts this when audio device routing changes mid-
    /// recording (AirPlay, device plug/unplug, sample-rate switch).
    /// AVAudioEngine STOPS itself when this fires, so we have to
    /// rebuild our recording session if we want to keep capturing.
    ///
    /// First pass: log the event, attempt a clean restart by recreating
    /// the AudioProcessor and re-running the level/transcription loops.
    /// If the restart fails, the watchdog above will surface a stall
    /// shortly after.
    private func installAudioConfigChangeObserver(on engine: AVAudioEngine?) {
        guard let engine else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                // Grace period before deciding the engine is dead.
                // AVAudioEngine often emits this notification during
                // normal route negotiation (typically settles within
                // ~150–250 ms of any engine start, plus on output route
                // changes), and the engine briefly reports !isRunning
                // mid-settle before recovering on its own. Forcing a
                // restart in that window races with the system's own
                // recovery and produces FormatNotSupported (-10868).
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard self.isRecording else { return }
                self.handleAudioConfigChange()
            }
        }
    }

    /// Config-change handler called *after* the 250 ms grace period in
    /// the observer block (see `installAudioConfigChangeObserver`).
    /// By the time we run, the system has had a chance to settle.
    ///
    /// Behaviour:
    ///   • If the existing engine recovered on its own → nothing to do.
    ///   • If still stopped → recreate the whole AudioProcessor and
    ///     re-tap. In-place `engine.start()` reliably trips
    ///     `kAudioUnitErr_FormatNotSupported (-10868)` when the system
    ///     is still mid-reconfigure; a fresh AVAudioEngine queries the
    ///     now-settled hardware format and binds against it cleanly.
    ///   • Cap to one recreate per second so a routing-storm scenario
    ///     (sustained AirPlay activation, USB hotplug churn) doesn't
    ///     produce an infinite loop. Second failure → give up and
    ///     surface the failure pill.
    private func handleAudioConfigChange() {
        guard let oldEngine = audioProcessor?.audioEngine else { return }

        // Engine self-recovered — typical when the change is purely
        // output-side (BT speaker swap, headphone jack, etc.).
        if oldEngine.isRunning {
            return
        }

        // Already restarted recently — assume sustained reconfig and
        // bail rather than thrash.
        if let last = lastConfigRestartAt, Date().timeIntervalSince(last) < 1.0 {
            Diagnostics.engine.error(
                "audio.configChange — engine stopped again within 1 s; giving up"
            )
            stopWithStatusMessage("Audio devices changed — recording stopped.")
            return
        }
        lastConfigRestartAt = Date()

        Diagnostics.engine.error(
            "audio.configChange — engine stopped, recreating audio processor"
        )

        audioProcessor?.stopRecording()
        let processor = AudioProcessor()
        self.audioProcessor = processor
        do {
            try processor.startRecordingLive(inputDeviceID: selectedInputDeviceID) { _ in }
            // Re-install the observer on the NEW engine — the old
            // observer is bound to a now-defunct engine instance and
            // will never fire again. Clear it explicitly first to
            // avoid leaking observers across recreations.
            if let obs = configChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                configChangeObserver = nil
            }
            installAudioConfigChangeObserver(on: processor.audioEngine)
            Diagnostics.engine.info("audio.configChange.restarted")
        } catch {
            Diagnostics.engine.error(
                "audio.configChange.restartFailed err=\(error.localizedDescription, privacy: .public)"
            )
            stopWithStatusMessage("Audio devices changed — recording stopped.")
        }
    }

    /// Sets a status string the recorder widget surfaces, then stops
    /// recording on the main actor. Called on irrecoverable audio
    /// errors (config change loop, hardware unplug). Uses `stop()`
    /// rather than `cancel()` so any audio captured before the failure
    /// gets finalized + saved as a session.
    private func stopWithStatusMessage(_ message: String) {
        status = message
        Task { @MainActor [weak self] in
            await self?.stop()
        }
    }

    private func runStep() async {
        guard let whisperKit, let audioProcessor else { return }

        let allSamples = audioProcessor.audioSamples
        let availableCount = allSamples.count - commitSampleIndex
        guard availableCount > sampleRate else { return } // need at least 1s

        let window = Array(allSamples[commitSampleIndex..<allSamples.count])

        // Noise pre-filter: if the whole window is effectively silence under
        // the selected filter level, skip transcription and trim the buffer
        // so we don't keep re-processing the same silent audio.
        if noiseFilterLevel != .off {
            let floor = noiseFilterLevel.rmsFloor
            if floor > 0 {
                let windowRMS = rms(of: window)
                if windowRMS < floor {
                    hypothesisText = ""
                    // Keep the last 0.5s in case speech is just starting.
                    let keep = sampleRate / 2
                    if window.count > keep * 3 {
                        commitSampleIndex = allSamples.count - keep
                    }
                    return
                }
            }
        }

        let windowDuration = Float(window.count) / Float(sampleRate)
        let options = buildDecodingOptions()

        do {
            let results = try await whisperKit.transcribe(
                audioArray: window,
                decodeOptions: options
            )
            let text = sanitize(results.first?.text)
            hypothesisText = text
            updateCurrentLine()

            let tailSilent = detectTailSilence(samples: window)
            let longEnough = windowDuration >= commitThresholds.minCommitSeconds
            let hitMax = windowDuration >= commitThresholds.maxSegmentSeconds

            if !text.isEmpty && ((tailSilent && longEnough) || hitMax) {
                let reason = hitMax ? "hitMax" : "tailSilent"
                Diagnostics.engine.info(
                    "runStep.commit chars=\(text.count, privacy: .public) windowSec=\(windowDuration, privacy: .public) reason=\(reason, privacy: .public)"
                )
                appendCommit(text: text, endingSampleIndex: allSamples.count)
                commitSampleIndex = allSamples.count
                hypothesisText = ""
                renderConfirmedText()
            }
        } catch is CancellationError {
            // Normal at end-of-recording — the loop's transcribe call
            // is cancelled when the user (or coordinator) calls stop().
            // Don't escalate that to an error in the log.
        } catch {
            Diagnostics.engine.error(
                "runStep.transcribe.failed err=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func finalizeRemaining() async {
        guard let whisperKit, let audioProcessor else { return }
        let allSamples = audioProcessor.audioSamples
        guard allSamples.count > commitSampleIndex + sampleRate / 2 else {
            hypothesisText = ""
            renderConfirmedText()
            return
        }
        let window = Array(allSamples[commitSampleIndex..<allSamples.count])

        if noiseFilterLevel != .off {
            let floor = noiseFilterLevel.rmsFloor
            if floor > 0 && rms(of: window) < floor {
                hypothesisText = ""
                renderConfirmedText()
                return
            }
        }

        let options = buildDecodingOptions()
        do {
            let results = try await whisperKit.transcribe(
                audioArray: window,
                decodeOptions: options
            )
            let text = sanitize(results.first?.text)
            if !text.isEmpty {
                appendCommit(text: text, endingSampleIndex: allSamples.count)
                commitSampleIndex = allSamples.count
            }
            hypothesisText = ""
            renderConfirmedText()
        } catch {
            hypothesisText = ""
            renderConfirmedText()
        }
    }

    // MARK: Rendering

    private func renderConfirmedText() {
        if commits.isEmpty {
            confirmedText = ""
            updateCurrentLine()
            return
        }

        var out = ""
        var currentLabel: String? = "__none__"   // sentinel so first commit starts a block

        for c in commits {
            if c.speakerLabel != currentLabel {
                if !out.isEmpty { out += "\n\n" }
                if let label = c.speakerLabel {
                    out += "\(label): \(c.text)"
                } else {
                    out += c.text
                }
                currentLabel = c.speakerLabel
            } else {
                out += " " + c.text
            }
        }

        confirmedText = out
        updateCurrentLine()
    }

    /// Computes the short ticker string shown in the floating recorder.
    /// Falls back to the hypothesis when nothing has been committed yet.
    private func updateCurrentLine() {
        let haystack = (confirmedText + " " + hypothesisText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if haystack.isEmpty {
            currentLine = ""
            return
        }
        // Strip a leading "Speaker N: " prefix if present, then take the
        // last sentence fragment (or last ~90 chars).
        var text = haystack
        if let r = text.range(of: "Speaker\\s+\\d+:\\s*", options: .regularExpression) {
            text = String(text[r.upperBound...])
        }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let latest = parts.last ?? text
        currentLine = String(latest.suffix(90))
    }

    // MARK: Permissions

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: Decoding options / vocabulary hints

    private func buildDecodingOptions() -> DecodingOptions {
        let prompt = vocabularyHints.trimmingCharacters(in: .whitespacesAndNewlines)
        var promptTokens: [Int]? = nil

        if !prompt.isEmpty, let tokenizer = whisperKit?.tokenizer {
            if prompt == cachedHintText, let cached = cachedPromptTokens {
                promptTokens = cached
            } else {
                let prepared = " " + prompt
                let tokens = tokenizer.encode(text: prepared)
                let specialBegin = tokenizer.specialTokens.specialTokenBegin
                let contentTokens = tokens.filter { $0 < specialBegin }
                cachedHintText = prompt
                cachedPromptTokens = contentTokens
                promptTokens = contentTokens
            }
        }

        // Named args must appear in declaration order in Swift; `promptTokens`
        // sits before `suppressBlank` in WhisperKit's DecodingOptions init.
        return DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            suppressBlank: noiseFilterLevel != .off,
            compressionRatioThreshold: noiseFilterLevel.compressionRatioThreshold,
            logProbThreshold: noiseFilterLevel.logProbThreshold,
            noSpeechThreshold: noiseFilterLevel.noSpeechThreshold
        )
    }

    // MARK: Audio helpers

    private func appendCommit(text: String, endingSampleIndex: Int) {
        let startSec = Float(commitSampleIndex) / Float(sampleRate)
        let endSec = Float(endingSampleIndex) / Float(sampleRate)
        commits.append(TranscriptCommit(startTime: startSec, endTime: endSec, text: text))
    }

    private func detectTailSilence(samples: [Float]) -> Bool {
        let tailCount = Int(Float(sampleRate) * commitThresholds.tailSilenceSeconds)
        guard samples.count >= tailCount + sampleRate else { return false }
        let tail = samples.suffix(tailCount)
        return rms(of: Array(tail)) < tailSilenceRMSThreshold
    }

    private func rms(of samples: [Float]) -> Float {
        Self.rmsOf(samples)
    }

    /// Static RMS used by the off-thread finalize path. Same math as
    /// `rms(of:)` but callable without a main-actor hop.
    fileprivate nonisolated static func rmsOf(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for x in samples { sumSq += x * x }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// Static sanitizer used by the off-thread finalize path.
    /// Mirrors `sanitize(_:)` exactly — filter-off returns the raw
    /// trimmed input, filter-on drops known Whisper silence
    /// hallucinations.
    fileprivate nonisolated static func sanitizeStatic(
        _ raw: String?,
        noiseFilter: NoiseFilterLevel
    ) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if noiseFilter == .off { return t }
        let lower = t.lowercased()
        let bannedExact: Set<String> = [
            "thanks for watching.",
            "thanks for watching!",
            "thank you for watching.",
            "thank you for watching!",
            "thank you.",
            "thanks.",
            "please subscribe.",
            "subtitles by the amara.org community",
            "you",
            ".",
            "♪",
            "[music]",
            "[silence]",
            "(music)",
            "(silence)"
        ]
        if bannedExact.contains(lower) { return "" }
        return t
    }

    /// Static version of the transcript renderer used by the finalize
    /// task. Identical output to `renderConfirmedText`'s — speaker
    /// prefix per block when labels exist, plain text otherwise.
    fileprivate nonisolated static func renderCommitsStatic(_ commits: [TranscriptCommit]) -> String {
        if commits.isEmpty { return "" }
        var out = ""
        var currentLabel: String? = "__none__"
        for c in commits {
            if c.speakerLabel != currentLabel {
                if !out.isEmpty { out += "\n\n" }
                if let label = c.speakerLabel {
                    out += "\(label): \(c.text)"
                } else {
                    out += c.text
                }
                currentLabel = c.speakerLabel
            } else {
                out += " " + c.text
            }
        }
        return out
    }

    /// Strips Whisper's well-known silence hallucinations (only when a filter
    /// level is active). We're deliberately conservative — only drop if the
    /// ENTIRE output is one of these phrases.
    private func sanitize(_ raw: String?) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if noiseFilterLevel == .off { return t }
        let lower = t.lowercased()
        let bannedExact: Set<String> = [
            "thanks for watching.",
            "thanks for watching!",
            "thank you for watching.",
            "thank you for watching!",
            "thank you.",
            "thanks.",
            "please subscribe.",
            "subtitles by the amara.org community",
            "you",
            ".",
            "♪",
            "[music]",
            "[silence]",
            "(music)",
            "(silence)"
        ]
        if bannedExact.contains(lower) { return "" }
        return t
    }

    // MARK: View helpers

    var fullTranscript: String {
        let c = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if hypothesisText.isEmpty { return c }
        return c.isEmpty ? hypothesisText : "\(c) \(hypothesisText)"
    }

    var hasContent: Bool {
        !confirmedText.isEmpty || !hypothesisText.isEmpty
    }

    var elapsedString: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// True whenever something blocks the user from starting a new
    /// recording right now. Deliberately excludes:
    ///   • diarization — runs on a self-contained snapshot in AppState
    ///     and doesn't touch the manager.
    ///   • finalize (the tail Whisper pass after Stop) — now runs on a
    ///     detached Task off the manager's critical path. The next
    ///     `start()` awaits it internally, so the UI doesn't need to.
    /// Only live recording and model loading actually block the pipeline.
    var isBusy: Bool {
        isRecording || isLoadingModel
    }

    /// True if the currently-selected quality doesn't match the model we
    /// have loaded. Used by the Setup window to decide whether hitting
    /// Start needs to pause for a reload first.
    var needsReload: Bool {
        !modelLoaded || loadedModelId != qualityLevel.modelId
    }

    /// A short label explaining *why* we're busy. Nil when we're free.
    /// Intentionally doesn't mention finalize — finalize runs off the
    /// critical path and doesn't flip `isBusy`, so any caller reading
    /// `busyReason` is asking about the live pipeline specifically.
    var busyReason: String? {
        if isRecording    { return "Recording…" }
        if isLoadingModel { return "Loading model…" }
        return nil
    }
}

// MARK: - Snapshot handed to the SessionStore

/// Plain value the manager emits when a session finishes. The view layer
/// turns this into a `TranscriptSession` and persists it. If speaker
/// labeling was enabled, `audioSamples` + `commits` carry everything the
/// background diarization worker needs to later rewrite the transcript —
/// so the manager itself can reset and serve a new recording immediately.
struct TranscriptSessionSnapshot {
    let createdAt: Date
    let durationSeconds: Int
    let transcriptText: String
    let quality: String
    let noiseFilter: String
    let speakerLabelsEnabled: Bool
    let vocabularyHints: String

    /// Audio captured for this session (16 kHz mono). Only populated if
    /// the caller may want to diarize later; otherwise empty.
    let audioSamples: [Float]
    /// The sentence-level commits with their time ranges.
    let commits: [TranscriptCommit]
}

