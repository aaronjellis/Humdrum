import Foundation
import SwiftUI
import Combine
import AppKit
import AVFoundation
import Carbon.HIToolbox
import HumdrumCore

/// Orchestrates Whisper Flow-style dictation, utterance-paced commits.
///
///   Press ⌥Space → orb appears centered on screen → speak → after
///   `silenceTimeoutSeconds` of silence (phase 1, the countdown ring
///   draining) we paste *the new tail* of the transcript into the
///   focused field — but the engine stays hot. The orb then begins
///   its scale-down (phase 2, another `silenceTimeoutSeconds`) as a
///   "still listening, but about to give up" affordance. Speaking
///   during phase 2 snaps the orb back to full and resets the
///   countdown — the next phase-1 boundary will paste only the
///   *new* tail (we track `pastedCharCount` against Whisper's
///   monotonic confirmedText). Stay silent through both phases and
///   we tear down via `stop()`, which flushes any final tail-pass
///   text the live stream hadn't surfaced yet. Hotkey stop also
///   flushes the diff so a quick ⌥Space-tap doesn't lose anything
///   that arrived after the last phase-1 commit. The user's
///   original complaint that drove the diff design: the previous
///   single-commit-at-2T cadence meant "the text appears too late"
///   AND killed the orb after one utterance — paste-and-keep-
///   listening fixes both.
///
/// Text goes in via clipboard + ⌘V. See `PasteHelper` for the
/// rationale (short version: ⌘V is the OS-blessed insertion event
/// every mainstream target accepts, where synthetic unicode key
/// events get silently filtered by Electron renderers).
///
/// Why diff-paste instead of per-Whisper-commit paste: the old
/// streaming-paste path fired one clipboard write + ⌘V per Whisper
/// commit, which produced overlapping pasteboard restores that
/// raced with Electron's lazy clipboard reads. On long dictations
/// the receiver would consistently land on the *restored*
/// clipboard contents and nothing would paste at all. Diff-paste
/// at phase 1 boundaries fires at human-utterance cadence (every
/// few seconds at most), giving each clipboard restore time to
/// resolve before the next paste arrives, while still letting the
/// user keep talking into the same orb session. See
/// `docs/mutter-paste-research.md` for the receipts on why
/// per-commit pasting was unsalvageable.
///
/// Uses the shared TranscriptionManager but temporarily overrides its
/// session-completion callback + settings so dictations aren't saved as
/// sessions and don't get speaker labels.
@MainActor
final class DictationCoordinator: ObservableObject {

    // MARK: - Published

    @Published private(set) var isDictating: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false

    /// True while the user has tapped ⌥P to pause an active dictation.
    /// The orb stays on screen, manager keeps recording (so resuming
    /// is instantaneous) but `evaluateAudio()` early-returns so no
    /// silence detection or phase-1 commits fire while paused. The
    /// overlay watches this flag to dim the orb and freeze the ring.
    /// Reset to false on every fresh `start()` and on resume.
    @Published private(set) var isPaused: Bool = false

    /// Timestamp set the moment the user hits Escape to cancel an
    /// active dictation. The overlay watches this to render a brief
    /// red ring-pulse around the orb so the cancel reads as
    /// intentional rather than as an unexplained fade. Cleared on
    /// the next `start()`.
    @Published private(set) var cancelFlashAt: Date?

    /// Timestamp of the most recent successful paste into the focused
    /// field. The overlay watches this to flash a short ring-pulse
    /// around the orb when paste lands. Fires on each phase-1
    /// commit boundary that successfully delivers text — single-
    /// utterance sessions see one pulse, multi-utterance sessions
    /// see one per commit. The orb's existing pulse animation
    /// handles either case gracefully, so each commit gets its own
    /// satisfying confirmation flash for free.
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
    ///     (phase 1). At elapsed = T the silence monitor fires
    ///     `commitAndPaste()` — that's when the new tail of the
    ///     transcript lands in the focused field.
    ///   • The post-commit "still listening" fade (phase 2,
    ///     [T, 2T]) keeps using this anchor to drive the orb's
    ///     1.0 → 0 scale: speaking during the fade resets
    ///     `lastSpeechTime` to now, the orb springs back to full,
    ///     and the next phase-1 boundary produces a fresh diff
    ///     paste. Sit silent through the full 2T window and
    ///     `stop()` runs.
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
    private let hotkey = HotkeyManager(id: 1)
    /// Conditional hotkey, only armed while the orb is up. Tap ⌥P to
    /// freeze the engine without losing the session; tap again to
    /// resume. Lives on its own HotkeyManager instance (id: 2) so it
    /// doesn't collide with the global ⌥Space toggle (id: 1).
    private let pauseHotkey = HotkeyManager(id: 2)

