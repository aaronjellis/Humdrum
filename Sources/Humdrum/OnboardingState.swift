import Foundation
import SwiftUI
import AVFoundation
import AppKit

/// Drives the first-run onboarding flow. Owned at app scope so it can
/// decide (pre-window) whether onboarding needs to run at all, and so
/// live permission state can be read/polled from one place.
///
/// Panels:
///   1. welcome       — who I am, one sentence of what I do
///   2. features      — explain the two modes (Meeting / Mutter)
///   3. activation    — pick toggle vs press-and-hold for Mutter
///   4. voiceModel    — pick a Quality, optionally download now
///   5. permissions   — mic + Accessibility, soft-blocking
///   6. folder        — optional default save folder (turns auto-save on)
///   7. success       — checkmark over the animated orb
///
/// Persists a single flag (`Humdrum.onboarded.v1`) — nothing else. All
/// other state (Quality, save folder, auto-save) is written straight to
/// the real sources of truth (TranscriptionManager / AppState) as the
/// user moves through, so bailing out mid-flow still leaves the app
/// correctly configured.
@MainActor
final class OnboardingState: ObservableObject {

    // MARK: - Panels

    enum Panel: Int, CaseIterable {
        case welcome, features, activation, voiceModel, permissions, folder, success
    }

    // MARK: - Published

    @Published var currentPanel: Panel = .welcome

    /// True once the user has reached and dismissed the success panel.
    /// Flipped to UserDefaults so subsequent launches skip the flow.
    @Published private(set) var isOnboarded: Bool

    /// Live TCC state. Polled while the permissions panel is visible so
    /// flipping a toggle in System Settings updates our UI without any
    /// extra clicks.
    @Published var micGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    /// Voice-model download progress. WhisperKit doesn't expose a %,
    /// so we show an indeterminate spinner plus any terminal error.
    @Published var isDownloadingModel: Bool = false
    @Published var modelDownloadError: String?

    // MARK: - Persistence key

    private static let onboardedKey = "Humdrum.onboarded.v1"

    // MARK: - Polling

    /// Panel-scoped fast poll (1 s). Active only while the Permissions
    /// panel is visible — snappy feedback while the user is actively
    /// looking at the rows.
    private var permissionPollTimer: Timer?

    /// Always-on safety-net poll (2 s). Runs for the whole lifetime of
    /// OnboardingState so that when the user flips Accessibility in
    /// Settings and comes back — even to a panel that isn't the
    /// permissions panel (e.g. they grant after navigating forward to
    /// Folder, or before they've reached Permissions at all) — the
    /// state still refreshes. Matches DictationCoordinator's approach.
    private var ambientPollTimer: Timer?

    /// DistributedNotificationCenter observer for the accessibility-api
    /// change notification. macOS broadcasts this when the TCC DB is
    /// modified, so we can refresh instantly without waiting on poll.
    private var tccObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        self.isOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        refreshPermissionState()

        // Listen for the Accessibility TCC notification so the onboarding
        // UI flips from "Allow" → "Granted" the instant the user toggles
        // our row in System Settings, without app relaunch.
        tccObserver = DistributedNotificationCenter
            .default()
            .addObserver(
                forName: Notification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissionState()
                }
            }

        // Belt-and-suspenders: the notification sometimes doesn't fire
        // (stale signature after rebuild, ad-hoc sign, etc.). Poll every
        // 2 s regardless of which panel is visible. Cheap syscall.
        ambientPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionState()
            }
        }
        // Fire in .common mode so the timer keeps ticking even when the
        // main runloop is in tracking mode (sheet up, menu open, etc).
        if let t = ambientPollTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    deinit {
        permissionPollTimer?.invalidate()
        ambientPollTimer?.invalidate()
        if let obs = tccObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    // MARK: - Navigation

    func next() {
        let all = Panel.allCases
        guard let idx = all.firstIndex(of: currentPanel), idx < all.count - 1 else { return }
        currentPanel = all[idx + 1]
    }

    func back() {
        let all = Panel.allCases
        guard let idx = all.firstIndex(of: currentPanel), idx > 0 else { return }
        currentPanel = all[idx - 1]
    }

    func go(to panel: Panel) {
        currentPanel = panel
    }

    /// Called from the success panel's "Open Humdrum" button. Flips the
    /// persisted flag so cold launches skip onboarding, and nudges the
    /// scene gate to swap to the main window.
    func finish() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        stopPermissionPolling()
        isOnboarded = true
    }

    // MARK: - Permissions

    /// Snapshot current mic + Accessibility state. Safe to call any time
    /// (no prompts, no side effects).
    func refreshPermissionState() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = PasteHelper.accessibilityEnabled()
    }

    /// Start a 1 s timer so permissions flipped in System Settings
    /// light up our UI without the user having to click anything in
    /// Humdrum. Call when the permissions panel appears; stop when it
    /// disappears or onboarding finishes.
    func startPermissionPolling() {
        stopPermissionPolling()
        refreshPermissionState()
        let t = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
            }
        }
        // .common so ticks continue during sheet / menu / drag tracking.
        RunLoop.main.add(t, forMode: .common)
        permissionPollTimer = t
    }

    func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    /// Show the system mic prompt the first time. Subsequent denials
    /// require a trip to System Settings (macOS TCC doesn't re-prompt).
    /// After the request, we re-read status so the UI row flips green
    /// immediately on approval.
    func requestMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micGranted = true
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            micGranted = ok
            if !ok {
                // User picked Don't Allow in the system sheet. Route
                // them to Settings so they can still grant.
                openMicrophoneSettings()
            }
        case .denied, .restricted:
            // TCC won't re-prompt here — send them to the pane.
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    /// Set once we've called the prompting variant of AX trust check
    /// in this process. macOS only surfaces the system sheet on the
    /// first ask per process lifetime — subsequent calls silently
    /// no-op. We use this to decide whether a click on "Allow" should
    /// fire the prompt (first time) or open System Settings (every
    /// time after).
    private var hasPromptedAccessibility: Bool = false

    /// Called when the user taps "Allow" on the Accessibility row in
    /// onboarding.
    ///
    /// Flow:
    ///   • Already trusted → just update our @Published flag.
    ///   • First click in this process → fire the system prompt sheet.
    ///     The sheet has its own "Open System Settings" button — do
    ///     NOT also open Settings ourselves, or the user sees both
    ///     the sheet and the Settings window appear simultaneously,
    ///     which reads as "did I click twice?".
    ///   • Second-plus click (prompt is now a no-op) → open Settings
    ///     directly, because the sheet won't re-appear and the button
    ///     would feel dead otherwise.
    func requestAccessibility() {
        if PasteHelper.accessibilityEnabled() {
            accessibilityGranted = true
            return
        }

        if !hasPromptedAccessibility {
            hasPromptedAccessibility = true
            // Fire the sheet. Return value is the current (pre-user-
            // decision) trust state — we don't act on it. The poller
            // picks up the grant whenever the user finishes.
            _ = PasteHelper.accessibilityEnabled(prompt: true)
            return
        }

        // Second click after the one-shot prompt has been exhausted —
        // route straight to Settings.
        openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Derived

    var bothPermissionsGranted: Bool {
        micGranted && accessibilityGranted
    }
}
