import SwiftUI

/// Palette inspired by Configonaut: near-black cool surfaces, a single
/// emerald accent, crimson/pink for secondary + destructive, muted
/// gray-teal secondary text, thin low-opacity borders on cards.
enum AppTheme {

    // Surfaces
    static let background      = Color(red: 0.035, green: 0.045, blue: 0.050)   // app bg (#0A0C0D)
    static let sidebar         = Color(red: 0.048, green: 0.063, blue: 0.068)   // sidebar (#0C1012)
    static let panel           = Color(red: 0.055, green: 0.078, blue: 0.082)   // card (#0E1415)
    static let panelElevated   = Color(red: 0.075, green: 0.098, blue: 0.104)   // card hover / code block
    static let codeBlock       = Color(red: 0.040, green: 0.058, blue: 0.062)

    // Borders — Configonaut uses very thin, low-opacity borders and adds a
    // colored one to active / selected elements.
    static let border          = Color.white.opacity(0.06)
    static let borderStrong    = Color.white.opacity(0.12)

    // Text
    static let textPrimary     = Color.white.opacity(0.94)
    static let textSecondary   = Color(red: 0.56, green: 0.61, blue: 0.62)
    static let textTertiary    = Color(red: 0.36, green: 0.41, blue: 0.42)

    // Accents
    static let accent          = Color(red: 0.10, green: 0.85, blue: 0.52)      // emerald (#1ADB85-ish)
    static let accentDim       = Color(red: 0.10, green: 0.85, blue: 0.52).opacity(0.70)
    static let accentSoft      = Color(red: 0.10, green: 0.85, blue: 0.52).opacity(0.12)
    static let accentGlow      = Color(red: 0.10, green: 0.85, blue: 0.52).opacity(0.32)
    static let accentBorder    = Color(red: 0.10, green: 0.85, blue: 0.52).opacity(0.35)

    static let danger          = Color(red: 0.97, green: 0.36, blue: 0.49)      // crimson-pink
    static let dangerSoft      = Color(red: 0.97, green: 0.36, blue: 0.49).opacity(0.14)
    static let dangerBorder    = Color(red: 0.97, green: 0.36, blue: 0.49).opacity(0.35)

    static let recording       = danger

    // Visualizer circles stay multi-color per the user's request; they
    // still read as celebratory/organic against the near-black stage.
    static let circle1         = Color(red: 1.00, green: 0.45, blue: 0.72)
    static let circle2         = Color(red: 0.62, green: 0.50, blue: 1.00)
    static let circle3         = Color(red: 0.20, green: 0.90, blue: 0.78)

    // Subtle stage backdrop with an emerald tint in the corner
    static let stageGradient = LinearGradient(
        colors: [
            Color(red: 0.038, green: 0.055, blue: 0.060),
            Color(red: 0.050, green: 0.085, blue: 0.078)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Reusable card modifier

/// The rounded, thin-bordered card style seen throughout Configonaut.
struct CardBackground: ViewModifier {
    var tinted: Bool = false           // if true, slight emerald tint
    var danger: Bool = false           // if true, crimson tint (for Inactive panel)
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        danger ? AppTheme.dangerBorder :
                        (tinted ? AppTheme.accentBorder : AppTheme.border),
                        lineWidth: 0.7
                    )
            )
    }
}

extension View {
    func configonautCard(tinted: Bool = false, danger: Bool = false, cornerRadius: CGFloat = 14) -> some View {
        self.modifier(CardBackground(tinted: tinted, danger: danger, cornerRadius: cornerRadius))
    }
}
