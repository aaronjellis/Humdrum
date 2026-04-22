import Foundation
import AppKit

/// First-launch helper that offers to move Humdrum into /Applications
/// when it's running from somewhere weird — typically ~/Downloads right
/// after the user drag-extracts the zip.
///
/// Keeps distribution hygiene clean: without this, the user runs the app
/// from ~/Downloads, macOS places its Application Support + TCC rows
/// against that path, and the next time they "clean up Downloads" the
/// shortcut breaks. Moving on first launch avoids the whole class of
/// bug.
///
/// Loosely modelled on PotionFactory's LetsMove, but minimal: we copy,
/// relaunch, and terminate. No dock-bouncing, no Sparkle integration,
/// no translocation gymnastics — the app is notarized so translocation
/// shouldn't be triggering in the first place.
enum MoveToApplications {

    /// UserDefaults flag so "Do Not Move" sticks across launches. If the
    /// user said no once we don't keep asking.
    private static let declinedKey = "Humdrum.moveToApplications.declined"

    /// Call early in `App.init()`. No-op in debug builds, no-op if already
    /// in /Applications, no-op if the user has previously declined.
    ///
    /// If the user accepts, this function does not return — it terminates
    /// the current process after launching the moved copy.
    static func offerIfNeeded() {
        guard shouldOffer() else { return }

        let alert = NSAlert()
        alert.messageText = "Move Humdrum to your Applications folder?"
        alert.informativeText = """
            Humdrum is currently running from \(currentFolderDescription()). \
            Keeping it in your Applications folder means it won't disappear when \
            you clean up Downloads, and macOS will remember your microphone and \
            Accessibility permissions reliably.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performMove()
        } else {
            UserDefaults.standard.set(true, forKey: declinedKey)
        }
    }

    // MARK: - Gating

    private static func shouldOffer() -> Bool {
        #if DEBUG
        // Swift-build dev loops run out of .build/release; don't pester
        // in those builds. Notarized release builds are the ones that
        // ship to users.
        return false
        #else
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return false }
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return false }

        // Running from /Applications or ~/Applications already → nothing to do.
        let path = bundleURL.path
        if path.hasPrefix("/Applications/") { return false }
        let userApps = ("~/Applications" as NSString).expandingTildeInPath
        if path.hasPrefix(userApps + "/") { return false }

        // If the app is inside a read-only mount (e.g., a DMG), moving
        // the binary will fail with a cross-device error. Skip the
        // offer rather than showing a broken flow.
        if path.contains("/Volumes/") { return false }

        return true
        #endif
    }

    private static func currentFolderDescription() -> String {
        let url = Bundle.main.bundleURL.deletingLastPathComponent()
        let path = url.path
        let homeDownloads = ("~/Downloads" as NSString).expandingTildeInPath
        if path == homeDownloads { return "your Downloads folder" }
        return path
    }

    // MARK: - The actual move

    /// Copies the app bundle into /Applications, relaunches it from
    /// there, and terminates the current process. Falls back to a
    /// non-blocking error alert if any step fails.
    private static func performMove() {
        let fm = FileManager.default
        let srcURL = Bundle.main.bundleURL
        let destURL = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(srcURL.lastPathComponent)

        // If a copy already exists there (prior install), replace it.
        // Unlike -replaceItem, plain trash+copy is simpler and doesn't
        // hit atomic-move subtleties on APFS.
        if fm.fileExists(atPath: destURL.path) {
            do {
                try fm.trashItem(at: destURL, resultingItemURL: nil)
            } catch {
                moveFailed(error, stage: "removing existing /Applications/\(srcURL.lastPathComponent)")
                return
            }
        }

        do {
            try fm.copyItem(at: srcURL, to: destURL)
        } catch {
            moveFailed(error, stage: "copying to /Applications")
            return
        }

        // Relaunch the moved copy via NSWorkspace, then quit this
        // instance. open -n would also work, but NSWorkspace gives us
        // a concrete failure path on the Swift side.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: destURL, configuration: config) { _, error in
            if let error {
                NSLog("Humdrum: relaunch after move failed: \(error)")
            }
            // Terminate regardless — the file has moved, and leaving
            // the old copy running against /Downloads is exactly what
            // we're trying to avoid.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func moveFailed(_ error: Error, stage: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't move Humdrum to Applications"
        alert.informativeText = """
            \(error.localizedDescription)

            The app will keep running from its current location. You can \
            drag it into Applications yourself later.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        _ = alert.runModal()
        NSLog("Humdrum MoveToApplications failure while \(stage): \(error)")
    }
}
