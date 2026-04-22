import SwiftUI

/// A cohesive glowing-sphere visualizer.
///
/// Key change from the previous version: there are NO independently-
/// rotating elements. Everything that gives the orb life moves as part of
/// the same sphere — otherwise the eye reads it as "strokes rotating on
/// top of each other" instead of "one irregular lit object."
///
/// Layering (back → front):
///   1. Outer halo        — soft blurred ambient glow
///   2. Middle glow       — nearer glow that brightens with audio
///   3. Glass sphere body — off-center radial gradient (the "globe")
///   4. Internal caustics — cloud of blurred blobs clipped to the sphere;
///                         gives it irregular bright regions like fluid
///                         light inside, not worms on top
///   5. Concentric rings  — two soft rings that PULSE in unison
///                         (no rotation)
///   6. Inner specular    — subtle off-center highlight, the 3D cue
///   7. Rim light         — thin illuminated edge
///
/// A single very slow 3D wobble is applied to the whole stack so the orb
/// feels alive but reads as ONE object.
struct AudioVisualizer: View {

    let levels: [Float]
    let isActive: Bool

    /// Size the orb is drawn at. All internal measurements scale from
    /// this so callers can plug it into a smaller or larger frame
    /// without hard-coded constants overflowing.
    var size: CGFloat = 200

    // MARK: - Palette
    //
    // `core` stays pure white. The other three colors are derived from a
    // slowly-drifting hue so the orb cycles gently between green → teal →
    // blue → purple shades instead of being a single static tint.

    private let core = Color.white

    /// Per-frame palette. Call with the current TimelineView time.
    private struct Palette {
        let accent: Color   // main tint
        let hot:    Color   // bright highlight variant
        let deep:   Color   // dim variant used for sphere base
    }

    private func palette(for t: TimeInterval) -> Palette {
        // Two sines at different periods → non-periodic smooth drift
        // through the cool-color range. 40 s and 67 s periods keep the
        // cycle slow enough to feel subtle but noticeable.
        let base = 0.46
        let drift = sin(t * 0.155) * 0.18 + cos(t * 0.093) * 0.12
        let hue   = min(0.82, max(0.20, base + drift))
        return Palette(
            accent: Color(hue: hue, saturation: 0.78, brightness: 0.82),
            hot:    Color(hue: hue, saturation: 0.30, brightness: 1.00),
            deep:   Color(hue: hue, saturation: 0.78, brightness: 0.50)
        )
    }

    // MARK: - Static "personality" of the orb

    private struct Blob: Hashable {
        let orbitRadius: Double
        let orbitSpeed: Double
        let phase: Double
        let bobAmp: Double
        let bobSpeed: Double
        let baseSize: Double
        let opacity: Double
    }

    @State private var blobs: [Blob]

    init(levels: [Float], isActive: Bool, size: CGFloat = 200) {
        self.levels = levels
        self.isActive = isActive
        self.size = size
        _blobs = State(initialValue: (0..<9).map { _ in
            Blob(
                orbitRadius: .random(in: 6 ... 22),
                orbitSpeed: .random(in: -0.22 ... 0.22),
                phase:      .random(in: 0 ..< (2 * .pi)),
                bobAmp:     .random(in: 2.5 ... 6.0),
                bobSpeed:   .random(in: 0.4 ... 1.4),
                baseSize:   .random(in: 22 ... 44),
                opacity:    .random(in: 0.14 ... 0.24)
            )
        })
    }

    // MARK: - Body

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rawLevel = avgLevel()
            let level = pow(rawLevel, 0.6)
            let p = palette(for: t)

