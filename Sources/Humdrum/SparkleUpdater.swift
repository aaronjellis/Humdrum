import Foundation
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's standard updater
/// controller.
///
/// Wires:
///   • SPUStandardUpdaterController — Sparkle's drop-in coordinator.
///     Owns the scheduled-check timer, presents the update UI, handles
///     download + install, and exposes the `updater` + `userDriver` if
///     we ever need to customize.
///   • `@Published canCheck` — bound to the "Check for Updates…" menu
///     item so it dims during an in-flight check.
///
/// Config keys live in Info.plist (`SUFeedURL`, `SUPublicEDKey`,
/// `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). We deliberately
/// don't hard-code the feed URL here; ops and versioning of the appcast
/// should be able to change without a code release.
@MainActor
final class SparkleUpdater: ObservableObject {

    /// Owned by us so its lifetime matches the app. `startingUpdater:
    /// true` kicks off the scheduled background timer immediately, so
    /// we don't need to call `start()` separately.
    let controller: SPUStandardUpdaterController

    /// Mirrors `updater.canCheckForUpdates`. Sparkle flips this to false
    /// while a check / download is already in flight, and we use it to
    /// disable the menu item so users can't pile up concurrent checks.
    @Published private(set) var canCheck: Bool = true

    private var pollTimer: Timer?

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Sparkle doesn't publish KVO-friendly changes to
        // canCheckForUpdates on the main actor in a SwiftUI-safe way,
        // so we poll at 1 Hz — cheap, and the only consumer is a menu
        // item's enabled state which doesn't need to be instant.
        self.canCheck = controller.updater.canCheckForUpdates
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = self.controller.updater.canCheckForUpdates
                if now != self.canCheck { self.canCheck = now }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        // Fire a background check a few seconds after launch. Sparkle's
        // own scheduled timer would also eventually do this, but its
        // "first check after launch" cadence is conservative (hours),
        // which fails the "I just installed — tell me if there's an
        // update" expectation. `checkForUpdatesInBackground` only shows
        // UI if an update actually exists; it's silent otherwise.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.controller.updater.checkForUpdatesInBackground()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// User-initiated check — always shows UI, even when there's no
    /// update (so the user gets a "you're up to date" dialog rather
    /// than a silent no-op that looks broken).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
