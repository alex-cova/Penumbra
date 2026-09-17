import CoreGraphics
import Foundation

/// Design contract for typewriter scrolling on ``TextView``.
///
/// Typewriter mode keeps the active line pinned at a fixed vertical fraction of the viewport
/// while the document scrolls beneath the caret. ``TextView`` adds bottom overscroll in
/// `preferredContentSize` and applies the anchor offset through `justScrollRangeToVisible`.
enum TypewriterScrollingPolicy {
    // MARK: - When anchoring runs

    /// Typewriter anchoring is a variant of automatic caret scrolling, not an independent
    /// scroll mode. Both flags must be enabled.
    ///
    /// Anchoring runs only for zero-length ranges (caret moves). Non-empty ranges keep the
    /// standard minimum-reveal scroll so find/replace, go-to-definition, and selection
    /// adjustments are not fighting the anchor.
    static func shouldAnchor(isTypewriterScrollingEnabled: Bool,
                             isAutomaticScrollEnabled: Bool,
                             isSuspendedByUser: Bool,
                             rangeLength: Int) -> Bool {
        isTypewriterScrollingEnabled && isAutomaticScrollEnabled && !isSuspendedByUser && rangeLength == 0
    }

    // MARK: - Anchor geometry

    /// The vertical position in **content coordinates** that should align with
    /// ``TextView/typewriterAnchorFraction`` in the viewport.
    ///
    /// Uses the document line's vertical center (`line.yPosition + lineHeight / 2`), not the
    /// raw caret rect, so wrapped lines and varying line heights stay stable.
    static func anchorY(lineYPosition: CGFloat, lineHeight: CGFloat) -> CGFloat {
        lineYPosition + lineHeight / 2
    }

    /// Target `contentOffset.y` that places `anchorY` at `anchorFraction` of the visible
    /// viewport height (after insets). Callers clamp the result to legal scroll bounds.
    static func contentOffsetY(anchorY: CGFloat,
                               viewportHeight: CGFloat,
                               anchorFraction: CGFloat) -> CGFloat {
        anchorY - viewportHeight * anchorFraction
    }

    /// Virtual padding above the document. At least half a viewport is retained at every anchor
    /// so the first visual line can reach the requested position.
    static func requiredTopOverscroll(viewportHeight: CGFloat, anchorFraction: CGFloat) -> CGFloat {
        max(viewportHeight / 2, viewportHeight * anchorFraction)
    }

    /// Extra vertical overscroll below the document so the last visual line can still reach
    /// `anchorFraction` up the viewport. At least half a viewport is always retained.
    static func requiredBottomOverscroll(viewportHeight: CGFloat, anchorFraction: CGFloat) -> CGFloat {
        max(viewportHeight / 2, viewportHeight * (1 - anchorFraction))
    }

    // MARK: - Multi-caret

    /// When multiple carets are active, anchor to the **primary** caret — the first range in
    /// ``TextView/selectedRanges``. Union/fit-all carets is intentionally out of scope for v1.

    // MARK: - Manual scroll

    /// While the user scrolls via trackpad, mouse wheel, or minimap interaction, anchoring is
    /// suspended so the viewport stays where they left it. The next key press in the editor
    /// clears the suspension and typewriter anchoring resumes on subsequent caret moves.

    // MARK: - Horizontal

    /// Typewriter adjusts vertical offset only. Horizontal reveal continues to use the
    /// existing logic in `contentOffsetForScrollingToVisibleRect`.
}