    // MARK: - Session state

    private var savedOnCompleted: ((TranscriptSessionSnapshot) -> Void)?
    private var savedSpeakerLabels: Bool = false
    private var savedNoiseFilter: NoiseFilterLevel = .normal
    private var savedVocabHints: String = ""
    private var savedCommitThresholds: CommitThresholds = .meeting

    private var silenceTask: Task<Void, Never>?
    private var tccObserver: NSObjectProtocol?
    private var accessibilityPollTimer: Timer?

    /// Cumulative count of characters from `manager.confirmedText` that
    /// have already been pasted into the focused field. Each phase-1
    /// commit pastes only the suffix `confirmedText.dropFirst(pastedCharCount)`,
    /// then advances this counter. Reset to zero on each fresh `start()`.
    /// Relies on Whisper's confirmedText being append-only, which it is
    /// for the stable-confirmed stream (the hypothesis tail is rewritten
    /// freely, but confirmed text only grows).
    private var pastedCharCount: Int = 0

    /// Set while a phase-1 commit's paste/verify cycle is in flight, so
    /// the silence monitor's 200 ms tick doesn't double-fire
    /// `commitAndPaste()` while the previous one is still resolving its
    /// post-paste AX verification. Cleared in the deferred block of
    /// `commitAndPaste()`.
    private var commitInProgress: Bool = false

    /// Tracks the currently-armed +3.5 s clipboard-re-write Task on the
    /// failure path. Each new commit cancels the prior task before
    /// arming its own — without this, a previous commit's preserved
    /// text could clobber the current commit's clipboard 3.5 s into
    /// the next utterance, and the user would ⌘V the wrong dictation.
    /// Deliberately NOT cancelled on `stop()` — if the final flush
    /// failed, the user needs the preserved text on their clipboard
    /// for several seconds after the orb disappears so ⌘V works.
    /// Cancelled on the next `start()` instead, which is the
    /// earliest moment a stale task could harm a live clipboard.
    private var clipboardPreservationTask: Task<Void, Never>?

