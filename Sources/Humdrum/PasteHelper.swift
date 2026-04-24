import Foundation
import AppKit
import ApplicationServices
import HumdrumCore

/// Executable-target adapter between the dictation coordinator and the
/// pure-logic `PasteCascade` in HumdrumCore.
///
/// The job of this file is narrow: read the live environment (Accessibility
/// trust, frontmost bundle ID, focused AX role), hand those facts to
/// `PasteCascade.decide`, then run the resulting `PasteDecision` through
/// the two concrete strategies (keystroke synthesis → clipboard + ⌘V).
/// Every decision-level concern lives in HumdrumCore so it can be
/// unit-tested without AppKit. This file is the thin I/O layer.
///
/// Why two stages (and why not AX):
///   Research into leading macOS dictation apps (Superwhisper, Wispr
///   Flow, TypeVox, Talon, Aqua Voice) and documented failure reports
///   against the AX text-insertion path in Chromium/Electron/Office/
///   JetBrains converge on the same conclusion: `kAXSelectedTextAttribute`
///   writes report `.success` but silently drop on too many target apps
///   to be useful as a primary strategy. Going keystroke-first
///   universally is simpler, more reliable, and avoids an entire class
///   of verification gymnastics.
///
///   1. **Keystroke synthesis.** `CGEventKeyboardSetUnicodeString` posts
///      unicode characters into the system-wide event tap. This is what
///      the OS itself uses for text substitution, so it gets routed the
///      same way the user's own typing does — including through any
///      custom event handling Electron apps install. Does NOT touch the
///      clipboard. Primary strategy for every non-refused paste.
///   2. **Clipboard + ⌘V.** Tail fallback, reached only when the CGEvent
///      source can't be constructed (very rare). Writes to
///      `NSPasteboard.general`, synthesizes ⌘V, then restores the
///      previous clipboard contents on a short delay so the user's
///      copied text isn't obliterated.
///
/// Above both stages, `decide()` also refuses outright when the focused
/// element is a password field — we never type into secure text fields.
///
/// The cascade decision lives in `PasteCascade.decide`; see the comment
/// there for the full branching logic.
enum PasteHelper {

    // MARK: - Accessibility status

    /// Silent check of Accessibility permission. No prompt, no state
    /// caching weirdness — always returns the current TCC decision.
    static func accessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    /// Version that also shows the system prompt if we're not yet
    /// trusted. Use this exactly once when we actually need the
    /// permission for paste, not as a status read.
    @discardableResult
    static func accessibilityEnabled(prompt: Bool) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Paste

    /// Top-level paste entry point used by `DictationCoordinator`. Probes
    /// the environment, asks `PasteCascade` which strategy to run, and
    /// hands the decision to `PasteCascade.execute` against the real
    /// backend. Returns HumdrumCore's `PasteResult`, which the coordinator
    /// switches on to flash the chunk pulse or surface the warning pill.
    @discardableResult
    static func paste(_ text: String) -> PasteResult {
        let decision = PasteCascade.decide(
            text: text,
            hasAccessibility: accessibilityEnabled(),
            bundleID: frontmostBundleID(),
            focusedRole: focusedAXRole()
        )
        return PasteCascade.execute(
            text: text,
            decision: decision,
            backend: RealPasteBackend()
        )
    }

    // MARK: - Environment probes

