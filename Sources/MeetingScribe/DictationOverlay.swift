import SwiftUI
import AppKit

// MARK: - Non-focusable floating panel

/// An NSPanel subclass that will NEVER become the key window. Critical
/// for the dictation overlay — the orb floats above everything but the
/// text field you were editing in the target app keeps focus, so our
/// simulated ⌘V lands in the right place.
///
/// Set up as a fully transparent panel: no title bar, no traffic lights,
/// no card background — just the orb view, floating.
final class DictationPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true          // clicks pass through to underneath
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        worksWhenModal = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Controller

/// Owns a `DictationPanel` that hosts the SwiftUI visualizer. Positions
/// the panel near the bottom of the active screen (centered horizontally)
/// so it doesn't obscure the text field the user is dictating into.
@MainActor
final class DictationOverlayController {

    private var panel: DictationPanel?
    private let size = NSSize(width: 220, height: 220)

    func show<Content: View>(_ content: Content) {
        hide()
        let panel = DictationPanel(
            contentRect: NSRect(origin: .zero, size: size)
        )
        panel.contentView = NSHostingView(rootView: content)
        // Make sure the SwiftUI layer is also transparent
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = .clear
        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Bottom-centered on whichever screen currently contains the mouse
    /// cursor (fallback: `NSScreen.main`). 80 pt above the Dock so on a
    /// screen with Dock visible it doesn't overlap.
    private func position(panel: DictationPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Overlay view

/// Just the orb, on a transparent window — no card, no stroke, no text.
/// The user wanted a single polished visual element; that's exactly
/// what this provides.
struct DictationOverlayView: View {
    @ObservedObject var manager: TranscriptionManager

    var body: some View {
        AudioVisualizer(
            levels: manager.audioLevels,
            isActive: manager.isRecording
        )
        .frame(width: 200, height: 200)
        .preferredColorScheme(.dark)
    }
}
