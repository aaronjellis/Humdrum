import SwiftUI
import AppKit
import HumdrumCore

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
    // orb also hosts the optional `StatusPill` (permission warning,
    // paste failure, or silent-drop notice).
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
/// Layered visuals:
///   • `AudioVisualizer`    — multi-color halo reactive to the mic.
///   • `ListeningIndicator` — small "Listening…" label inside the orb
///                            so the user has a constant visual that
///                            we're capturing audio, even when their
///                            voice isn't peaking the visualizer.
///   • `StatusPill`         — single pill below the orb that surfaces
///                            any condition the user needs to act on:
///                            Accessibility missing, paste failed,
///                            paste silently dropped. Hidden in the
///                            happy path.
struct DictationOverlayView: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var dictation: DictationCoordinator

    // Orb render size (inside the 460pt panel). Smaller than the
    // recorder-widget orb because the halo + whole-stack scaleEffect
    // can bloom past 2× on loud peaks. A 180pt base leaves lots of
    // margin so the glow never clips at the panel edge.
    private let orbSize: CGFloat = 180

    var body: some View {
        VStack(spacing: 8) {
            // Single TimelineView drives every continuous animation:
            // the orb's breathing/aberration motion, the chunk-pulse
            // confirmation flash, the silence-countdown ring, and the
            // post-paste wind-down scale. One timeline source means
            // everything is rendered from the same `now`, so phases
            // stay perfectly aligned with the engine's silence
            // monitor (which uses the same `lastSpeechTime` anchor).
            //
            // Wind-down model:
            //   Phase 1 — `[0, T]`: full-size orb, ring drains.
            //             T = `silenceTimeoutSeconds`. At elapsed = T
            //             the silence monitor fires `stop()` →
            //             snapshot finalize → ⌘V paste lands.
            //   Phase 2 — `[T, 2T]`: post-paste wind-down. The orb
            //             scales 1.0 → 0 across `stop()`'s linger
            //             window. The engine is already stopped and
            //             the text is in the focused field; this is
            //             a courtesy fade only.
            //
            // The user-facing meaning of `silenceTimeoutSeconds` is
            // "how long of silence triggers the paste" — paste
            // happens at T, not 2T. The phase-2 visual is purely
            // cosmetic teardown. (Earlier iterations let users speak
            // during phase 2 to reactivate; that affordance was
            // removed when we moved paste to end-of-phase-1, since
            // the text has already been delivered by the time phase 2
            // starts and continuing would require another paste.)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let scale = windDownScale(now: timeline.date)
                let breath = breathingScale(now: timeline.date)
                let drift = aberrationOffset(now: timeline.date)
                let tilt = aberrationRotation(now: timeline.date)
                ZStack {
                    AudioVisualizer(
                        levels: manager.audioLevels,
                        isActive: manager.isRecording,
                        size: orbSize
                    )
                    .frame(width: orbSize, height: orbSize)

                    // "Listening…" inside the orb. Replaces the
                    // word-ticker experiment (the ticker visibly
                    // squashed inside the orb and stutter-paused
                    // because Whisper commits don't tick on every
                    // word). The label is gated on detected speech:
                    // visible while the user is talking, fades out
                    // within ~300ms once they stop. The orb's own
                    // breathing/aberration motion (below) is the
                    // always-on "I'm running" signal.
                    ListeningIndicator(
                        orbDiameter: orbSize,
                        dictation: dictation,
                        now: timeline.date
                    )

                    indicators(now: timeline.date)
                        .frame(width: orbSize, height: orbSize)
                        .allowsHitTesting(false)
                }
                // Order matters: aberration transforms first (in the
                // orb's local space), then the wind-down scale, then
                // opacity. That way the breathing/drift motion shrinks
                // with the orb during phase 2 instead of bouncing
                // around its old origin.
                .rotationEffect(tilt)
                .offset(drift)
                .scaleEffect(breath)
                .scaleEffect(scale)
                .opacity(Double(scale))
            }
            .frame(width: orbSize, height: orbSize)

            if let status = currentStatus {
                StatusPill(status: status)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(status)   // re-fire transition when state flips
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: currentStatus)
    }

    /// Resolve the single most-important status condition to surface in
    /// the pill. Order matters: a paste failure is more urgent than a
    /// permission warning (the user just lost a dictation; tell them
    /// where the text is). On success, returns nil → pill is hidden.
    private var currentStatus: StatusPill.Status? {
        switch dictation.pasteOutcome {
        case .failed:      return .pasteFailed
        case .silentDrop:  return .silentDrop
        case .succeeded:
            return dictation.accessibilityGranted ? nil : .accessibilityMissing
        }
    }

    /// Always-on breathing scale — a slow primary inhale/exhale plus
    /// a faster, smaller secondary wave with a phase offset. The two
    /// waves never align cleanly (irrational period ratio), so the
    /// orb never quite repeats itself: the eye reads it as organic
    /// "alive" motion rather than a metronomic pulse. Amplitudes are
    /// kept under ~3% combined so the breathing reads as personality
    /// without competing with AudioVisualizer's louder peak response.
    private func breathingScale(now: Date) -> CGFloat {
        let t = now.timeIntervalSinceReferenceDate
        let primary = sin(t * 2 * .pi / 3.5) * 0.020
        let secondary = cos(t * 2 * .pi / 1.7 + 0.7) * 0.008
        return CGFloat(1.0 + primary + secondary)
    }

    /// A barely-perceptible 2D drift, applied as a translation on the
    /// orb stack. Two independent slow waves on x and y so the orb
    /// traces a Lissajous-ish path rather than oscillating along an
    /// axis. ±1.2 pt is small enough not to look like jitter, large
    /// enough to register peripherally as "this thing is alive."
    private func aberrationOffset(now: Date) -> CGSize {
        let t = now.timeIntervalSinceReferenceDate
        let x = sin(t * 2 * .pi / 4.3) * 1.2
        let y = cos(t * 2 * .pi / 5.7 + 1.3) * 1.0
        return CGSize(width: x, height: y)
    }

    /// Subtle rotational tilt — ±0.6° at a long period. Pairs with
    /// the offset above to give the orb a feeling of suspension in
    /// space rather than rigid attachment to the panel. The angle
    /// stays small enough that the AudioVisualizer's internal
    /// asymmetric specular highlight doesn't read as wobbling badly.
    private func aberrationRotation(now: Date) -> Angle {
        let t = now.timeIntervalSinceReferenceDate
        return .degrees(sin(t * 2 * .pi / 6.1) * 0.6)
    }

    /// Phase-2 (wind-down) orb scale. See `body` for the model:
    /// returns 1.0 throughout phase 1 and the no-speech-yet window,
    /// then linearly shrinks 1.0 → 0 across phase 2 once the
    /// configured silence timeout has elapsed since last speech.
    ///
    /// Under the commit-at-phase-1 cadence (post-paste-pivot v2), this
    /// scale animates during `stop()`'s linger after the paste has
    /// already landed — the engine is stopped, `lastSpeechTime` is
    /// frozen, and elapsed naturally crosses into the phase 2 window.
    /// The "speak again to reactivate" affordance from the previous
    /// design is intentionally gone: by the time the user could speak
    /// again the paste is already in their focused field.
    private func windDownScale(now: Date) -> CGFloat {
        // Pre-speech window: hold full size; the no-speech timeout
        // fires its own teardown without a visual wind-down.
        guard let last = dictation.lastSpeechTime else { return 1.0 }
        let elapsed = now.timeIntervalSince(last)
        let phaseOne = dictation.silenceTimeoutSeconds
        if elapsed <= phaseOne { return 1.0 }
        // Phase 2: shrink 1.0 → 0 over another silenceTimeoutSeconds.
        // Total auto-stop firing happens at 2T (see evaluateAudio).
        let phaseTwo = phaseOne
        guard phaseTwo > 0 else { return 0 }
        let progress = min(1.0, max(0.0, (elapsed - phaseOne) / phaseTwo))
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
    /// the dictation's transcript has just been pasted into the focused
    /// field. Under commit-once cadence this fires exactly once per
    /// dictation, on success — a single satisfying confirmation flash.
    /// (Function and trigger field names still say "chunk" for legacy
    /// reasons; the pulse animation is identical to what we used in
    /// the streaming-paste era when it fired per Whisper commit.)
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

}

