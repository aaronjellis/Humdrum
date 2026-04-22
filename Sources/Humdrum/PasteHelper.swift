import Foundation
import AppKit
import ApplicationServices

/// Small helper for injecting text into whatever field currently has focus
/// in the frontmost app. Used by the dictation coordinator so transcribed
/// chunks appear in Claude Desktop / Slack / Teams / etc. as you speak.
///
/// **Single strategy: direct AX insert.**
///
/// We find the focused UI element via `AXUIElementCreateSystemWide`
/// and set `kAXSelectedTextAttribute` to the new text — the same
/// mechanism native macOS text substitution uses. Requires
/// Accessibility permission.
///
/// This deliberately does NOT fall back to clipboard + synthesized
/// ⌘V. Two reasons:
///   1. The ⌘V path overwrites the user's clipboard on every chunk,
///      which is a surprising side effect.
///   2. If AX insert isn't working, a keystroke fallback papering
///      over the problem hides a real misconfiguration — we'd rather
///      surface a visible failure than silently pretend it worked.
///
/// If AX insert fails, the coordinator shows the warning pill so the
/// user knows to check Accessibility permission (or switch to a field
/// that supports text insertion).
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

    // MARK: - Paste result

    /// Outcome of a paste attempt. The coordinator flashes the chunk
    /// pulse on `.inserted` and surfaces the permission/focus warning
    /// pill on `.failed`.
    enum PasteResult {
        case inserted   // AX set-selected-text succeeded
        case failed     // no trust, no focused element, or the element doesn't support text insertion
    }

    // MARK: - Paste

    /// Attempts to insert `text` into the focused field via the
    /// Accessibility API. Does NOT touch `NSPasteboard`. Returns
    /// `.inserted` on success, `.failed` otherwise.
    @discardableResult
    static func paste(_ text: String) -> PasteResult {
        guard !text.isEmpty else { return .failed }
        guard accessibilityEnabled() else { return .failed }
        return insertViaAccessibility(text) ? .inserted : .failed
    }

    // MARK: - AX insert

    /// Tries to set `kAXSelectedTextAttribute` on the currently-focused
    /// UI element. Returns `false` if:
    ///   • no focused element is reachable (rare — no frontmost app)
    ///   • the element doesn't support text insertion (e.g. a canvas)
    ///   • the app filters AX writes from external processes
    ///
    /// `kAXSelectedTextAttribute` replaces the current selection (or
    /// inserts at the caret if nothing is selected), which is exactly
    /// what we want for progressive dictation. Writing to
    /// `kAXValueAttribute` instead would replace the entire field
    /// contents — never do that.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()

        var focusedRaw: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        )
        guard focusedErr == .success, let focusedRaw else { return false }
        // Force-cast is safe — AX returns an AXUIElement for this key.
        let element = focusedRaw as! AXUIElement

        let setErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return setErr == .success
    }
}
