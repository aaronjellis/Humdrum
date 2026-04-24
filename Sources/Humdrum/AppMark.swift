import SwiftUI

/// The Humdrum app mark — an emerald orb on a dark squircle, matching
/// the PNG/icns app icon. Rendered in pure SwiftUI so it stays crisp at
/// any point size and doesn't require shipping a second raster asset
/// just to put the logo in the sidebar.
///
/// Use this anywhere you'd previously have drawn a green rectangle +
/// SF Symbol "waveform" placeholder — sidebar header, About tab,
/// empty-state heroes. Keeps every in-app surface in sync with what
/// Finder / Dock / Spotlight show for the .app itself.
///
/// Example:
///
///     AppMark(size: 42)
///     AppMark(size: 64)
///
/// The proportions inside the mark scale with `size`, so there's only
/// one knob to turn at the call site.
struct AppMark: View {
    var size: CGFloat

    // macOS Big Sur+ app icons use a specific superellipse; a
    // continuous-curvature RoundedRectangle with corner radius ≈ 22.4%
    // of the shorter side is a close visual match and renders
    // efficiently.
    private var cornerRadius: CGFloat { size * 0.2237 }

    // Orb fills ~72% of the tile so there's a clean halo margin to the
    // squircle edge. Matches the breathing room in the .icns artwork.
    private var orbDiameter: CGFloat { size * 0.72 }

    var body: some View {
        ZStack {
            // Dark squircle base. Two-stop vertical gradient adds just
            // enough depth that the icon doesn't look like a flat chip
            // on a dark sidebar background — which would otherwise
            // disappear.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.10, blue: 0.11),
                            Color(red: 0.03, green: 0.04, blue: 0.045)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

            // Outer halo glow behind the orb. Sitting on a Circle with
            // a radial gradient gives a softer falloff than a plain
            // shadow and doesn't clip against the squircle bounds.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.accent.opacity(0.55),
                            AppTheme.accent.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: orbDiameter * 0.35,
                        endRadius: orbDiameter * 0.95
                    )
                )
                .frame(width: orbDiameter * 1.4, height: orbDiameter * 1.4)
                .blendMode(.plusLighter)

            // Emerald body. Radial gradient with the light source
            // biased up-and-to-the-left mirrors the icns artwork —
            // inner mix of emerald + mint, deepening to forest at
            // the edge.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.55, green: 1.00, blue: 0.82),   // core hotspot
                            Color(red: 0.14, green: 0.86, blue: 0.52),   // mid emerald
                            Color(red: 0.02, green: 0.38, blue: 0.26)    // deep edge
                        ],
                        center: UnitPoint(x: 0.35, y: 0.32),
                        startRadius: 0,
                        endRadius: orbDiameter * 0.62
                    )
                )
                .frame(width: orbDiameter, height: orbDiameter)

            // Specular highlight — a small bright ellipse in the upper
            // left quadrant, blurred, for the glossy "it's a sphere"
            // read at small sizes.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.85),
                            Color.white.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: orbDiameter * 0.22
                    )
                )
                .frame(width: orbDiameter * 0.42, height: orbDiameter * 0.30)
                .offset(x: -orbDiameter * 0.16, y: -orbDiameter * 0.18)
                .blur(radius: size * 0.01)
                .blendMode(.plusLighter)
        }
        .frame(width: size, height: size)
        // One unified shadow under the whole squircle — cheaper than
        // per-layer shadows and gives the mark enough weight to sit on
        // any background without looking pasted on.
        .shadow(color: AppTheme.accentGlow.opacity(0.4),
                radius: size * 0.18, x: 0, y: size * 0.03)
    }
}

#Preview {
    HStack(spacing: 20) {
        AppMark(size: 32)
        AppMark(size: 42)
        AppMark(size: 64)
        AppMark(size: 96)
    }
    .padding()
    .background(Color.black)
}
