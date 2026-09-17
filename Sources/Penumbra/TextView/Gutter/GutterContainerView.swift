@preconcurrency import AppKit
import Foundation

/// `LayoutManager`'s container for the gutter's chrome (background, line numbers, folding ribbon).
///
/// This view is normally set `isUserInteractionEnabled = false` so mouse events over the gutter
/// (line numbers, background) fall through to whatever's behind it in the same scrolling content
/// view — namely `TextInputView` — which is what lets a text selection drag started in the document
/// continue smoothly as the mouse crosses into the gutter. `hitTest(_:)` on the disabled base
/// `UIView` returns `nil` unconditionally, which stops AppKit's hit-test walk from ever recursing
/// into this view's subviews at all, regardless of their own `isUserInteractionEnabled` — so a
/// child that genuinely needs clicks (the folding ribbon) can't just flip its own flag.
///
/// `interactiveRect` carves out a single exception: when set (to the ribbon's current frame, in
/// this view's own bounds coordinates), points inside it fall through to the normal recursive
/// hit-test instead, letting the ribbon (which stays enabled) claim them, while every other point
/// keeps today's pass-through behavior unchanged.
final class GutterContainerView: UIView {
    var interactiveRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveRect, let superview {
            let localPoint = convert(point, from: superview)
            if interactiveRect.contains(localPoint) {
                return super.hitTest(point)
            }
        }
        return isUserInteractionEnabled ? super.hitTest(point) : nil
    }
}
