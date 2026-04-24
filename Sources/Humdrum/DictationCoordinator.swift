import Foundation
import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import HumdrumCore

/// Orchestrates Whisper Flow-style dictation.
///
///   Press ⌥Space → orb appears centered on screen → speak → each
///   committed Whisper chunk is inserted directly into whatever field
///   had focus via the Accessibility API → 2.5 s of silence (or another
///   ⌥Space) stops dictation and hides the orb.
///
/// Text goes in via `kAXSelectedTextAttribute` only — no clipboard
/// writes, no synthesized ⌘V keystrokes. See `PasteHelper` for the
/// rationale (short version: silent clipboard mutation is surprising,
/// and keystroke fallback hides real permission problems).
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
    /// around the orb each time a chunk lands — the user gets a
    /// positive signal that Whisper → paste is flowing, instead of
    /// wondering if anything's happening.
    @Published private(set) var lastChunkPastedAt: Date?

    /// Timestamp of the most recent activity (speech OR paste). The
    /// overlay reads this to render a shrinking silence-countdown
    /// ring; when the elapsed time since this moment reaches
    /// `silenceTimeoutSeconds`, dictation auto-closes.
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
    /// Mic RMS below this counts as silence.
    var silenceRMSThreshold: Float = 0.015

    // MARK: - Dependencies

    private let manager: TranscriptionManager
    private let overlay = DictationOverlayController()
    private let hotkey = HotkeyManager()

    // MARK: - Session state

    private var pastedText: String = ""            // what we've already sent to the focused field
    private var savedOnCompleted: ((TranscriptSessionSnapshot) -> Void)?
    private var savedSpeakerLabels: Bool = false
    private var savedNoiseFilter: NoiseFilterLevel = .normal
    private var savedVocabHints: String = ""

    private var commitsSink: AnyCancellable?
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

        pastedText = ""
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

        manager.onSessionCompleted = { _ in /* suppressed for dictation */ }
        manager.speakerLabelsEnabled = false
        manager.noiseFilterLevel = .strict

        // Observe committed transcript for incremental paste.
        commitsSink = manager.$confirmedText
            .sink { [weak self] newText in
                guard let self else { return }
                Task { @MainActor in self.handleTextUpdate(newText) }
            }

        // Reset the session anchor now that the model is actually
        // ready — otherwise a slow first-time model download would
        // burn the entire 8 s no-speech budget before the user could
        // say anything, and dictation would auto-stop on the very
        // first silence-monitor tick.
        sessionStartedAt = Date()

        startSilenceMonitor()
        await manager.start()
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

        commitsSink?.cancel()
        commitsSink = nil
        silenceTask?.cancel()
        silenceTask = nil

        await manager.stop()

        // Paste any final delta that arrived during finalize.
        let remaining = computeDelta(manager.confirmedText)
        if !remaining.isEmpty {
            PasteHelper.paste(remaining)
            pastedText = manager.confirmedText
        }

        // Restore manager settings so meeting mode works as before.
        manager.onSessionCompleted = savedOnCompleted
        manager.speakerLabelsEnabled = savedSpeakerLabels
        manager.noiseFilterLevel = savedNoiseFilter
        manager.vocabularyHints = savedVocabHints

        // Delay hide slightly so the last paste lands before the window
        // teardown flickers.
        try? await Task.sleep(nanoseconds: 120_000_000)
        overlay.hide()
    }

    // MARK: - Real-time paste

    private func handleTextUpdate(_ newText: String) {
        let delta = computeDelta(newText)
        guard !delta.isEmpty else { return }

        let result = PasteHelper.paste(delta)
        lastSpeechTime = Date()

        // Only advance `pastedText` when the cascade actually inserted
        // the chunk. If we advanced on `.failed` we'd silently drop the
        // delta forever — the next tick's computeDelta would no longer
        // include it. Leaving `pastedText` in place means the missed
        // chunk gets retried on the next Whisper update.
        switch result {
        case .inserted:
            pastedText = newText
            // Publish the paste timestamp so the overlay's ring-pulse
            // animation fires — user gets a confirmation burst every
            // time a chunk successfully lands in the focused field.
            lastChunkPastedAt = Date()
        case .failed:
            // Refresh status so the overlay's warning pill can appear
            // (e.g. user revoked Accessibility mid-session) instead of
            // silently pretending everything's fine.
            refreshAccessibilityStatus()
        }
    }

    /// Diff between what the manager has committed and what we've already
    /// sent to the focused field. Defensive: if the committed text ever
    /// diverges (Whisper rewrites older chunks), we skip the update and
    /// wait for it to reconverge rather than send unintended keystrokes.
    private func computeDelta(_ newText: String) -> String {
        if newText.hasPrefix(pastedText) {
            return String(newText.dropFirst(pastedText.count))
        }
        // Divergence — don't type anything; wait for the next commit.
        return ""
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
        let avg = manager.audioLevels.isEmpty
            ? 0
            : manager.audioLevels.reduce(0, +) / Float(manager.audioLevels.count)
        let isSpeaking = avg >= silenceRMSThreshold

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
