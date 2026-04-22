import Foundation
import Carbon.HIToolbox
import AppKit

/// Minimal Swift wrapper around Carbon's RegisterEventHotKey API for a
/// single global hotkey. Carbon hotkeys don't require Accessibility
/// permission and fire reliably from any app or workspace.
///
/// Default binding: ⌥Space (Option + Space) — same as Whisper Flow /
/// Superwhisper. Can be rebound at runtime via `register(keyCode:modifiers:)`.
final class HotkeyManager {

    typealias Handler = () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: Handler?

    /// Convenience wrappers for the most common modifier bit masks (from
    /// <Carbon/HIToolbox/Events.h>).
    enum Modifier: UInt32 {
        case command = 0x100   // cmdKey
        case shift   = 0x200   // shiftKey
        case option  = 0x800   // optionKey
        case control = 0x1000  // controlKey
    }

    /// Convenience keyCodes for space + common letters.
    enum Key {
        static let space: UInt32 = UInt32(kVK_Space)         // 49
    }

    /// Registers the given hotkey. Replaces any previously registered
    /// binding. The handler is invoked on the main thread every time the
    /// key combination fires.
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping Handler
    ) -> Bool {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install the event handler (only once; we keep a ref so we can
        // remove it on unregister).
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            DispatchQueue.main.async { manager.handler?() }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr, let handlerRef else { return false }
        self.eventHandler = handlerRef

        // Register the actual hotkey. Signature is an arbitrary FourCC
        // ("MSCD" = Meeting Scribe Dictation) — macOS uses it for
        // disambiguation if multiple processes register hotkeys.
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4D53_4344), // "MSCD"
            id: 1
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            removeHandler()
            return false
        }
        self.hotKeyRef = ref
        return true
    }

    /// Removes the registered hotkey (no-op if none).
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        removeHandler()
    }

    private func removeHandler() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