    /// Bundle identifier of the frontmost app (as reported by NSWorkspace).
    /// Passed to `PasteCascade.decide` where it's currently reserved for
    /// telemetry/logging hooks — the cascade no longer branches on bundle
    /// ID now that the AX-first path has been removed. `nil` when no app
    /// is frontmost or the app has no bundle ID (very rare — mostly
    /// background system helpers).
    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// AX role of the currently-focused UI element, if we can read it.
    /// Returns `nil` when:
    ///   • no focused element is reachable (no frontmost app)
    ///   • the element refuses the role read (some hardened web views)
    ///   • the element reports an empty/unexpected role
    ///
    /// Password fields are normalized to `"AXSecureTextField"` regardless
    /// of whether the OS reports them via the stable role (Safari login,
    /// native password fields) or via the `AXSecureTextField` subrole on
    /// a generic `AXTextField` (some Electron apps and web forms).
    /// `PasteCascade.decide` treats that role as a refusal signal.
    ///
    /// `PasteCascade.decide` treats `nil` the same as "role not in the
    /// editable set" — route to keystrokes rather than gamble on an AX
    /// round-trip we can't validate ahead of time.
    private static func focusedAXRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRaw: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        )
        guard focusErr == .success, let focusedRaw else { return nil }
        let element = focusedRaw as! AXUIElement

        // Subrole first: some apps tag a password field as a generic
        // AXTextField with the secure *subrole*, rather than the stable
        // AXSecureTextField role. We surface both as the same token so
        // HumdrumCore's refusal check catches either form.
        var subroleRaw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleRaw
        ) == .success, let subrole = subroleRaw as? String,
           subrole == "AXSecureTextField" {
            return "AXSecureTextField"
        }

        var roleRaw: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRaw
        )
        guard roleErr == .success else { return nil }
        return roleRaw as? String
    }
}

// MARK: - Real backend

/// Concrete `PasteBackend` used in production. Implements the two cascade
/// stages: keystroke synthesis (primary) and clipboard + ⌘V (fallback).
/// Failures at either stage return `false` so `PasteCascade.execute` can
/// fall through.
private struct RealPasteBackend: PasteBackend {

    // MARK: Stage 1 — Keystroke synthesis

    /// Post unicode key-down events carrying `text` to the system-wide
    /// event tap. This is the same path native text substitution takes,
    /// so Electron apps that swallow AX writes still accept it.
    ///
    /// Implementation notes:
    ///   • Chunked to 16 UTF-16 code units per event.
    ///     `CGEventKeyboardSetUnicodeString` truncates longer strings
    ///     in practice (~20 limit reported in the wild); 16 is well
    ///     under the floor.
    ///   • Unicode payload is attached to the `keyDown` event only;
    ///     the `keyUp` is sent bare. Attaching the payload to both
    ///     causes some Electron renderers (Slack, Discord, Teams) to
    ///     process the string twice, producing doubled characters.
    ///   • 5ms sleep between chunks. Slower renderers (Office for Mac,
    ///     JetBrains IDEs, heavy-DOM Electron apps) occasionally drop
    ///     bursts that arrive within the same run-loop turn. Five ms
    ///     is below a typical user's perception threshold for a full
    ///     dictated chunk and is what Wispr Flow / Superwhisper-style
    ///     apps land on in practice.
    func insertViaKeystrokes(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let utf16 = Array(text.utf16)
        var index = 0
        let chunkSize = 16
        let interChunkDelayUs: useconds_t = 5_000   // 5 ms

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])

            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                return false
            }

            chunk.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buf.count,
                    unicodeString: base
                )
                // Intentionally no payload on keyUp — see doc comment.
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
            if index < utf16.count {
                usleep(interChunkDelayUs)
            }
        }
        return true
    }

    // MARK: Stage 2 — Clipboard + ⌘V with restore

    /// Write `text` to the general pasteboard, synthesize ⌘V, and restore
    /// the previous pasteboard contents after a short delay so the user's
    /// copy buffer survives the paste. Only reached when both earlier
    /// stages fall through — rare in practice but essential for apps that
    /// ignore AX *and* filter synthetic unicode key events (some hardened
    /// security tools, a few kiosk-style web frontends).
    ///
    /// The restore delay needs to be long enough that the receiving app
    /// has finished reading the pasteboard in response to ⌘V. 350ms is
    /// comfortably past the worst case we've observed.
    func insertViaClipboard(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // ⌘V — virtual key 9 is "V" on every Apple keyboard layout.
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            restorePasteboard(pasteboard, snapshot: saved)
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        // Restore on the main queue after the receiving app has had time
        // to pick up the pasteboard contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restorePasteboard(pasteboard, snapshot: saved)
        }
        return true
    }

    // MARK: Pasteboard save/restore

    /// Snapshot of all items on the general pasteboard, preserved as a
    /// per-type `Data` blob so we can write it back verbatim later.
    /// Non-`Data`-representable types (e.g. filesystem promises) are
    /// skipped; restoring them in-process would require reconstructing
    /// the original providers.
    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
