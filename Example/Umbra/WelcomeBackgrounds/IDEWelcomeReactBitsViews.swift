import SwiftUI

struct IDEWelcomeGradientWaves: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeGradientWavesRenderer()
        }
    }
}

struct IDEWelcomeMoltenMetal: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeMoltenMetalRenderer()
        }
    }
}

struct IDEWelcomeGalaxy: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeGalaxyRenderer()
        }
    }
}

struct IDEWelcomeLiquidChrome: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeLiquidChromeRenderer()
        }
    }
}

struct IDEWelcomePixelSnow: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomePixelSnowRenderer()
        }
    }
}

struct IDEWelcomeEvilEye: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeEvilEyeRenderer()
        }
    }
}

struct IDEWelcomeAeroShards: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeMetalShaderView(parallax: parallax, isPaused: reduceMotion || controlActiveState == .inactive) {
            IDEWelcomeAeroShardsRenderer()
        }
    }
}