    /// Token returned by `NSEvent.addGlobalMonitorForEvents` (and the
    /// matching local monitor) for the Escape-to-cancel handler. Both
    /// monitors are armed in `start()` after the orb is up and torn
    /// down in `stop()` / `cancel()` so we're not eavesdropping on
    /// every keystroke globally outside an active dictation. Stored
    /// as `Any?` because the AppKit return type is opaque.
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

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
        pastedCharCount = 0
        commitInProgress = false
        clipboardPreservationTask?.cancel()
        clipboardPreservationTask = nil
        isPaused = false
        cancelFlashAt = nil

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
            return
        }

        // Engine is hot and the orb is visible — arm the conditional
        // bindings that only make sense during an active dictation.
        installPauseHotkey()
        installEscapeMonitor()
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
        isPaused = false

        silenceTask?.cancel()
        silenceTask = nil

        // Conditional bindings (pause hotkey, escape monitor) only
        // make sense while the orb is up. Tear them down before the
        // orb hides so we don't eavesdrop on every keystroke between
        // sessions.
        teardownConditionalBindings()

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
        // Then slice off the prefix that earlier phase-1 commits
        // already pasted — we only want to flush whatever new tail
        // arrived between the last commit and teardown. Trim
        // trailing whitespace; Whisper occasionally leaves a hanging
        // space after the last token.
        let rawText = snapshot?.transcriptText ?? manager.confirmedText
        let pendingTail: String
        if pastedCharCount >= rawText.count {
            pendingTail = ""
        } else {
            let startIdx = rawText.index(
                rawText.startIndex,
                offsetBy: pastedCharCount,
                limitedBy: rawText.endIndex
            ) ?? rawText.endIndex
            pendingTail = String(rawText[startIdx...])
        }
        let finalText = pendingTail.trimmingCharacters(in: .whitespacesAndNewlines)

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
        // Cancel any in-flight preservation Task from a prior phase-1
        // commit before arming our own, otherwise the older task
        // would clobber the clipboard 3.5s into teardown.
        //
        // We accept the known cosmetic cost: heavy clipboard managers
        // (Alfred, Raycast, Paste) may show a transient duplicate
        // entry for the dictation text. Acceptable trade for never
        // silently losing a dictation.
        if !finalText.isEmpty, pasteOutcome != .succeeded {
            clipboardPreservationTask?.cancel()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
            clipboardPreservationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
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

        // Outcome-dependent orb linger.
        //
        // On success, 250 ms — enough for the final flush ⌘V to
        // paint and the confirmation ring-pulse to be visible
        // without the orb feeling sticky. By the time `stop()` runs
        // on the silence path the orb has already animated through
        // the phase 2 scale-down (1.0 → 0 over [T, 2T]) — that's
        // the visible "still listening, but giving up" cue that
        // resolves into a near-zero orb just as we land here. On
        // hotkey stops the user is yanking the orb intentionally,
        // so the abrupt 250 ms exit is fine.
        //
        // On failure, 4.5 s so the failure pill is readable and
        // actionable before the orb disappears.
        let lingerNs: UInt64 = (pasteOutcome == .succeeded) ? 250_000_000 : 4_500_000_000
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

    // MARK: - Phase-1 commit

    /// Phase-1 paste: at the end of the silence countdown, paste the
    /// new tail of `manager.confirmedText` (everything since
    /// `pastedCharCount`) and advance the counter, leaving the engine
    /// running so the user can continue dictating into the same
    /// session. The orb's phase 2 fade plays out from here; speaking
    /// during it resets `lastSpeechTime`, which snaps the orb back to
    /// full size and arms the next phase-1 commit on the next silence.
    ///
    /// Why slice on UTF-16 character offsets and not, say, words or
    /// Whisper segment boundaries: `confirmedText` is the canonical
    /// monotonic stream Whisper has decided to lock in — it only ever
    /// grows, never gets rewritten (the hypothesis tail is what gets
    /// rewritten). So a simple "what's after the last paste's
    /// length" diff is correct by construction. We don't need the
    /// `WordStream` diff machinery here because there's no
    /// hypothesis-overlap problem at phase-1 boundaries: by then
    /// `silenceTimeoutSeconds` of silence has elapsed, and Whisper
    /// has had ample chances to promote any reasonable hypothesis
    /// into confirmedText.
    ///
    /// Race-safety: `commitInProgress` gates re-entry from the 200 ms
    /// silence monitor tick. The check + set happens on @MainActor in
    /// a single sync run, so there's no TOCTOU window. We always
    /// advance `pastedCharCount` to the snapshot count even on paste
    /// failure — retry-as-bigger-diff is worse than letting the
    /// failure-path clipboard preservation be the recovery vehicle.
    private func commitAndPaste() async {
        guard !commitInProgress, isDictating else { return }
        commitInProgress = true
        defer { commitInProgress = false }

        // Snapshot now — `confirmedText` is observable and could grow
        // mid-paste if Whisper finalizes another segment while we're
        // awaiting the AX verification. We paste exactly the slice
        // we measured, and advance the counter to that measured
        // length (not the live length) so anything that lands during
        // the await gets picked up by the next phase-1 commit.
        let confirmedSnapshot = manager.confirmedText
        let snapshotCount = confirmedSnapshot.count
        guard snapshotCount > pastedCharCount else { return }

        let startIdx = confirmedSnapshot.index(
            confirmedSnapshot.startIndex,
            offsetBy: pastedCharCount,
            limitedBy: confirmedSnapshot.endIndex
        ) ?? confirmedSnapshot.endIndex
        let pendingTail = String(confirmedSnapshot[startIdx...])
        let trimmed = pendingTail.trimmingCharacters(in: .whitespacesAndNewlines)

        // The diff was pure whitespace — no user-visible text to
        // paste, but advance the counter so we don't keep
        // re-entering on the next monitor tick.
        if trimmed.isEmpty {
            pastedCharCount = snapshotCount
            return
        }

        let baselineLength = PasteHelper.focusedTextLength()
        let result = PasteHelper.paste(trimmed)
        switch result {
        case .inserted:
            pasteOutcome = await verifyInsertion(trimmed, before: baselineLength)
            if pasteOutcome == .succeeded {
                lastChunkPastedAt = Date()
            }
            pastedCharCount = snapshotCount
        case .failed:
            pasteOutcome = .failed
            refreshAccessibilityStatus()
            pastedCharCount = snapshotCount
        }

        // Failure-path clipboard preservation, mirroring `stop()`.
        // Cancel any in-flight preservation Task from a previous
        // commit before arming our own — otherwise consecutive
        // failures could race their +3.5 s rewrites and leave stale
        // text on the clipboard.
        if pasteOutcome != .succeeded {
            clipboardPreservationTask?.cancel()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            clipboardPreservationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
            }
        }
    }

    // MARK: - Pause / Cancel

    /// Tap-⌥P handler. Toggles `isPaused`. The orb stays visible in
    /// either state — the overlay watches `isPaused` to dim the orb
    /// and freeze the silence ring while paused. The transcription
    /// manager keeps recording, so resume is instantaneous, but
    /// `evaluateAudio()` early-returns so no silence detection or
    /// phase-1 commits fire while paused. We also re-anchor
    /// `lastSpeechTime` to the moment of (un)pause so the ring renders
    /// from full when entering paused (no flicker as elapsed jumps
    /// past T) and gets a fresh runway on resume.
    private func togglePause() {
        guard isDictating else { return }
        isPaused.toggle()
        // Refresh the speech anchor either way — entering pause
        // freezes the ring at full (recent speech), and exiting
        // pause gives the user the full silenceTimeoutSeconds before
        // a phase-1 commit fires.
        lastSpeechTime = Date()
    }

    /// Escape handler. Tears the orb down without pasting whatever
    /// new tail has accumulated since the last phase-1 commit.
    /// Already-pasted text from earlier commits is untouched — undoing
    /// text that's already landed in another app is a can of worms
    /// macOS apps don't generally have a sane way to open. Sets
    /// `cancelFlashAt` so the overlay can paint a brief red ring
    /// before fade so the user reads the cancel as intentional.
    ///
    /// We mark the cancel as a successful outcome (no failure pill)
    /// — the user explicitly threw the work away, that's not an
    /// error worth surfacing. We do NOT touch the clipboard: if a
    /// previous phase-1 commit's failure path armed a preservation
    /// task, that text is still useful to the user even after a
    /// cancel.
    ///
    /// Lifecycle gotcha: we hide the overlay promptly after the red
    /// flash plays out (~350 ms), but we must still synchronously
    /// await `manager.stop()` before restoring production settings —
    /// otherwise a fast follow-up ⌥Space could read mid-cleanup
    /// state and bind the wrong `savedOnCompleted` for the next
    /// session, leaking the cancellation behavior into a real
    /// recording. While we're inside that await, `manager.isBusy` is
    /// true so a new `start()` will beep-and-bail, which is the
    /// desired backpressure.
    private func cancel() async {
        guard isDictating else { return }
        isDictating = false
        isPaused = false

        silenceTask?.cancel()
        silenceTask = nil
        teardownConditionalBindings()

        // Trigger the red ring-pulse on the overlay.
        cancelFlashAt = Date()

        // Discard whatever the manager has captured — cancel means
        // throw away. nil-ing the callback before stop() means the
        // manager's tail-pass completion fires into the void
        // instead of triggering any session-saver logic.
        manager.onSessionCompleted = nil

        // Promptly hide the orb after the red flash plays. This
        // happens in parallel with manager.stop() below; the user
        // doesn't need to see the orb sit while Whisper finalizes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.overlay.hide()
        }

        await manager.stop()

        manager.onSessionCompleted = savedOnCompleted
        manager.speakerLabelsEnabled = savedSpeakerLabels
        manager.noiseFilterLevel = savedNoiseFilter
        manager.vocabularyHints = savedVocabHints
        manager.commitThresholds = savedCommitThresholds
    }

    /// Registers the ⌥P binding on `pauseHotkey`. Logs and continues
    /// silently if registration fails — pause is a nice-to-have, not
    /// a critical path, and the global ⌥P collision is the
    /// realistic failure mode (some other app already owns it).
    private func installPauseHotkey() {
        let registered = pauseHotkey.register(
            keyCode: HotkeyManager.Key.p,
            modifiers: HotkeyManager.Modifier.option.rawValue
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.togglePause()
            }
        }
        if !registered {
            NSLog("[Humdrum] Pause hotkey ⌥P could not be registered (likely owned by another app).")
        }
    }

    /// Installs both a global and a local NSEvent monitor for
    /// `keyDown` events matching the Escape key. The dictation panel
    /// is intentionally non-key (so the user's focused text field in
    /// the target app keeps focus and ⌘V lands correctly), so a
    /// local monitor alone wouldn't catch keystrokes during a
    /// typical dictation. Global covers "user is in another app and
    /// hits escape," local covers the rare case where Humdrum's
    /// main window happens to be focused. Both are torn down on
    /// stop/cancel so we're not eavesdropping outside an active
    /// dictation.
    private func installEscapeMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, event.keyCode == 53 /* kVK_Escape */ else { return }
            Task { @MainActor [weak self] in
                await self?.cancel()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                await self?.cancel()
            }
            // Swallow the event so it doesn't propagate into our own
            // window's responder chain.
            return nil
        }
    }

    /// Tears down the pause hotkey and escape monitors. Safe to call
    /// multiple times (each call is idempotent on already-cleared
    /// state). Called from both `stop()` and `cancel()`.
    private func teardownConditionalBindings() {
        pauseHotkey.unregister()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
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
        // Pause is a hard freeze — no silence detection, no phase-1
        // commits, no no-speech-timeout firing. The orb stays on
        // screen with `lastSpeechTime` frozen at the moment of pause
        // (set inside `togglePause()`), so the silence ring renders
        // at full and reads as "we're holding for you." Tap ⌥P
        // again to resume.
        if isPaused { return }

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

        // Had speech already — two thresholds:
        //
        //   • At elapsed = T (`silenceTimeoutSeconds`): the countdown
        //     ring has fully drained — fire `commitAndPaste()`. This
        //     pastes whatever new text has accumulated since the last
        //     paste (the *diff* of `manager.confirmedText`); engine
        //     stays hot.
        //   • At elapsed = 2T: full teardown via `stop()`. The user
        //     stayed silent through both the ring drain AND the
        //     post-commit fade window, so we shut down.
        //
        // Speaking during *either* phase advances `lastSpeechTime`,
        // resetting elapsed to zero — the orb springs back to full
        // size, the ring re-engages, and the next phase-1 boundary
        // produces a fresh paste of just the new text. This is the
        // "commit-and-keep-listening" affordance: a long dictation
        // becomes a sequence of utterance-sized commits without ever
        // losing focus.
        guard let last = lastSpeechTime else { return }
        let silenceElapsed = Date().timeIntervalSince(last)

        if silenceElapsed >= silenceTimeoutSeconds * 2 {
            Task { await self.stop(reason: .silenceTimeout) }
            return
        }

        if silenceElapsed >= silenceTimeoutSeconds,
           !commitInProgress,
           manager.confirmedText.count > pastedCharCount {
            Task { await self.commitAndPaste() }
        }
    }

    deinit {
        hotkey.unregister()
        pauseHotkey.unregister()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
        }
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
