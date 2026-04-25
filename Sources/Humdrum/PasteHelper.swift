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
/// the two concrete strategies (clipboard + ⌘V → keystroke synthesis).
/// Every decision-level concern lives in HumdrumCore so it can be
/// unit-tested without AppKit. This file is the thin I/O layer.
///
/// Why clipboard-first, and why not AX:
///   Both Superwhisper and Wispr Flow ship with clipboard + ⌘V as their
///   default insertion path; keystroke simulation is an opt-in advanced
///   setting in both. The reason is that ⌘V is the single OS-blessed
///   insertion event that every mainstream target — Chrome, Electron
///   (Slack, Discord, Teams, Claude desktop), Office, JetBrains, Safari,
///   Notes, Terminal — accepts, whereas synthetic unicode key events
///   can be silently filtered by Electron renderers and by some
///   hardened web views. We validated that the hard way: keystroke-first
///   looked clean in tests but silently no-op'd in Claude desktop. AX
///   `kAXSelectedTextAttribute` writes are worse still — documented to
///   report `.success` while silently dropping on too many target apps
///   (Chromium, Electron, Office, JetBrains) to keep at any stage of
///   the cascade.
///
///   1. **Clipboard + ⌘V.** Writes to `NSPasteboard.general`,
///      synthesizes ⌘V, then restores the previous clipboard contents
///      after a short delay so the user's copied text isn't obliterated.
///      Primary strategy for every non-refused paste.
///   2. **Keystroke synthesis.** Tail fallback, reached only when the
///      CGEvent source for ⌘V can't be constructed (very rare). Posts
///      unicode characters via `CGEventKeyboardSetUnicodeString` into
///      the system-wide event tap. Does NOT touch the clipboard.
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
    /// switches on to flash the success ring-pulse or surface the
    /// failure StatusPill (and to drive the post-paste AX silent-drop
    /// verification on the `.inserted` branch).
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

    /// Character count of the currently-focused element's text, if AX
    /// will tell us. Used by the dictation coordinator to verify
    /// post-paste that the receiving app actually accepted the ⌘V —
    /// the receiver's text length should grow by at least the length
    /// of the dictated string. Returns `nil` when the element refuses
    /// the read, which is the common case for Electron and Chromium
    /// renderers; the coordinator treats `nil` as "unknown, assume
    /// success" rather than firing a false-positive silent-drop
    /// warning.
    ///
    /// We try `kAXNumberOfCharactersAttribute` first (the dedicated
    /// length attribute, supported by native Cocoa text views) and
    /// fall back to reading `kAXValue` and measuring its length, which
    /// works for elements that expose the value but not the length
    /// attribute (some web text inputs).
    static func focusedTextLength() -> Int? {
        let system = AXUIElementCreateSystemWide()
        var focusedRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw else { return nil }
        let element = focusedRaw as! AXUIElement

        var lenRaw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &lenRaw
        ) == .success, let n = lenRaw as? Int {
            return n
        }

        // Fallback: AXValue string length. Some web inputs expose the
        // value but not a dedicated character count.
        var valueRaw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRaw
        ) == .success, let s = valueRaw as? String {
            return s.count
        }
        return nil
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
/// stages: clipboard + ⌘V (primary) and keystroke synthesis (fallback).
/// Failures at either stage return `false` so `PasteCascade.execute` can
/// fall through.
private struct RealPasteBackend: PasteBackend {

    // MARK: Stage 2 — Keystroke synthesis (fallback)

    /// Post unicode key-down events carrying `text` to the system-wide
    /// event tap. Reached only when clipboard + ⌘V can't construct a
    /// CGEvent source (rare) — retained as the tail fallback because a
    /// few niche apps rebind ⌘V (vim in a terminal) or filter synthetic
    /// paste events while still accepting typed unicode.
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

    // MARK: Stage 1 — Clipboard + ⌘V with restore (primary)

    /// Write `text` to the general pasteboard, synthesize ⌘V, and restore
    /// the previous pasteboard contents after a short delay so the user's
    /// copy buffer survives the paste. Primary strategy for every
    /// non-refused paste — matches what Superwhisper and Wispr Flow do
    /// by default. ⌘V is the single OS-blessed insert event that every
    /// mainstream target (Chrome, Electron, Office, JetBrains, Safari,
    /// Terminal) accepts; synthetic unicode key events can be silently
    /// filtered by Electron renderers.
    ///
    /// The restore delay needs to be long enough that the receiving app
    /// has finished reading the pasteboard in response to ⌘V. We're
    /// pasting exactly once per dictation now, so the restore window
    /// can be generous — 3.0s, matching Superwhisper. See the comment
    /// on the actual `asyncAfter` call below for the full reasoning.
    func insertViaClipboard(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard change time to propagate before we fire
        // ⌘V. Electron renderers (Claude desktop, Slack, Discord) and
        // some Cocoa apps observe pasteboard change notifications and
        // can drop a ⌘V that arrives on the same run-loop turn as the
        // `setString` — the receiver still sees the *old* contents.
        // 15ms is below user-perception threshold for a dictation
        // chunk and matches what Wispr Flow does.
        usleep(15_000)

        // Post ⌘V as an explicit 4-event sequence: cmd-down, V-down,
        // V-up, cmd-up. We used to only set `.maskCommand` on the V
        // events and post those two, but that's silently dropped by
        // some Electron renderers (Claude desktop was the motivating
        // case) which listen for actual modifier keyDown events, not
        // the flag. Virtual keys: 0x37 is Left Command, 9 is "V" on
        // every Apple keyboard layout.
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 9,    keyDown: true),
              let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 9,    keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            restorePasteboard(pasteboard, snapshot: saved)
            return false
        }
        // Both V events still carry the cmd flag — some apps key off
        // `event.flags` rather than the modifier-event history.
        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)

        // Restore on the main queue after the receiving app has had
        // time to pick up the pasteboard contents. We're now in the
        // commit-once world (one paste per dictation, not one per
        // Whisper commit), so a longer restore window is free —
        // there's no back-pressure from the next paste. 3.0s matches
        // Superwhisper's known-good value; their telemetry says it's
        // the floor at which Electron renderers' lazy pasteboard
        // reads are reliably done. Wispr Flow holds at ~500ms but
        // they have telemetry to verify it for them; we'd rather
        // pay 2.5 extra seconds of "your copied text comes back
        // slightly later" than risk a missed paste because Slack's
        // observer fired at +900ms.
        //
        // Note: the dictation coordinator's failure path (silent drop
        // or cascade refusal) re-writes the dictation text to the
        // clipboard immediately and again at +3.5s, so the user's
        // ⌘V still sees the dictation text even if this restore wins
        // the race. See `DictationCoordinator.stop()`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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
