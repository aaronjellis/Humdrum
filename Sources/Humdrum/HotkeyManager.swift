import Foundation
import Carbon.HIToolbox
import AppKit

/// Minimal Swift wrapper around Carbon's RegisterEventHotKey API for a
/// single global hotkey. Carbon hotkeys don't require Accessibility
/// permission and fire reliably from any app or workspace.
///
/// Default binding: ⌥Space (Option + Space) — same as Whisper Flow /
/// Superwhisper. Can be rebound at runtime via `register(keyCode:modifiers:)`.
///
/// Multiple instances can coexist as long as they're constructed with
/// different `id`s (Carbon disambiguates registered hotkeys by the
/// `(signature, id)` pair). The dictation flow uses two: id 1 for the
/// global ⌥Space toggle, id 2 for the conditional ⌥P pause that's only
/// armed while the orb is up.
final class HotkeyManager {

    typealias Handler = () -> Void

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: Handler?

    init(id: UInt32 = 1) {
        self.id = id
    }

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
        static let p:     UInt32 = UInt32(kVK_ANSI_P)        // 35
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
        // ("HDRM" = Humdrum) — macOS uses it for disambiguation if
        // multiple processes register hotkeys. The numeric `id` lets
        // *this* process distinguish multiple bindings owned by
        // different HotkeyManager instances.
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4844_524D), // "HDRM"
            id: id
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
