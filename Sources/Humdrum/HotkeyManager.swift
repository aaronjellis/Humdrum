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
    /// Optional companion handler invoked on `kEventHotKeyReleased`.
    /// Used by PTT to detect end-of-hold without resorting to NSEvent
    /// global monitors, which can't swallow events globally and so leak
    /// raw ⌥Space keystrokes (= macOS non-breaking-space insertion)
    /// through to the focused field.
    private var releaseHandler: Handler?

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
    ///
    /// If `onRelease` is provided, the hotkey also generates release
    /// events (Carbon's `kEventHotKeyReleased`). This is the path PTT
    /// uses — Carbon swallows BOTH press and release at the OS level, so
    /// the focused field never sees the raw ⌥Space keystrokes that
    /// would otherwise insert non-breaking spaces while the user holds
    /// the combo.
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping Handler,
        onRelease: Handler? = nil
    ) -> Bool {
        unregister()
        self.handler = handler
        self.releaseHandler = onRelease

        // When the caller wants release events too, install handlers for
        // both event kinds. Carbon dispatches each kind to the same
        // EventHandlerUPP — we disambiguate inside the callback by
        // reading the event's kind. Keeping a single InstallEventHandler
        // call (with a count of 2) means we still only have one handler
        // ref to clean up on unregister.
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]
        if onRelease != nil {
            eventTypes.append(
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                )
            )
        }

        // Install the event handler (only once; we keep a ref so we can
        // remove it on unregister). The callback fires on the main
        // thread for both pressed and released events; we route each
        // event to the right handler based on its kind.
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let manager = Unmanaged<HotkeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            let kind = GetEventKind(eventRef)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyReleased) {
                    manager.releaseHandler?()
                } else {
                    manager.handler?()
                }
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        // `&eventTypes` on a Swift Array does NOT give us the C-array
        // pointer Carbon expects (it boxes through the inout machinery).
        // Use withUnsafeBufferPointer to grab the contiguous storage's
        // base address directly. The pointer is only valid during the
        // closure call, but InstallEventHandler copies the EventTypeSpec
        // values internally, so we don't need the storage to outlive
        // this scope.
        let installStatus: OSStatus = eventTypes.withUnsafeBufferPointer { buffer in
            // `inNumTypes` imports as `Int` in current SDKs (older
            // headers typed it as the Carbon `ItemCount`/UInt32). Pass
            // `buffer.count` directly — the integer literal `1` worked
            // in the press-only path because Swift coerces literals,
            // but a typed UInt32 doesn't get the same coercion.
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
        }
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
        handler = nil
        releaseHandler = nil
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