            ZStack {
                outerHalo(level: level, t: t, palette: p)
                middleGlow(level: level, t: t, palette: p)
                glassSphere(level: level, palette: p)
                internalCaustics(t: t, level: level, palette: p)
                pulseRings(t: t, level: level, palette: p)
                innerSpecular(level: level, t: t, palette: p)
                rimLight(level: level, palette: p)
            }
            .frame(width: size, height: size)
            // Subtle whole-orb wobble so the sphere feels alive but the
            // rotation is shared across every layer → it still reads as
            // ONE object.
            .rotation3DEffect(
                .degrees(sin(t * 0.35) * 5),
                axis: (0.3, 1.0, 0.0)
            )
            .scaleEffect(1.0
                         + CGFloat(sin(t * 0.9)) * 0.018
                         + level * 0.07)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)           // clicks pass through to controls
        .accessibilityHidden(true)
    }

    // MARK: - Layers (all dimensions scale from `size`)

    @ViewBuilder
    private func outerHalo(level: CGFloat, t: TimeInterval, palette p: Palette) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: p.accent.opacity(0.45), location: 0),
                        .init(color: p.accent.opacity(0.12), location: 0.55),
                        .init(color: .clear,                 location: 1.0)
                    ]),
                    center: .center,
                    startRadius: size * 0.10,
                    endRadius: size * 0.55
                )
            )
            .blur(radius: size * 0.11)
            .frame(width: size, height: size)
            .scaleEffect(1.0 + CGFloat(sin(t * 0.7)) * 0.04 + level * 0.18)
    }

    @ViewBuilder
    private func middleGlow(level: CGFloat, t: TimeInterval, palette p: Palette) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: p.hot.opacity(0.22 + Double(level) * 0.35), location: 0),
                        .init(color: p.accent.opacity(0.18), location: 0.45),
                        .init(color: .clear,                 location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 4,
                    endRadius: size * 0.38
                )
            )
            .blur(radius: size * 0.05)
            .frame(width: size * 0.73, height: size * 0.73)
            .scaleEffect(1.0 + level * 0.10)
    }

    @ViewBuilder
    private func glassSphere(level: CGFloat, palette p: Palette) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: core.opacity(0.30),     location: 0.00),
                        .init(color: p.hot.opacity(0.28),    location: 0.32),
                        .init(color: p.accent.opacity(0.22), location: 0.72),
                        .init(color: p.deep.opacity(0.15),   location: 0.93),
                        .init(color: .clear,                 location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.38, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.36
                )
            )
            .blur(radius: 2.0)
            .frame(width: size * 0.65, height: size * 0.65)
    }

    /// Cloud of blurred blobs inside the sphere. Each blob drifts on a
    /// small orbit and bobs radially; heavy blur + masking + additive
    /// blending fuses them into organic caustic-like bright regions —
    /// nothing reads as a discrete element.
    @ViewBuilder
    private func internalCaustics(t: TimeInterval, level: CGFloat, palette p: Palette) -> some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for blob in blobs {
                let angle = blob.phase + t * blob.orbitSpeed
                let bob = sin(t * blob.bobSpeed + blob.phase) * blob.bobAmp
                let r = blob.orbitRadius + bob
                let x = center.x + CGFloat(cos(angle) * r)
                let y = center.y + CGFloat(sin(angle) * r)
                let s = blob.baseSize * (1.0 + Double(level) * 0.30)
                let rect = CGRect(
                    x: x - CGFloat(s / 2),
                    y: y - CGFloat(s / 2),
                    width: CGFloat(s),
                    height: CGFloat(s)
                )
                let op = blob.opacity * (1.0 + Double(level) * 0.5)
                ctx.fill(
                    Path(ellipseIn: rect),
                    with: .color(p.hot.opacity(op))
                )
            }
        }
        .frame(width: size * 0.7, height: size * 0.7)
        .blur(radius: size * 0.07)
        .mask(Circle().frame(width: size * 0.60, height: size * 0.60))
        .blendMode(.plusLighter)
    }

    /// Two gentle rings that *pulse* (grow / shrink) together. No
    /// rotation. Reads as the sphere breathing light out, not orbiting
    /// objects.
    @ViewBuilder
    private func pulseRings(t: TimeInterval, level: CGFloat, palette p: Palette) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                let pulse = sin(t * 0.85 + Double(i) * 1.1) * 0.5 + 0.5
                let r = size * (0.24 + Double(i) * 0.05) + CGFloat(pulse) * size * 0.015

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                p.accent.opacity(0.08),
                                p.hot.opacity(0.45),
                                p.accent.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                    .frame(width: r * 2, height: r * 2)
                    .blur(radius: 0.7)
                    .opacity(0.30 + Double(level) * 0.35 + pulse * 0.12)
            }
        }
    }

    @ViewBuilder
    private func innerSpecular(level: CGFloat, t: TimeInterval, palette p: Palette) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: core.opacity(0.55), location: 0),
                        .init(color: p.hot.opacity(0.22), location: 0.5),
                        .init(color: .clear,              location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.10
                )
            )
            .blur(radius: size * 0.03)
            .frame(width: size * 0.20, height: size * 0.20)
            .offset(x: -size * 0.07, y: -size * 0.065)
            .scaleEffect(1.0 + level * 0.4 + CGFloat(sin(t * 1.4)) * 0.06)
    }

    @ViewBuilder
    private func rimLight(level: CGFloat, palette p: Palette) -> some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .clear,
                        p.hot.opacity(0.55 + Double(level) * 0.35),
                        p.accent.opacity(0.35),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.85
            )
            .frame(width: size * 0.65, height: size * 0.65)
            .blur(radius: 0.35)
    }

    // MARK: - Helpers

    private func avgLevel() -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let s = levels.reduce(0, +)
        return CGFloat(max(0, min(1.1, s / Float(levels.count))))
    }
}
