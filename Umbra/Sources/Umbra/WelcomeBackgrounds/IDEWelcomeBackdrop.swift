import SwiftUI

/// The animated backdrop shared by the welcome page and AI mode's empty states.
/// Reads `welcomeReduceMotion` (system Reduce Motion or Umbra's "Disable animation"
/// preference, set by the parent) and holds still while the window isn't active.
struct IDEWelcomeBackdrop: View {
    let kind: IDEWelcomeBackground
    let parallax: IDEWelcomeParallax
    let animationDisabled: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        backdrop
            .environment(\.welcomeReduceMotion, systemReduceMotion || animationDisabled)
    }

    @ViewBuilder private var backdrop: some View {
        switch kind {
        case .starfield:
            IDEWelcomeStarfield(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .deepSpace:
            IDEWelcomeDeepSpace(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .gradientWaves:
            IDEWelcomeGradientWaves(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .moltenMetal:
            IDEWelcomeMoltenMetal(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .galaxy:
            IDEWelcomeGalaxy(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .liquidChrome:
            IDEWelcomeLiquidChrome(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .evilEye:
            IDEWelcomeEvilEye(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .pixelSnow:
            IDEWelcomePixelSnow(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .particles:
            IDEWelcomeParticles(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .dotField:
            IDEWelcomeDotField(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .aeroShards:
            IDEWelcomeAeroShards(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .balatro:
            IDEWelcomeBalatro(parallax: parallax)
                .background(IDEAppearance.ColorToken.editor)
        case .none:
            IDEAppearance.ColorToken.editor
        }
    }
}
