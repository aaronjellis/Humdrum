import Foundation
import SwiftUI
import Combine
import AppKit
import AVFoundation
import Carbon.HIToolbox
import HumdrumCore

/// Orchestrates Whisper Flow-style dictation, commit-once.
///
///   Press ⌥Space → orb appears centered on screen → speak → after
///   `silenceTimeoutSeconds` of silence the countdown ring drains and
///   we immediately stop, finalize, and paste the entire transcript
///   into the focused field as a single ⌘V. The orb then visually
///   winds down (scales 1.0 → 0 over another `silenceTimeoutSeconds`)
///   purely as a courtesy fade — the engine is already stopped and
///   the paste has already landed by then. Speaking during the
///   countdown resets the timer; speaking during the post-paste fade
///   does not — at that point you'd press ⌥Space to start a new
///   dictation. The user's complaint that drove this design was "the
///   text appears too late": commit-at-phase-1-end means the user
///   sees their text the moment the ring drains, not silenceTimeout
///   seconds later.
///
/// Text goes in via clipboard + ⌘V. See `PasteHelper` for the
/// rationale (short version: ⌘V is the OS-blessed insertion event
/// every mainstream target accepts, where synthetic unicode key
/// events get silently filtered by Electron renderers).
///
/// Why commit-once instead of paste-as-you-go: the streaming-paste
/// path used to fire one clipboard write + ⌘V per Whisper commit,
/// which produced overlapping pasteboard restores that raced with
/// Electron's lazy clipboard reads. On long dictations the receiver
/// would consistently land on the *restored* clipboard contents and
/// nothing would paste at all. Every shipping competitor (Wispr
/// Flow, Superwhisper, VoiceInk, Aqua Voice) pastes exactly once at
/// end of utterance for the same reason; see
/// `docs/mutter-paste-research.md` for the receipts.
///
/// Uses the shared TranscriptionManager but temporarily overrides its
/// session-completion callback + settings so dictations aren't saved as
/// sessions and don't get speaker labels.
@MainActor
final class DictationCoordinator: ObservableObject {

    // MARK: - Published

    @Published private(set) var isDictating: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false

    /// Timestamp of the most recent successful paste into the focused
    /// field. The overlay watches this to flash a short ring-pulse
    /// around the orb when paste lands — under the new commit-once
    /// cadence this fires exactly once per dictation, on success, at
    /// the moment the final transcript is delivered to the focused
    /// field. The orb's existing pulse animation handles either one
    /// or many triggers gracefully, so we get a single satisfying
    /// confirmation flash for free.
    @Published private(set) var lastChunkPastedAt: Date?

    /// Outcome of the most recent dictation's paste, surfaced to the
    /// overlay's status pill. Defaults to `.succeeded` so the UI
    /// stays clean before the user has dictated anything; flipped
    /// inside `stop()` after the paste completes and (for `.inserted`
    /// results) the post-paste AX verification runs.
    @Published private(set) var pasteOutcome: PasteOutcome = .succeeded

    /// Timestamp of the most recent detected speech. Drives several
    /// things in the overlay:
    ///   • The silence-countdown ring drains over `silenceTimeoutSeconds`
    ///     (phase 1). When elapsed reaches `silenceTimeoutSeconds`
    ///     the silence monitor fires `stop()` — that's when paste
    ///     lands.
    ///   • The post-paste wind-down (phase 2) keeps using this anchor
    ///     to drive the orb's 1.0 → 0 scale: by the time stop()'s
    ///     linger is running, `lastSpeechTime` is frozen and elapsed
    ///     keeps growing past `silenceTimeoutSeconds`, so the
    ///     scale function naturally animates the fade.
    ///   • The Listening… indicator inside the orb checks freshness
    ///     against this anchor — fades in fast when it's recent,
    ///     fades out within ~400ms once silence resumes.
    @Published private(set) var lastSpeechTime: Date?

    /// Timestamp of the current dictation session's start. Exposed so
    /// the overlay can render the no-speech-yet countdown before the
    /// user has said their first word.
    @Published private(set) var sessionStartedAt: Date?

