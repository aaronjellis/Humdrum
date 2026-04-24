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
    // The panel is intentionally much larger than the orb itself. At
    // peak audio, several layers scale up simultaneously:
    //   – the outer halo blurs ~30 pt past its own frame
    //   – the halo's own scaleEffect pushes to ~1.22×
    //   – the whole stack has another ~1.09× scaleEffect
    // Stacking those on the 260 pt orb means visible diameter can bloom
    // past 400 pt during loud peaks. 460 × 460 leaves comfortable
    // headroom so nothing clips at the panel edge. A VStack below the
    // orb also hosts the optional permission-warning pill.
    private let size = NSSize(width: 460, height: 460)

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
/// A permission-warning pill slides in underneath when we detect that
/// Accessibility isn't granted; without it the orb bounces to the user's
/// voice but typed text never actually lands in the focused field, and
/// that silent failure is exactly what we want to avoid.
struct DictationOverlayView: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var dictation: DictationCoordinator

    // Orb render size (inside the 460pt panel). Smaller than the
    // recorder-widget orb because:
    //   1. The halo + whole-stack scaleEffect can bloom past 2× on
    //      loud peaks. A 180pt base leaves lots of margin so the
    //      glow never clips at the panel edge.
    //   2. The whole orb also scales DOWN to zero as silence
    //      accumulates (see `silenceScale`), so the floor for
    //      legibility mid-shrink matters less than generous bloom
    //      headroom.
    private let orbSize: CGFloat = 180

    var body: some View {
        VStack(spacing: 8) {
            // Single TimelineView drives everything that animates
            // continuously: the indicators (chunk-pulse + countdown
            // ring) and the silence-scale transform on the orb
            // itself. One timeline source means the scale and the
            // ring are rendered from the exact same `now`, so they
            // stay perfectly in sync frame-to-frame.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let scale = silenceScale(now: timeline.date)
                ZStack {
                    AudioVisualizer(
                        levels: manager.audioLevels,
                        isActive: manager.isRecording,
                        size: orbSize
                    )
                    .frame(width: orbSize, height: orbSize)

                    indicators(now: timeline.date)
                        .frame(width: orbSize, height: orbSize)
                        .allowsHitTesting(false)
                }
                // Shrink (and fade) the orb as silence elapses toward
                // the user's configured timeout. When the user speaks
                // again, `lastSpeechTime` advances, elapsed resets,
                // and the orb springs back to full size. `opacity`
                // matching `scale` hides the tiny residual dot at the
                // very end rather than leaving a pinprick behind.
                .scaleEffect(scale)
                .opacity(Double(scale))
            }
            .frame(width: orbSize, height: orbSize)

            if !dictation.accessibilityGranted {
                permissionPill
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: dictation.accessibilityGranted)
    }

    /// Scale factor (1.0 → 0.0) that tracks how much of the current
    /// silence window has elapsed. Same anchor/total logic as the
    /// countdown ring — they're two readouts of the same clock:
    ///
    ///   • User hasn't spoken yet → anchor = `sessionStartedAt`,
    ///     total = `noSpeechTimeoutSeconds`.
    ///   • User has spoken → anchor = `lastSpeechTime`,
    ///     total = `silenceTimeoutSeconds`.
    ///
    /// A 0.4 s grace at the top keeps the orb at full size through
    /// natural inter-word pauses rather than flickering down on
    /// every breath.
    private func silenceScale(now: Date) -> CGFloat {
        let grace: TimeInterval = 0.4
        let anchor: Date?
        let total: TimeInterval

        if let last = dictation.lastSpeechTime {
            anchor = last
            total = dictation.silenceTimeoutSeconds
        } else if let start = dictation.sessionStartedAt {
            anchor = start
            total = dictation.noSpeechTimeoutSeconds
        } else {
            anchor = nil
            total = 0
        }

        guard let anchor, total > grace else { return 1.0 }
        let elapsed = now.timeIntervalSince(anchor)
        if elapsed <= grace { return 1.0 }
        let span = total - grace
        let progress = min(1.0, max(0.0, (elapsed - grace) / span))
        return CGFloat(1.0 - progress)
    }

    /// Combined chunk-pulse and silence-countdown visuals. Rendered
    /// inside a TimelineView so both animations are driven entirely
    /// by the current wall-clock time relative to coordinator events.
    @ViewBuilder
    private func indicators(now: Date) -> some View {
        ZStack {
            chunkPulse(now: now)
            silenceCountdown(now: now)
        }
    }

    /// Ring that expands outward from the orb edge and fades out when
    /// a chunk of Whisper text has just been pasted into the focused
    /// field. Fires for ~0.9 s per chunk. If the user is dictating
    /// quickly the rings overlap — that's the intended "I'm firing
    /// off text right now" feel.
    @ViewBuilder
    private func chunkPulse(now: Date) -> some View {
        if let pastedAt = dictation.lastChunkPastedAt {
            let age = now.timeIntervalSince(pastedAt)
            let duration: TimeInterval = 0.9
            if age >= 0, age < duration {
                let progress = age / duration
                let scale = 0.96 + CGFloat(progress) * 0.30
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: orbSize * scale, height: orbSize * scale)
                    .opacity(1.0 - progress)
                    .blur(radius: 0.8)
                    .shadow(color: AppTheme.accent.opacity(0.7), radius: 10)
            }
        }
    }

    /// A ring around the orb that shrinks (via `trim`) from full to
    /// empty as the auto-close silence timer counts down. Two modes:
    ///
    ///   • If the user has already spoken, the anchor is the last
    ///     speech/paste moment and the total is `silenceTimeoutSeconds`.
    ///   • If the user hasn't spoken yet (hot-key press but no audio),
    ///     the anchor is `sessionStartedAt` and the total is
    ///     `noSpeechTimeoutSeconds`.
    ///
    /// A small 0.4 s grace period at the top prevents the ring from
    /// flickering on natural inter-word pauses.
    @ViewBuilder
    private func silenceCountdown(now: Date) -> some View {
        let grace: TimeInterval = 0.4
        let (anchor, total) = countdownAnchor()

        if let anchor, total > grace {
            let elapsed = now.timeIntervalSince(anchor)
            if elapsed >= grace {
                let span = total - grace
                let progress = min(1.0, max(0.0, (elapsed - grace) / span))
                let trim = max(0.0, 1.0 - progress)
                Circle()
                    .trim(from: 0, to: trim)
                    .stroke(
                        AppTheme.accent.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))           // start at 12 o'clock
                    .frame(width: orbSize * 0.94,
                           height: orbSize * 0.94)
                    .shadow(color: AppTheme.accent.opacity(0.6), radius: 6)
                    .opacity(0.85)
            }
        }
    }

    /// Non-@ViewBuilder helper that resolves `(anchor, total)` for the
    /// countdown ring. Lives outside the builder body because SwiftUI's
    /// result-builder machinery can't see past imperative assignment
    /// statements — every line inside `@ViewBuilder` must be a view
    /// expression.
    private func countdownAnchor() -> (Date?, TimeInterval) {
        if let last = dictation.lastSpeechTime {
            return (last, dictation.silenceTimeoutSeconds)
        }
        if let start = dictation.sessionStartedAt {
            return (start, dictation.noSpeechTimeoutSeconds)
        }
        return (nil, 0)
    }

    /// Shown only when Accessibility isn't granted. Explains in one
    /// line why no text is appearing and how to fix it. Pointer events
    /// are passed through on the panel level, so this is purely visual.
    private var permissionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
            Text("Grant Accessibility to paste — see Settings → Dictation")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(AppTheme.danger.opacity(0.92))
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.danger.opacity(0.45), radius: 10, y: 3)
    }
}