// MARK: - StatusPill

/// Single pill below the orb that surfaces any user-actionable condition
/// at the end of (or during) a dictation. Only one state shows at a time
/// — see `DictationOverlayView.currentStatus` for the precedence order.
///
/// All three states use the danger-pink fill so the pill always reads as
/// "something needs your attention." The icon and copy disambiguate:
///
///   • `.accessibilityMissing` — orb is up but won't be able to paste.
///     Copy points the user to Settings.
///   • `.pasteFailed`          — cascade refused (no AX, password field,
///                               etc) or errored. Text was preserved on
///                               the clipboard; copy tells them so.
///   • `.silentDrop`           — cascade reported success but the
///                               receiving app dropped the ⌘V on the
///                               floor (Electron, hardened web views).
///                               Same remedy as `.pasteFailed`.
///
/// Auto-dismiss is handled by the orb lifecycle itself: failure paths
/// linger the orb 4.5s before hiding (see DictationCoordinator.stop()),
/// which is plenty of time to read and act on the pill. The pill never
/// dismisses early — if the user ⌘Vs while it's still up, that's fine,
/// the clipboard has the text.
struct StatusPill: View {
    enum Status: Hashable {
        case accessibilityMissing
        case pasteFailed
        case silentDrop

        var iconName: String {
            switch self {
            case .accessibilityMissing: return "exclamationmark.triangle.fill"
            case .pasteFailed:          return "exclamationmark.circle.fill"
            case .silentDrop:           return "exclamationmark.circle.fill"
            }
        }

