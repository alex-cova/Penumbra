import AppKit
import SwiftUI

extension IDEAppearance {
    /// Chrome animation tokens, and the one place that honours Reduce Motion for them.
    ///
    /// Views use `ideAnimation(_:value:)` and `ideTransition(_:)`, which read
    /// `accessibilityReduceMotion` themselves (so a body that does not animate never reads it).
    /// Model code, which has no environment, goes through `animate(_:_:)`.
    enum Motion {
        /// Hover tints and small state changes.
        static let quick = Animation.easeOut(duration: 0.12)
        /// Filters, disclosure, toasts and panels appearing.
        static let standard = Animation.easeOut(duration: 0.16)
        /// Whole-page changes (empty chat to conversation).
        static let panel = Animation.easeOut(duration: 0.35)

        /// The system-wide Reduce Motion switch, for code outside a view.
        static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// `animation`, or nil when Reduce Motion is on.
        static func resolved(_ animation: Animation) -> Animation? {
            reduceMotion ? nil : animation
        }

        /// `withAnimation` that does not animate under Reduce Motion.
        @MainActor
        static func animate<Result>(_ animation: Animation = standard, _ body: () throws -> Result) rethrows -> Result {
            try withAnimation(resolved(animation), body)
        }

        /// Under Reduce Motion a sliding transition becomes a plain fade.
        static func transition(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : transition
        }
    }
}

private struct IDEAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct IDETransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transition: AnyTransition

    func body(content: Content) -> some View {
        content.transition(IDEAppearance.Motion.transition(transition, reduceMotion: reduceMotion))
    }
}

extension View {
    /// `.animation(_:value:)` that is off while Reduce Motion is on.
    func ideAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(IDEAnimationModifier(animation: animation, value: value))
    }

    /// `.transition(_:)` that falls back to a fade while Reduce Motion is on.
    func ideTransition(_ transition: AnyTransition) -> some View {
        modifier(IDETransitionModifier(transition: transition))
    }
}
