import CoreGraphics
import Foundation

/// The complete coordinate transform between the editor's scroll space and the minimap's own
/// drawing space, as a pure value type so every mapping is unit-testable without a window.
///
/// The design mirrors VS Code: the viewport **indicator** is placed first, always inside the
/// drawn content — `indicatorY ∈ [0, min(boundsHeight, scaledDocumentHeight) - indicatorHeight]`
/// for every input — and the minimap's drawn content is then offset by whatever amount keeps the
/// rows the indicator frames aligned with the rows currently visible in the editor. Nothing here
/// can push the indicator off screen, let it drift away from the bars it sits over, or slide the
/// bars themselves when the whole document already fits in the minimap, regardless of
/// `textContainerInset`, typewriter overscroll, line wrapping, or folding — those all live inside
/// `documentHeight`.
struct MinimapGeometry {
    /// Height of the minimap view itself, in points.
    let boundsHeight: CGFloat
    /// Height of the editor's visible viewport, in points.
    let viewportHeight: CGFloat
    /// The editor's current vertical scroll offset.
    let contentOffsetY: CGFloat
    /// The editor's minimum legal scroll offset (`-contentInset.top`; normally `0`).
    let minimumContentOffsetY: CGFloat
    /// The editor's maximum legal scroll offset.
    let maximumContentOffsetY: CGFloat
    /// The full scrollable document height in editor points — `max(scrollView.contentSize.height,
    /// textContainerInset.top + lineManager.contentHeight + textContainerInset.bottom)`. The
    /// `max` covers the one-runloop lag where `lineManager.contentHeight` is already fresh but
    /// `contentSize` has not been re-applied yet (see `TextView.handleContentSizeUpdateIfNeeded`).
    let documentHeight: CGFloat
    /// The editor's top text-container inset, so document y-positions map to the same origin the
    /// editor uses.
    let textContainerInsetTop: CGFloat
    /// Points of minimap height per point of editor height. Typically `minimapRowHeight /
    /// estimatedLineHeight`.
    let scale: CGFloat
    /// Lower bound on the drawn indicator height so it stays grabbable on huge documents.
    let minIndicatorHeight: CGFloat

    var isValid: Bool {
        documentHeight > 0 && viewportHeight > 0 && boundsHeight > 0 && scale > 0
    }

    /// Total minimap height the whole document would occupy at `scale`.
    var scaledDocumentHeight: CGFloat {
        documentHeight * scale
    }

    private var mainScrollRange: CGFloat {
        max(maximumContentOffsetY - minimumContentOffsetY, 0)
    }

    /// `0` at the top of the document, `1` at the bottom.
    var progress: CGFloat {
        guard mainScrollRange > 0 else {
            return 0
        }
        return min(max((contentOffsetY - minimumContentOffsetY) / mainScrollRange, 0), 1)
    }

    var indicatorHeight: CGFloat {
        // A document shorter than the viewport can't fill the box — frame the bars that
        // exist rather than overhanging them. (No effect once the document is taller than
        // the viewport, which is the scrollable case.)
        min(max(min(viewportHeight, documentHeight) * scale, minIndicatorHeight), boundsHeight)
    }

    /// The indicator's travel range — how far its top can move. Bounded by the content
    /// actually drawn: when the whole document fits in the minimap the bars stay put and only
    /// the indicator moves, so travel is the scaled document's height, not the minimap's.
    /// Using `boundsHeight` unconditionally drives `contentOffset` negative on a short but
    /// scrollable document and slides every bar down the view.
    private var indicatorTravel: CGFloat {
        max(min(boundsHeight, scaledDocumentHeight) - indicatorHeight, 0)
    }

    var indicatorY: CGFloat {
        progress * indicatorTravel
    }

    func indicatorRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: indicatorY, width: width, height: indicatorHeight)
    }

    /// How far the minimap's drawn content is scrolled up, in minimap points. Defined as
    /// "scaled viewport top minus indicator top", which is what keeps the drawn rows aligned
    /// with the indicator.
    var contentOffset: CGFloat {
        (contentOffsetY - minimumContentOffsetY) * scale - indicatorY
    }

    /// Top edge, in minimap view coordinates, of the bar for a line at document y-position `y`.
    func bandY(forLineYPosition y: CGFloat) -> CGFloat {
        (textContainerInsetTop + y) * scale - contentOffset
    }

    /// Height, in minimap view coordinates, of a bar representing `documentHeight` points of
    /// document. Callers pass a single line's height (clamped so wrapped lines still draw a
    /// thin bar).
    func bandHeight(forDocumentHeight height: CGFloat) -> CGFloat {
        max(height * scale, 1)
    }

    /// The document y-range whose bars can intersect the minimap's visible height. Used to seed
    /// the row walk; the lower bound is clamped to `0`.
    var visibleDocumentYRange: ClosedRange<CGFloat> {
        let top = max(contentOffset / scale - textContainerInsetTop, 0)
        let bottom = (contentOffset + boundsHeight) / scale - textContainerInsetTop
        return top ... max(top, bottom)
    }

    // MARK: - Inverse mappings (mouse handling)

    private func clampContentOffsetY(_ y: CGFloat) -> CGFloat {
        min(max(y, minimumContentOffsetY), maximumContentOffsetY)
    }

    /// Target `contentOffset.y` that centers the viewport on a click at `localY` in the minimap.
    func contentOffsetY(forClickAtLocalY localY: CGFloat) -> CGFloat {
        let travel = indicatorTravel
        guard travel > 0 else {
            return contentOffsetY
        }
        let clickProgress = min(max((localY - indicatorHeight / 2) / travel, 0), 1)
        return clampContentOffsetY(minimumContentOffsetY + clickProgress * mainScrollRange)
    }

    /// Target `contentOffset.y` while dragging the indicator by `deltaLocalY` from a scroll
    /// offset of `startContentOffsetY`. Keeps the grabbed point under the cursor.
    func contentOffsetY(forDragDelta deltaLocalY: CGFloat, from startContentOffsetY: CGFloat) -> CGFloat {
        let travel = indicatorTravel
        guard travel > 0 else {
            return startContentOffsetY
        }
        return clampContentOffsetY(startContentOffsetY + deltaLocalY * mainScrollRange / travel)
    }
}
