import Foundation
import AppKit
import Carbon.HIToolbox

/// Watches global keyboard events for ⌥+Space press-and-hold activation.
///
/// Carbon's `RegisterEventHotKey` only fires on press, not release. PTT
/// needs both edges, so we observe NSEvent's `keyDown` / `keyUp` /
/// `flagsChanged` directly via paired global + local monitors.
///
/// Why both monitors:
/// - Global covers the typical PTT scenario: user is in another app
///   (their target text field), holds ⌥Space. NSEvent's global
///   monitor only sees events when *another* app has focus.
/// - Local covers the rarer case where Humdrum's own window is
///   foregrounded when the user triggers PTT. Local sees events when
///   *this* app has focus.
///
/// The monitor maintains its own state machine — coordinator code only
/// sees the debounced `onPress` (both keys went held) and `onRelease`
/// (either key went unheld) callbacks. Re-fires of `onPress` from
/// keyboard autorepeat are filtered.
///
/// `pressedFired` debounces both directions. Without it, a user who
/// holds ⌥, taps Space, taps Space again (still holding ⌥) would emit
/// only one `onPress` for the first tap — but `pressedFired` flips
/// false on the release between taps, so the second tap re-fires
/// correctly. The bookkeeping is "did we tell the coordinator we're
/// in a held combo right now?" — flips true on entry, false on exit.
@MainActor
final class PushToTalkMonitor {
    typealias Handler = () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// True while ⌥ is currently held. Updated from `flagsChanged`.
    /// Either physical option key (left/right) counts.
    private var optionHeld: Bool = false

    /// True while Space is currently held. Updated from `keyDown`/`keyUp`
    /// of `kVK_Space`.
    private var spaceHeld: Bool = false

    /// True between an emitted `onPress` and its matching `onRelease`.
    /// Prevents re-firing `onPress` when the user, e.g., re-presses Space
    /// while still holding ⌥, *unless* the previous combo has been
    /// released first (which clears this flag).
    private var pressedFired: Bool = false

    private var onPress: Handler?
    private var onRelease: Handler?

    /// Installs the global + local NSEvent monitors. Replaces any
    /// previously installed monitors. Idempotent.
    func install(onPress: @escaping Handler, onRelease: @escaping Handler) {
        uninstall()
        self.onPress = onPress
        self.onRelease = onRelease

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

        // AppKit dispatches both global and local NSEvent monitor
        // closures on the main thread, so we can call our @MainActor-
        // isolated `handle` synchronously by asserting isolation. We
        // need synchronous access in the local monitor anyway because
        // the swallow decision (return nil vs return event) has to be
        // made before this closure returns.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            // Swallow the event when we're handling it as a PTT trigger
            // so it doesn't propagate into Humdrum's own responder
            // chain. ⌥Space inside our own UI shouldn't insert a
            // non-breaking space if PTT is the user's chosen activation
            // — the whole point of the binding is that this combo means
            // "dictate."
            if Self.isPTTRelevant(event) {
                return nil
            }
            return event
        }
    }

    /// Tears down both monitors and resets state. Safe to call multiple
    /// times — each call is idempotent on already-cleared state.
    func uninstall() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        // Reset combo state so re-installing doesn't think the combo is
        // mid-hold from a previous activation.
        optionHeld = false
        spaceHeld = false
        pressedFired = false
        onPress = nil
        onRelease = nil
    }

    /// Static helper: does this event match a key we care about? Used by
    /// the local monitor to decide whether to swallow.
    private static func isPTTRelevant(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            // We can't easily tell if it's *option* changing without
            // tracking state, but flagsChanged is rare enough — and our
            // own UI doesn't bind anything modifier-only — that
            // swallowing all flagsChanged events while PTT is armed is
            // harmless. (Modifier-only events don't insert text or
            // trigger menu shortcuts; they just update the global
            // modifier state, which the OS does separately from our
            // monitor.)
            return true
        case .keyDown, .keyUp:
            return event.keyCode == UInt16(kVK_Space)
        default:
            return false
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let now = event.modifierFlags.contains(.option)
            if now != optionHeld {
                optionHeld = now
                evaluate()
            }
        case .keyDown:
            // `isARepeat` filters keyboard autorepeat — without this,
            // holding Space would fire repeated keyDown events at the
            // OS repeat rate. The first non-repeat downstroke is what
            // we count.
            if event.keyCode == UInt16(kVK_Space), !event.isARepeat {
                if !spaceHeld {
                    spaceHeld = true
                    evaluate()
                }
            }
        case .keyUp:
            if event.keyCode == UInt16(kVK_Space) {
                if spaceHeld {
                    spaceHeld = false
                    evaluate()
                }
            }
        default:
            break
        }
    }

    private func evaluate() {
        if optionHeld && spaceHeld {
            if !pressedFired {
                pressedFired = true
                onPress?()
            }
        } else if pressedFired {
            // Either ⌥ or Space went unheld while we were in a held
            // combo — that's the PTT release signal.
            pressedFired = false
            onRelease?()
        }
    }

    deinit {
        // deinit can't await @MainActor; we just rip the monitors.
        // NSEvent.removeMonitor is documented as safe to call from any
        // thread.
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
