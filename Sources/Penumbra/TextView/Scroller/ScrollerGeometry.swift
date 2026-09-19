import CoreGraphics
import Foundation

/// The complete coordinate transform between the editor's scroll space and one overlay scroller's
/// track, as a pure value type so every mapping is unit-testable without a window. It is
/// axis-agnostic: callers feed it the `x` or the `y` components of the editor's scroll metrics.
///
/// Like ``MinimapGeometry``, the knob is placed first and always stays inside the track —
/// `knobOrigin ∈ [0, trackLength - knobLength]` for every input — and every inverse mapping clamps
/// into `minimumContentOffset ... maximumContentOffset`. Because the range comes from the editor's
/// min/max content offsets rather than `contentSize`, content insets, the find-panel inset,
/// typewriter overscroll and horizontal overscroll are already accounted for.
struct ScrollerGeometry {
    /// Length of the scroller's track along its axis, in points.
    let trackLength: CGFloat
    /// Length of the editor's visible viewport along the same axis.
    let viewportLength: CGFloat
    /// The editor's current scroll offset along the axis.
    let contentOffset: CGFloat
    /// The editor's minimum legal scroll offset (`-contentInset.top`/`-left`; normally `0`).
    let minimumContentOffset: CGFloat
    /// The editor's maximum legal scroll offset.
    let maximumContentOffset: CGFloat
    /// Lower bound on the drawn knob length so it stays grabbable on huge documents.
    let minKnobLength: CGFloat

    /// Sub-point scroll ranges are rounding noise, not something worth a scroller.
    private static let scrollableThreshold: CGFloat = 0.5

    var scrollRange: CGFloat {
        max(maximumContentOffset - minimumContentOffset, 0)
    }

    var isScrollable: Bool {
        scrollRange > Self.scrollableThreshold && trackLength > 0 && viewportLength > 0
    }

    /// `0` at the start of the document, `1` at the end.
    var progress: CGFloat {
        guard scrollRange > 0 else {
            return 0
        }
        return min(max((contentOffset - minimumContentOffset) / scrollRange, 0), 1)
    }

    /// The knob's share of the track mirrors the viewport's share of the whole scrollable extent.
    var knobLength: CGFloat {
        guard trackLength > 0, viewportLength > 0 else {
            return 0
        }
        let proportional = viewportLength / (viewportLength + scrollRange) * trackLength
        return min(max(proportional, min(minKnobLength, trackLength)), trackLength)
    }

    /// How far the knob's leading edge can move.
    private var knobTravel: CGFloat {
        max(trackLength - knobLength, 0)
    }

    var knobOrigin: CGFloat {
        progress * knobTravel
    }

    // MARK: - Inverse mappings (mouse handling)

    private func clamped(_ offset: CGFloat) -> CGFloat {
        min(max(offset, minimumContentOffset), maximumContentOffset)
    }

    /// Target offset that centers the knob on a click at `position` along the track.
    func contentOffset(forClickAt position: CGFloat) -> CGFloat {
        let travel = knobTravel
        guard travel > 0 else {
            return contentOffset
        }
        let clickProgress = min(max((position - knobLength / 2) / travel, 0), 1)
        return clamped(minimumContentOffset + clickProgress * scrollRange)
    }

    /// Target offset for a click on the track outside the knob: one viewport toward the click.
    /// A click on the knob itself leaves the offset unchanged.
    func pagedContentOffset(forClickAt position: CGFloat) -> CGFloat {
        if position < knobOrigin {
            return clamped(contentOffset - viewportLength)
        }
        if position > knobOrigin + knobLength {
            return clamped(contentOffset + viewportLength)
        }
        return contentOffset
    }

    /// Target offset while dragging the knob by `delta` from a scroll offset of `startContentOffset`.
    /// Keeps the grabbed point under the cursor.
    func contentOffset(forDragDelta delta: CGFloat, from startContentOffset: CGFloat) -> CGFloat {
        let travel = knobTravel
        guard travel > 0 else {
            return startContentOffset
        }
        return clamped(startContentOffset + delta * scrollRange / travel)
    }
}