    /// Master switch controlled from Settings. When false, the global
    /// hotkey is unregistered entirely and dictation can't be triggered.
    /// Persisted in UserDefaults so it survives launches.
    @Published var hotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: Self.hotkeyEnabledKey)
            applyHotkeyRegistration()
        }
    }

    // MARK: - Persisted keys

    private static let hotkeyEnabledKey = "Humdrum.dictation.hotkeyEnabled"
    private static let silenceTimeoutKey = "Humdrum.dictation.silenceTimeout"

    // MARK: - Config

    /// How long a continuous silent stretch triggers auto-stop (in
    /// seconds). Only counts *after* the user has said something.
    @Published var silenceTimeoutSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(silenceTimeoutSeconds, forKey: Self.silenceTimeoutKey)
        }
    }
    /// How long we wait for speech after activation before giving up
    /// (so hitting the hotkey by accident doesn't leave an orb onscreen
    /// forever).
    var noSpeechTimeoutSeconds: TimeInterval = 8.0
    /// Raw-RMS cutoff below which we consider the last 50 ms of mic
    /// audio "silence." Compared against `manager.currentRMS`, which
    /// publishes the un-boosted mic energy directly — do NOT compare
    /// this against `manager.audioLevels` (those are visualizer-
    /// boosted by 14× and will never cross this threshold in real
    /// room conditions, which is why the silence auto-stop never
    /// fired before). 0.015 is a decent "normal speaker in a normal
    /// room" boundary; quieter rooms may want lower.
    var silenceRMSThreshold: Float = 0.015

    // MARK: - Dependencies

    private let manager: TranscriptionManager
    private let overlay = DictationOverlayController()
    private let hotkey = HotkeyManager()

    // MARK: - Session state

    private var savedOnCompleted: ((TranscriptSessionSnapshot) -> Void)?
    private var savedSpeakerLabels: Bool = false
    private var savedNoiseFilter: NoiseFilterLevel = .normal
    private var savedVocabHints: String = ""
    private var savedCommitThresholds: CommitThresholds = .meeting

    private var silenceTask: Task<Void, Never>?
    private var tccObserver: NSObjectProtocol?
    private var accessibilityPollTimer: Timer?

    // MARK: - Init

    init(manager: TranscriptionManager) {
        self.manager = manager
        self.accessibilityGranted = PasteHelper.accessibilityEnabled()

        // Hydrate persisted settings with sensible defaults.
        let defaults = UserDefaults.standard
        self.hotkeyEnabled = defaults.object(forKey: Self.hotkeyEnabledKey) as? Bool ?? true
        self.silenceTimeoutSeconds =
            defaults.object(forKey: Self.silenceTimeoutKey) as? Double ?? 2.5

        // Listen for the Accessibility TCC change notification so the
        // UI flips from "not granted" → "granted" the instant the user
        // toggles our row in System Settings, without app relaunch.
        tccObserver = DistributedNotificationCenter
            .default()
            .addObserver(
                forName: Notification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // The notification queue is `.main`, but the closure is
                // still nonisolated — hop to @MainActor explicitly so
                // `refreshAccessibilityStatus()` (which is main-actor-
                // bound) can be called without tripping the strict
                // concurrency diagnostic.
                Task { @MainActor [weak self] in
                    self?.refreshAccessibilityStatus()
                }
            }

        // Notification fires only on TCC database changes, which doesn't
        // catch the stale-signature case (rebuild after ad-hoc sign).
        // Poll every 2 s as a safety net — cheap syscall, runs forever.
        accessibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityStatus()
            }
        }
    }

    // MARK: - Hotkey wiring

    /// Called once at app launch. Applies the persisted `hotkeyEnabled`
    /// value — registers the binding if on, unregisters if off.
    func installHotkey() {
        applyHotkeyRegistration()
    }

    private func applyHotkeyRegistration() {
        hotkey.unregister()
        guard hotkeyEnabled else { return }
        hotkey.register(
            keyCode: HotkeyManager.Key.space,
            modifiers: HotkeyManager.Modifier.option.rawValue
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.toggle()
            }
        }
    }

    /// Asks for Accessibility permission and updates `accessibilityGranted`.
    /// Used by the Settings window when the user clicks the fix-it button.
    func requestAccessibilityPermission() {
        accessibilityGranted = PasteHelper.accessibilityEnabled(prompt: true)
    }

    /// Silent check — no system prompt. Used by the Settings UI to
    /// refresh permission state without bugging the user.
    func refreshAccessibilityStatus() {
        accessibilityGranted = PasteHelper.accessibilityEnabled()
    }

    /// Per-session reminder flag so we don't re-nag a user who has
    /// explicitly said "start anyway" on this launch. They'll see the
    /// pill on the overlay, which is enough ongoing signal.
    private static var _nudgeSuppressedThisLaunch: Bool = false

    private static func permissionNudgeSuppressed() -> Bool {
        _nudgeSuppressedThisLaunch
    }

    /// Blocking alert presented on first start when Accessibility isn't
    /// granted. Returns true if the user chooses "Start Anyway" — the
    /// orb will still appear and listen, but nothing will land in the
    /// focused field until they grant permission. Returns false if
    /// they canceled or opted to open Settings, which aborts start.
    private func promptAccessibilityAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Humdrum can't paste into the focused field"
        alert.informativeText = """
            Dictation needs Accessibility permission to place text into the app you're typing in. \
            Without it the orb will still listen and transcribe — but nothing will land in the focused field.

            Open System Settings → Privacy & Security → Accessibility and enable Humdrum.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Start Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Open Settings and cancel this start — the user can hit
            // ⌥Space again once they've flipped the toggle; by then
            // the TCC notification observer will have refreshed state.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return false
        case .alertSecondButtonReturn:
            // Start Anyway — honor their choice and stop re-nagging
            // for the rest of this launch. The overlay pill remains
            // visible so they still see the warning.
            Self._nudgeSuppressedThisLaunch = true
            return true
        default:
            return false
        }
    }

    /// Shells out to `tccutil reset Accessibility <bundleID>` to clear
    /// any stale TCC grant for this app, then immediately triggers the
    /// macOS Accessibility grant prompt so the user can re-authorize.
    /// Without the second step, the user lands in an empty Privacy
    /// Settings pane with no pending request.
    func resetAccessibilityPermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aaronellis.humdrum"
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Accessibility", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("tccutil reset failed: \(error)")
        }
        // Fire the system prompt so macOS adds a fresh pending request
        // that the user can approve.
        _ = PasteHelper.accessibilityEnabled(prompt: true)
        refreshAccessibilityStatus()
    }

    // MARK: - Toggle

    /// Start dictation if idle; stop it if already running. The hotkey
    /// calls this. Refuses to start if the manager is busy with a
    /// meeting recording / finalize.
    func toggle() async {
        if isDictating {
            await stop(reason: .hotkey)
        } else {
            await start()
        }
    }

    // MARK: - Start

    private func start() async {
        // Don't piggy-back on a meeting recording.
        guard !manager.isBusy else {
            NSSound.beep()
            return
        }

        // Re-check Accessibility; show prompt if needed. The system
        // prompt only fires the first time — subsequent starts just
        // read the current TCC decision.
        accessibilityGranted = PasteHelper.accessibilityEnabled(prompt: true)

        // If the user still isn't granted (either they ignored the
        // system prompt, or this app's TCC row is stale after a
        // rebuild), give them a blocking, actionable alert instead of
        // starting dictation that would silently fail to paste. This
        // is the "bounces but no text" fix — the failure mode was
        // invisible, so users had no idea what to do.
        if !accessibilityGranted,
           !Self.permissionNudgeSuppressed(),
           !promptAccessibilityAlert() {
            return
        }

        pasteOutcome = .succeeded
        lastSpeechTime = nil
        lastChunkPastedAt = nil
        sessionStartedAt = Date()

        // Show the orb IMMEDIATELY so the user gets feedback, even if
        // we need a few seconds to load the model first. The overlay
        // observes `self` so the missing-permission pill appears/
        // disappears in real time if the user flips Accessibility on
        // while the orb is already up.
        isDictating = true
        overlay.show(DictationOverlayView(manager: manager, dictation: self))

        // Ensure the Whisper model is loaded before we start recording.
        // Without this, manager.start() silently no-ops when it was
        // never loaded — which is why the first ⌥Space press never
        // pasted anything.
        if manager.needsReload {
            await manager.loadModel()
        }
        guard manager.modelLoaded else {
            // Load failed — drop the overlay and bail.
            isDictating = false
            overlay.hide()
            return
        }

        // Save everything we're about to override, so we can restore on
        // stop and keep the meeting flow unaffected.
        savedOnCompleted = manager.onSessionCompleted
        savedSpeakerLabels = manager.speakerLabelsEnabled
        savedNoiseFilter = manager.noiseFilterLevel
        savedVocabHints = manager.vocabularyHints
        savedCommitThresholds = manager.commitThresholds

        // Clear the manager's session-completion callback for the
        // duration of dictation. Dictations aren't meetings — they
        // don't get persisted as sessions. We re-install a one-shot
        // callback inside `stop()`'s continuation flow to capture the
        // final tail-pass snapshot for paste; that callback is
        // self-cleanup and the production handler is restored before
        // we return to the meeting flow.
        manager.onSessionCompleted = nil
        manager.speakerLabelsEnabled = false
        manager.noiseFilterLevel = .strict
        // Switch the manager's commit cadence to "dictation": short
        // windows, tight tail-silence. Even though paste happens once
        // at end-of-utterance, the tighter cadence keeps the tail
        // Whisper pass cheap so `stop()` finalizes quickly.
        manager.commitThresholds = .dictation

        // Reset the session anchor now that the model is actually
        // ready — otherwise a slow first-time model download would
        // burn the entire 8 s no-speech budget before the user could
        // say anything, and dictation would auto-stop on the very
        // first silence-monitor tick.
        sessionStartedAt = Date()

        startSilenceMonitor()
        await manager.start()

        // Surface a mic-denied / device-error up front instead of
        // letting the user stare at the orb for 8 seconds waiting for
        // the no-speech timeout. If isRecording didn't flip true,
        // manager.start() aborted — status carries the human-readable
        // reason — so we tear the overlay down, restore settings, and
        // beep. The user sees the manager's status string in the main
        // window next time they open it.
        if !manager.isRecording {
            isDictating = false
            silenceTask?.cancel()
            silenceTask = nil
            manager.onSessionCompleted = savedOnCompleted
            manager.speakerLabelsEnabled = savedSpeakerLabels
            manager.noiseFilterLevel = savedNoiseFilter
            manager.vocabularyHints = savedVocabHints
            manager.commitThresholds = savedCommitThresholds
            overlay.hide()
            NSSound.beep()
            // If permission was the issue, flip macOS over to the right
            // settings pane — same move as the menu-bar helper. Users
            // on a denied state otherwise have no discoverable path to
            // fix it without reopening the main window.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Stop

    enum StopReason {
        case hotkey
        case silenceTimeout
        case noSpeechTimeout
    }

    private func stop(reason: StopReason) async {
        guard isDictating else { return }
        isDictating = false

        silenceTask?.cancel()
        silenceTask = nil

        // Capture the final snapshot via a single-await continuation.
        // Three things race inside it:
        //   1. We install a one-shot `onSessionCompleted` callback
        //      that resumes the continuation with the snapshot.
        //   2. We arm a 5s safety timeout that resumes with `nil`.
        //   3. We kick off `manager.stop()`, which ultimately fires
        //      the callback after the tail Whisper pass completes.
        // Whichever resolves first wins; the loser is a no-op via the
        // single-resume latch. The 5s deadline is intentionally
        // tighter than the manager's own 30s finalize budget — that
        // budget exists for meeting-mode windows; dictation-mode
        // segments cap at 7s so the tail pass finalizes well under
        // a second on the happy path. We'd rather paste whatever
        // confirmedText reads than strand the orb on screen.
        let snapshot: TranscriptSessionSnapshot? = await withCheckedContinuation {
            (cont: CheckedContinuation<TranscriptSessionSnapshot?, Never>) in

            let latch = SingleResumeLatch<TranscriptSessionSnapshot?>(continuation: cont)

            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                latch.resume(nil)
            }

            manager.onSessionCompleted = { snap in
                timeout.cancel()
                latch.resume(snap)
            }

            Task { @MainActor [weak self] in
                await self?.manager.stop()
            }
        }

        // Resolve the final text. Prefer the snapshot's transcript
        // (which includes anything that only landed via the tail pass);
        // fall back to live `confirmedText` if the snapshot timed out.
        // Trim trailing whitespace — Whisper sometimes leaves a
        // hanging space after the last token, and we don't want
        // that landing in the user's focused field.
        let rawText = snapshot?.transcriptText ?? manager.confirmedText
        let finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if finalText.isEmpty {
            // User hit ⌥Space twice with nothing said, or speech
            // didn't pass Whisper's confidence threshold. Treat as
            // trivial success so the failure pill doesn't fire.
            pasteOutcome = .succeeded
        } else {
            // Snapshot the focused element's character count *before*
            // posting ⌘V. nil means AX won't tell us (Electron, some
            // hardened web views) — `verifyInsertion` treats nil as
            // "unknown, assume succeeded" rather than firing a
            // false-positive silent-drop pill on apps where we can't
            // observe the insertion either way.
            let baselineLength = PasteHelper.focusedTextLength()
            let result = PasteHelper.paste(finalText)
            switch result {
            case .inserted:
                pasteOutcome = await verifyInsertion(finalText, before: baselineLength)
                if pasteOutcome == .succeeded {
                    // Single satisfying ring-pulse confirmation.
                    lastChunkPastedAt = Date()
                }
            case .failed:
                pasteOutcome = .failed
                // Refresh status so the overlay reflects a freshly-
                // revoked Accessibility grant (or similar) without a
                // delay.
                refreshAccessibilityStatus()
            }
        }

        // Failure-path clipboard preservation. The cascade restored
        // (or is about to restore) the user's prior clipboard
        // contents 3.0s after `setString`. In the failure paths we
        // want the dictation text to outlast that restore so the
        // user can ⌘V the dictation manually. Re-write now (so a
        // fast-fingered user who reads the pill immediately can ⌘V
        // before the restore even runs) and again at +3.5s (so we
        // beat the restore for slower users). See the research memo
        // for the race details.
        //
        // We accept the known cosmetic cost: heavy clipboard managers
        // (Alfred, Raycast, Paste) may show a transient duplicate
        // entry for the dictation text. Acceptable trade for never
        // silently losing a dictation.
        if !finalText.isEmpty, pasteOutcome != .succeeded {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(finalText, forType: .string)
            }
        }

        // Restore manager settings so meeting mode works as before.
        // Order matters: this comes AFTER the snapshot continuation
        // resolved, so our one-shot onSessionCompleted callback has
        // already done its job. Restoring `savedOnCompleted` here
        // re-arms the production session-saving handler before the
        // user can start the next meeting.
        manager.onSessionCompleted = savedOnCompleted
        manager.speakerLabelsEnabled = savedSpeakerLabels
        manager.noiseFilterLevel = savedNoiseFilter
        manager.vocabularyHints = savedVocabHints
        manager.commitThresholds = savedCommitThresholds

        // Outcome- and reason-dependent orb linger.
        //
        //   • Silence-timeout success: hold the orb up for one
        //     `silenceTimeoutSeconds`. `lastSpeechTime` is frozen at
        //     this point, so the overlay's `windDownScale` naturally
        //     animates the orb 1.0 → 0 across the linger window —
        //     this is the post-paste phase 2 wind-down visual.
        //   • Hotkey or no-speech success: 250 ms — the user explicitly
        //     stopped (or never started talking), so a long fade reads
        //     as sticky.
        //   • Any failure: 4.5 s so the failure pill is readable and
        //     actionable before the orb disappears.
        let lingerNs: UInt64
        if pasteOutcome == .succeeded {
            switch reason {
            case .silenceTimeout:
                lingerNs = UInt64(silenceTimeoutSeconds * 1_000_000_000)
            case .hotkey, .noSpeechTimeout:
                lingerNs = 250_000_000
            }
        } else {
            lingerNs = 4_500_000_000
        }
        try? await Task.sleep(nanoseconds: lingerNs)

        overlay.hide()
    }

    /// Cheap post-paste AX verification. Reads the focused element's
    /// character count 250ms after we posted ⌘V and compares against
    /// the pre-paste baseline. If the count grew by at least the
    /// dictation's character length, paste succeeded. If it didn't,
    /// the receiving app silently dropped the ⌘V — Electron renderers
    /// and some hardened web views observe paste events but don't
    /// always consume them.
    ///
    /// `nil` baseline OR `nil` post-paste read both downgrade to
    /// `.succeeded`: if AX won't tell us, we'd rather not fire a
    /// false-alarm pill on apps where we can't observe the insertion
    /// either way. Aggressive multi-tick polling would catch more
    /// silent drops but adds perceptible orb-linger and trips on
    /// slow renderers; the single-read approach is the 90% solution
    /// at 10% of the cost.
    ///
    /// 250ms is the minimum that comfortably handles Electron's lazy-
    /// read pattern. Longer than that and the orb teardown lingers
    /// visibly; shorter and we'd trip false-positive silent drops on
    /// slow renderers.
    private func verifyInsertion(_ text: String, before: Int?) async -> PasteOutcome {
        guard let before else { return .succeeded }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let after = PasteHelper.focusedTextLength() else { return .succeeded }
        return (after - before) >= text.count ? .succeeded : .silentDrop
    }

    // MARK: - Silence monitor

    private func startSilenceMonitor() {
        silenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isDictating {
                self.evaluateAudio()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func evaluateAudio() {
        // Compare against the manager's RAW RMS, not the boosted
        // `audioLevels`. The old code averaged the three boosted +
        // smoothed visualizer levels and compared to 0.015 — that
        // threshold maps to roughly 0.001 raw, which real rooms
        // rarely clear, so the silence auto-stop effectively never
        // fired. Real-mic silence crosses below 0.015 raw routinely.
        let isSpeaking = manager.currentRMS >= silenceRMSThreshold

        if isSpeaking {
            lastSpeechTime = Date()
            return
        }

        // No speech yet — check the "did you ever speak" timeout.
        guard let start = sessionStartedAt else { return }
        if lastSpeechTime == nil,
           Date().timeIntervalSince(start) >= noSpeechTimeoutSeconds {
            Task { await self.stop(reason: .noSpeechTimeout) }
            return
        }

        // Had speech already — check the "stopped talking" timeout.
        // Auto-stop fires at exactly `silenceTimeoutSeconds` so the
        // paste lands the moment the countdown ring drains. The
        // post-paste wind-down (orb scaling 1.0 → 0 — see
        // `DictationOverlayView.windDownScale`) plays out during
        // `stop()`'s linger, but by then the engine is already
        // stopped and the text is already in the focused field.
        // Speaking during phase 1 advances `lastSpeechTime`, resetting
        // the elapsed back to zero. Speaking during the post-paste
        // fade does NOT reactivate dictation — at that point the user
        // taps ⌥Space again to start a fresh capture.
        if let last = lastSpeechTime,
           Date().timeIntervalSince(last) >= silenceTimeoutSeconds {
            Task { await self.stop(reason: .silenceTimeout) }
        }
    }

    deinit {
        hotkey.unregister()
        accessibilityPollTimer?.invalidate()
        if let tccObserver {
            DistributedNotificationCenter.default().removeObserver(tccObserver)
        }
    }
}

// MARK: - SingleResumeLatch
//
// Used by `stop()`'s snapshot-capture continuation. Both the snapshot
// callback and the safety timeout race to resume the same checked
// continuation; whichever wins, the loser must be a no-op (otherwise
// `withCheckedContinuation` traps with a fatal error on double-resume).
//
// We don't reach for atomics: both branches run on @MainActor (the
// timeout Task is `@MainActor` and the manager fires
// `onSessionCompleted` on the main thread). A plain `Bool` guarded by
// the actor's serialization is sufficient.

@MainActor
private final class SingleResumeLatch<T> {
    private var resumed = false
    private let continuation: CheckedContinuation<T, Never>

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
