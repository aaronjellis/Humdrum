import Foundation
import SwiftUI
import AVFoundation
import WhisperKit

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

enum NoiseFilterLevel: String, CaseIterable, Identifiable {
    case off, light, normal, strict
    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .off:    return "Off"
        case .light:  return "Light"
        case .normal: return "Normal"
        case .strict: return "Strict"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Transcribe everything Whisper outputs, including music tags, typing, coughs, and occasional \"Thanks for watching\" hallucinations during silence."
        case .light:
            return "Skip dead silence only. Most borderline audio (typing, HVAC, paper shuffling) still shows up as text."
        case .normal:
            return "Skip silence and suppress Whisper's common hallucinations during quiet stretches. Good default for meetings."
        case .strict:
            return "Aggressively drop anything that doesn't look like clear speech. May cut quiet voices — use only if background noise is severe."
        }
    }

    /// Minimum RMS for a window to even be sent to Whisper.
    var rmsFloor: Float {
        switch self {
        case .off:    return 0
        case .light:  return 0.002
        case .normal: return 0.004
        case .strict: return 0.008
        }
    }

    var noSpeechThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return 0.6
        case .normal: return 0.55
        case .strict: return 0.4
        }
    }

    var compressionRatioThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return 2.8
        case .normal: return 2.4
        case .strict: return 2.0
        }
    }

    var logProbThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return -1.5
        case .normal: return -1.0
        case .strict: return -0.6
        }
    }
}

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
    private let maxSegmentSeconds: Float = 18.0
    private let tailSilenceSeconds: Float = 1.3
    private let tailSilenceRMSThreshold: Float = 0.006
    private let minCommitSeconds: Float = 2.5

    // MARK: Internal

    private var whisperKit: WhisperKit?
    private var audioProcessor: AudioProcessor?

    private var transcriptionTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var commitSampleIndex: Int = 0
    private var startedAt: Date?
    private var loadedModelId: String?

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
        guard !isRecording, !isFinalizing else { return }
        let targetModel = qualityLevel.modelId
        if modelLoaded && loadedModelId == targetModel { return }

        isLoadingModel = true
        modelLoaded = false
        status = "Preparing “\(qualityLevel.shortLabel)” model… (first run downloads \(qualityLevel.sizeDescription))"

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
            self.status = "Ready (\(qualityLevel.shortLabel)). Click Start to record."
            self.cachedHintText = ""
            self.cachedPromptTokens = nil
            self.onModelLoaded?()
        } catch {
            self.status = "Model load failed: \(error.localizedDescription)"
        }
        isLoadingModel = false
    }

    // MARK: Recording lifecycle

    func start() async {
        guard modelLoaded else {
            status = "Model not loaded yet."
            return
        }
        guard !isRecording else { return }
        // Finalize is brief (the last Whisper pass on the trailing audio).
        // We still can't start a new recording *during* it because we'd
        // clobber the shared audio buffer and WhisperKit instance.
        // Diarization, however, runs entirely off the manager now — we
        // don't block on it.
        guard !isFinalizing else {
            status = "Still finalizing the previous transcript…"
            return
        }
        guard !isLoadingModel else {
            status = "Still loading model…"
            return
        }

        let granted = await ensureMicrophoneAccess()
        guard granted else {
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

            startTranscriptionLoop()
            startTimerLoop()
            startLevelLoop()
        } catch {
            status = "Could not start mic: \(error.localizedDescription). Grant microphone permission in System Settings → Privacy & Security → Microphone."
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        isFinalizing = true
        transcriptionTask?.cancel()
        timerTask?.cancel()
        levelTask?.cancel()
        transcriptionTask = nil
        timerTask = nil
        levelTask = nil
        audioProcessor?.stopRecording()
        audioLevels = [0, 0, 0]

        status = "Finalizing transcript…"
        await finalizeRemaining()

        // Always render the speaker-less transcript first so the view
        // layer can show it immediately.
        renderConfirmedText()

        // Capture the ENTIRE session as a self-contained snapshot before
        // we reset state, so that AppState can diarize later while the
        // manager is already busy with the next recording.
        let snapshot = TranscriptSessionSnapshot(
            createdAt: startedAt ?? Date(),
            durationSeconds: elapsedSeconds,
            transcriptText: confirmedText,
            quality: qualityLevel.rawValue,
            noiseFilter: noiseFilterLevel.rawValue,
            speakerLabelsEnabled: speakerLabelsEnabled,
            vocabularyHints: vocabularyHints,
            audioSamples: speakerLabelsEnabled
                ? Array(audioProcessor?.audioSamples ?? [])
                : [],
            commits: speakerLabelsEnabled ? commits : []
        )

        // Reset the manager's in-memory state so the next recording starts
        // clean. The snapshot is self-contained and doesn't share storage.
        commits = []
        commitSampleIndex = 0
        hypothesisText = ""
        confirmedText = ""
        currentLine = ""
        elapsedSeconds = 0
        startedAt = nil

        isFinalizing = false
        status = "Transcript ready."
        onSessionCompleted?(snapshot)
    }

    func clear() {
        guard !isRecording && !isFinalizing else { return }
        commits = []
        confirmedText = ""
        hypothesisText = ""
        commitSampleIndex = 0
        elapsedSeconds = 0
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
            while !Task.isCancelled, let self, self.isRecording {
                if let processor = self.audioProcessor {
                    let samples = processor.audioSamples
                    let windowSize = self.sampleRate / 20   // 50 ms
                    if samples.count >= windowSize {
                        let tail = samples.suffix(windowSize)
                        var sumSq: Float = 0
                        for x in tail { sumSq += x * x }
                        let rms = (sumSq / Float(tail.count)).squareRoot()
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
            let longEnough = windowDuration >= minCommitSeconds
            let hitMax = windowDuration >= maxSegmentSeconds

            if !text.isEmpty && ((tailSilent && longEnough) || hitMax) {
                appendCommit(text: text, endingSampleIndex: allSamples.count)
                commitSampleIndex = allSamples.count
                hypothesisText = ""
                renderConfirmedText()
            }
        } catch {
            // transient; try again next tick
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
        let tailCount = Int(Float(sampleRate) * tailSilenceSeconds)
        guard samples.count >= tailCount + sampleRate else { return false }
        let tail = samples.suffix(tailCount)
        return rms(of: Array(tail)) < tailSilenceRMSThreshold
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for x in samples { sumSq += x * x }
        return (sumSq / Float(samples.count)).squareRoot()
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
    /// recording right now. Note: diarization is deliberately excluded —
    /// it runs on a self-contained snapshot in AppState and doesn't touch
    /// the manager. Live recording, finalize, and model loading *do* need
    /// exclusive access to the pipeline.
    var isBusy: Bool {
        isRecording || isFinalizing || isLoadingModel
    }

    /// True if the currently-selected quality doesn't match the model we
    /// have loaded. Used by the Setup window to decide whether hitting
    /// Start needs to pause for a reload first.
    var needsReload: Bool {
        !modelLoaded || loadedModelId != qualityLevel.modelId
    }

    /// A short label explaining *why* we're busy. Nil when we're free.
    var busyReason: String? {
        if isRecording    { return "Recording…" }
        if isFinalizing   { return "Finalizing transcript…" }
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

