import Foundation
import AppKit
import Carbon.HIToolbox

/// Watches global keyboard events for ⌥+Space press-and-hold activation.
///
/// **Why Carbon and not NSEvent monitors:** an earlier revision of this
/// file used `NSEvent.addGlobalMonitorForEvents` to detect press/release.
/// That worked for *detection*, but global NSEvent monitors are
/// observation-only — they cannot swallow events. So while the user
/// held ⌥Space, the OS continued delivering ⌥Space keystrokes (= a
/// non-breaking space character) to whatever app had focus, replacing
/// the user's selected text and then autorepeating to fill the field
/// with spaces. The fix: register ⌥Space as a Carbon hotkey, which
/// the OS routes to *us* instead of the focused app — same mechanism
/// the toggle-mode binding uses to avoid the same problem.
///
/// Carbon's `RegisterEventHotKey` supports both `kEventHotKeyPressed`
/// and `kEventHotKeyReleased`; `HotkeyManager` was extended to wire
/// the release callback. Together that gives us debounced press/release
/// edges for ⌥Space with zero leakage of raw keystrokes to the
/// focused field.
///
/// We DO still install a tiny local NSEvent monitor for the rare case
/// where Humdrum's own window is foregrounded — local monitors *can*
/// swallow, and we need to make sure ⌥Space inside our own UI doesn't
/// insert a non-breaking space into a Humdrum text field either. The
/// local monitor doesn't drive the press/release callbacks (Carbon
/// does); it exists purely to consume the event so it doesn't hit our
/// own responder chain.
///
/// The monitor maintains its own `pressedFired` debounce so the
/// coordinator only sees one matched (press, release) pair per
/// physical hold, even if Carbon ever decides to autorepeat the
/// pressed event.
@MainActor
final class PushToTalkMonitor {
    typealias Handler = () -> Void

    /// Carbon hotkey on ⌥Space, configured to fire callbacks for both
    /// press and release. Distinct id (3) from the toggle-mode binding
    /// (id 1) and pause hotkey (id 2) so Carbon disambiguates them.
    private let hotkey = HotkeyManager(id: 3)

    /// Local-only monitor that swallows ⌥Space inside Humdrum's own
    /// window. Global swallowing is Carbon's job; this fills in the
    /// "our app is foregrounded" gap so ⌥Space doesn't insert a
    /// non-breaking space into our own text fields when PTT is the
    /// active activation surface.
    private var localMonitor: Any?

    /// True between an emitted `onPress` and its matching `onRelease`.
    /// Carbon should already give us clean edges, but this guard makes
    /// us robust to any Carbon weirdness (e.g. synthesized release
    /// events on focus changes) and gives the deinit a clean exit.
    private var pressedFired: Bool = false

    private var onPress: Handler?
    private var onRelease: Handler?

    /// Installs the Carbon hotkey + local NSEvent monitor. Replaces any
    /// previously installed monitors. Idempotent.
    func install(onPress: @escaping Handler, onRelease: @escaping Handler) {
        uninstall()
        self.onPress = onPress
        self.onRelease = onRelease

        let registered = hotkey.register(
            keyCode: HotkeyManager.Key.space,
            modifiers: HotkeyManager.Modifier.option.rawValue,
            handler: { [weak self] in
                guard let self else { return }
                if !self.pressedFired {
                    self.pressedFired = true
                    self.onPress?()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                if self.pressedFired {
                    self.pressedFired = false
                    self.onRelease?()
                }
            }
        )

        if !registered {
            // Carbon registration can fail if another process already
            // owns ⌥Space exclusively (rare). The user will notice
            // because pressing ⌥Space won't do anything; the right
            // remedy is to flip activation mode in Settings or quit the
            // conflicting app. We log via NSLog — Diagnostics may not
            // have its routing set up if this fires very early.
            NSLog("[Humdrum] PushToTalkMonitor: Carbon registration of ⌥Space failed.")
        }

        // Local monitor — swallows ⌥Space inside our own window so it
        // doesn't insert a non-breaking space into a Humdrum text
        // field. Carbon already swallows globally; this is purely the
        // "we're frontmost" complement.
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.keyCode == UInt16(kVK_Space),
               event.modifierFlags.contains(.option) {
                return nil
            }
            return event
        }
    }

    /// Tears down the Carbon hotkey + local monitor and resets state.
    /// Safe to call multiple times — each call is idempotent on already-
    /// cleared state.
    func uninstall() {
        hotkey.unregister()
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        pressedFired = false
        onPress = nil
        onRelease = nil
    }

    deinit {
        // deinit can't await @MainActor; we just rip the local monitor
        // and let HotkeyManager's own deinit handle the Carbon teardown.
        // NSEvent.removeMonitor is documented as safe from any thread.
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
