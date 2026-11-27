import SwiftUI

/// Studio tokens for the photo editor.
///
/// Ported from Hextech's `PhotoStudio.Photo` family (`Theme+Photo.swift`, `Theme+Metrics.swift`,
/// `Theme+Typography.swift`, `Theme+Motion.swift`). The photo editor holds its canvas and inspector
/// at a fixed neutral gray whatever the system appearance is — a photo's perceived tone shifts
/// against a changing surround — so these colors deliberately do not adapt to light/dark mode.
/// The inspector root also forces `\.colorScheme` to `.dark` so AppKit-backed controls inherit
/// matching styling.
///
/// Anything drawn on `Photo` surfaces takes its foreground from this same set; mixing in
/// `.primary`/`.secondary` would invert in light mode. Spacing reuses `IDEAppearance.Spacing`
/// (identical values); radius/typography/motion mirror the Hextech values.
enum PhotoStudio {
    /// Fixed neutral studio chrome. See the enum-level note on why these do not adapt.
    enum Photo {
        /// Module-stack ground.
        static let panel = Color(white: 0.16)
        /// Recessed wells — histogram, tone curve, graph backgrounds.
        static let panelDeep = Color(white: 0.11)
        /// Hairline separators between modules and inside wells.
        static let hairline = Color(white: 1.0, opacity: 0.10)
        /// Module titles and slider names.
        static let label = Color(white: 0.66)
        /// Numeric readouts and active text.
        static let value = Color(white: 0.92)
        /// Slider track (unfilled).
        static let track = Color(white: 0.32)
        /// Void behind the image on the canvas.
        static let canvasVoid = Color(white: 0.13)
    }

    typealias Spacing = IDEAppearance.Spacing

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
    }

    enum Typography {
        static let caption: Font = .caption
        static let caption2: Font = .caption2
        static let captionEmphasis: Font = .caption.weight(.semibold)
        static let metric: Font = .caption.monospacedDigit().weight(.semibold)
    }

    enum Motion {
        static let quick: Animation = .snappy(duration: 0.15)
        static let standard: Animation = .snappy(duration: 0.2)
        static let emphasized: Animation = .snappy(duration: 0.28)
        static let reduced: Animation = .easeOut(duration: 0.1)
    }

    /// The photo editor's accent. Hextech used a graphics-category tint; Umbra uses its accent.
    static var accent: Color { IDEAppearance.ColorToken.accent }
}

private struct PhotoAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? PhotoStudio.Motion.reduced : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that drops to a short crossfade under Reduce Motion.
    func photoAnimation<Value: Equatable>(
        _ animation: Animation = PhotoStudio.Motion.standard,
        value: Value
    ) -> some View {
        modifier(PhotoAnimationModifier(animation: animation, value: value))
    }
}