        var message: String {
            switch self {
            case .accessibilityMissing:
                return "Grant Accessibility to paste — see Settings → Dictation"
            case .pasteFailed:
                return "Couldn't paste — text on your clipboard, ⌘V to insert"
            case .silentDrop:
                return "That app didn't take the paste — ⌘V to insert"
            }
        }
    }

    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.iconName)
                .font(.system(size: 10, weight: .bold))
            Text(status.message)
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
        .allowsHitTesting(false)
    }
}

// MARK: - ListeningIndicator

/// Small "Listening" label with three trailing dots that pulse in
/// sequence, rendered inside the dictation orb. Pure visual feedback
/// that audio capture is hearing you specifically — distinct from the
/// orb's own breathing/aberration motion, which is the always-on
/// "engine is running" signal.
///
/// Visibility is gated on `dictation.lastSpeechTime`: the indicator
/// fades in within one render frame of speech being detected and
/// fades out within ~300 ms of silence resuming. This prevents the
/// label from sitting frozen on screen during long thinking pauses
/// (which read as "is the app stuck?") and matches what the user
/// asked for: the dots should pop up only when there's actually
/// noise.
///
/// The label is purely visual — `allowsHitTesting(false)` keeps it
/// out of the cursor path so the underlying app still gets pointer
/// events.
private struct ListeningIndicator: View {
    /// Orb render diameter. Font size scales as a fraction so the
    /// label looks balanced if the orb's size is ever tuned.
    let orbDiameter: CGFloat

    /// The dictation coordinator, observed for `lastSpeechTime`
    /// updates. The parent's TimelineView already drives the redraws
    /// — we don't need a local TimelineView here since `now` is
    /// passed in.
    @ObservedObject var dictation: DictationCoordinator

    /// Current frame time, supplied by the parent's TimelineView so
    /// the recency check stays in lock-step with the wind-down scale
    /// and ring-countdown animations.
    let now: Date

    /// Per-dot pulse cadence. 1.2 s feels like a natural breathing
    /// rhythm — fast enough to read as alive, slow enough not to
    /// feel jittery.
    private let cycleSeconds: Double = 1.2

    /// Lag between successive dots, as a fraction of the cycle. At
    /// 0.18 the second and third dots feel like they're chasing the
    /// first without piling up on top of each other.
    private let dotLag: Double = 0.18

    /// How long we hold full opacity after the last detected speech
    /// before starting the fade-out. Roughly matches the silence
    /// monitor's 200 ms tick so a single missed RMS sample doesn't
    /// drop the dots mid-utterance.
    private let holdSeconds: Double = 0.2

    /// Fade-out duration once `holdSeconds` has elapsed. 300 ms total
    /// (hold + fade ≈ 0.5 s) reads as "snaps off as soon as you
    /// stop talking" without strobing on natural inter-syllable
    /// silences.
    private let fadeSeconds: Double = 0.3

    private var fontSize: CGFloat { max(11, orbDiameter * 0.085) }

    var body: some View {
        let visibility = speechVisibility()
        HStack(alignment: .center, spacing: 1) {
            Text("Listening")
                .foregroundStyle(.white.opacity(0.85))
            ForEach(0..<3, id: \.self) { i in
                Text(".")
                    .foregroundStyle(.white.opacity(dotOpacity(i)))
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: .rounded))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 0)
        .opacity(visibility)
        .frame(width: orbDiameter, height: orbDiameter)
        .allowsHitTesting(false)
    }

    /// 1.0 while speech is fresh, linearly fading to 0 across
    /// `fadeSeconds` once the recency exceeds `holdSeconds`. Returns
    /// 0 if the user hasn't spoken yet — the orb's breathing motion
    /// already signals "I'm here," no need for the dots to crowd
    /// the no-speech window.
    private func speechVisibility() -> Double {
        guard let last = dictation.lastSpeechTime else { return 0 }
        let recency = now.timeIntervalSince(last)
        if recency <= holdSeconds { return 1.0 }
        let progress = (recency - holdSeconds) / fadeSeconds
        return max(0.0, 1.0 - progress)
    }

    /// Sine-wave opacity for a given dot. Phase = cycle position
    /// shifted by `dotLag * i`. Output mapped to [0.2, 1.0] so dots
    /// never fully disappear (a flickered-out dot reads as a layout
    /// bug, not an animation).
    private func dotOpacity(_ index: Int) -> Double {
        let secs = now.timeIntervalSinceReferenceDate
        let phase = (secs / cycleSeconds - Double(index) * dotLag) * 2.0 * .pi
        let normalized = (sin(phase) + 1.0) / 2.0          // 0..1
        return 0.2 + 0.8 * normalized
    }
}
