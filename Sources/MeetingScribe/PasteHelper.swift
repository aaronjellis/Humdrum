import Foundation
import AppKit
import ApplicationServices

/// Small helper for injecting text into whatever field currently has focus
/// in the frontmost app. Used by the dictation coordinator so transcribed
/// chunks appear in Claude Desktop / Slack / Teams / etc. as you speak.
///
/// Strategy: write the text to NSPasteboard, then synthesize ⌘V via
/// CGEvent. This is the same approach TextExpander, Raycast, and every
/// major dictation tool uses on macOS. Requires Accessibility permission;
/// without it, CGEventPost silently fails but the clipboard paste still
/// lands.
enum PasteHelper {

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

    /// Writes `text` to the pasteboard and simulates ⌘V. Returns `true`
    /// if we at least managed the clipboard half; the keystroke
    /// simulation is fire-and-forget. The caller is responsible for
    /// showing any "text copied, grant Accessibility permission" UI when
    /// `accessibilityEnabled()` is false.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        let wrote = pb.setString(text, forType: .string)
        guard wrote else { return false }

        // Small delay so the pasteboard update is visible to other apps
        // before we synthesize the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            simulateCommandV()
        }
        return true
    }

    /// Posts ⌘V-down / ⌘V-up to the HID system event tap. Needs
    /// Accessibility permission to actually reach foreground apps on
    /// macOS 10.14+; without it, the events are swallowed and the user
    /// still has the text on their clipboard to paste manually.
    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09   // Virtual key for V
        let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: tapLocation)

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: tapLocation)
    }
}
