@preconcurrency import AppKit
import Foundation

/// Owns the vertical and horizontal ``OverlayScrollerView``s of a ``TextView`` and decides which
/// are visible and where they sit, so `TextView` only forwards a handful of lifecycle calls.
///
/// - The vertical scroller shows only while the minimap is off — the minimap's viewport indicator
///   already fills that role while it is visible.
/// - The horizontal scroller is independent of the minimap and appears whenever content overflows
///   horizontally (in practice: line wrapping off and a line wider than the viewport).
/// - With the system's always-visible ("legacy") scroller style the vertical scroller also reserves
///   its slot beside the text, and shows its track even when the document fits.
@MainActor
final class ScrollerOverlayController: NSObject {
    let verticalScroller = OverlayScrollerView(axis: .vertical)
    let horizontalScroller = OverlayScrollerView(axis: .horizontal)

    /// Pins the scroller style instead of reading `NSScroller.preferredScrollerStyle`, so tests
    /// don't depend on whether the machine has a mouse attached.
    var scrollerStyleOverride: NSScroller.Style? {
        didSet { applyScrollerStyle() }
    }

    private weak var textView: TextView?
    private static let revealEdgeDistance: CGFloat = 24

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var usesLegacyStyle: Bool {
        (scrollerStyleOverride ?? NSScroller.preferredScrollerStyle) == .legacy
    }

    @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
        applyScrollerStyle()
    }

    private func applyScrollerStyle() {
        verticalScroller.usesLegacyStyle = usesLegacyStyle
        horizontalScroller.usesLegacyStyle = usesLegacyStyle
        textView?.setNeedsLayout()
    }

    // MARK: - Lifecycle

    /// Adds both scrollers to `textView` as viewport-anchored overlays. They start collapsed.
    /// `onUserScroll` runs before a click or drag on a scroller changes the scroll offset.
    func install(in textView: TextView, themeSource: TextInputView, onUserScroll: @escaping () -> Void) {
        self.textView = textView
        for scroller in [verticalScroller, horizontalScroller] {
            scroller.scrollView = textView
            scroller.themeSource = themeSource
            scroller.onUserScroll = onUserScroll
            scroller.usesLegacyStyle = usesLegacyStyle
            scroller.applyTheme()
            scroller.collapse()
            textView.addFixedOverlaySubview(scroller)
        }
    }

    func applyTheme() {
        verticalScroller.applyTheme()
        horizontalScroller.applyTheme()
    }

    // MARK: - Layout

    /// Width to take from the text column for the vertical scroller. Only non-zero in the legacy
    /// style, where the scroller is a permanent strip; overlay scrollers float over the text.
    /// Deliberately independent of whether the document currently overflows, so reserving the
    /// space can never change wrapping and flip that answer.
    func reservedTrailingWidth(for textView: TextView) -> CGFloat {
        guard textView.showsScrollers, !textView.showMinimap, usesLegacyStyle else {
            return 0
        }
        return OverlayScrollerView.thickness
    }

    func layout(in textView: TextView) {
        guard textView.showsScrollers else {
            verticalScroller.collapse()
            horizontalScroller.collapse()
            return
        }
        let bounds = textView.bounds
        let thickness = OverlayScrollerView.thickness
        let minimapWidth = textView.showMinimap ? textView.minimapWidth : 0

        let verticalGeometry = OverlayScrollerView.geometry(axis: .vertical, trackLength: bounds.height, in: textView)
        let horizontalGeometry = OverlayScrollerView.geometry(
            axis: .horizontal,
            trackLength: max(bounds.width - minimapWidth, 0),
            in: textView
        )
        let showsVertical = !textView.showMinimap && (usesLegacyStyle || verticalGeometry.isScrollable)
        let showsHorizontal = horizontalGeometry.isScrollable
        let verticalSlot = showsVertical ? thickness : 0
        let horizontalSlot = showsHorizontal ? thickness : 0

        if showsVertical {
            place(
                verticalScroller,
                frame: CGRect(x: bounds.maxX - thickness, y: 0, width: thickness, height: max(bounds.height - horizontalSlot, 0))
            )
        } else {
            verticalScroller.collapse()
        }
        if showsHorizontal {
            place(
                horizontalScroller,
                frame: CGRect(
                    x: 0,
                    y: bounds.maxY - thickness,
                    width: max(bounds.width - minimapWidth - verticalSlot, 0),
                    height: thickness
                )
            )
        } else {
            horizontalScroller.collapse()
        }
        raiseToFront(in: textView)
    }

    private func place(_ scroller: OverlayScrollerView, frame: CGRect) {
        if scroller.isHidden {
            scroller.isHidden = false
        }
        if scroller.frame != frame {
            scroller.frame = frame
        }
        scroller.updateKnob()
    }

    /// Keeps the visible scrollers above the minimap, gutter and canvas. Only reorders when they
    /// aren't already the topmost subviews, so a steady-state layout pass causes no view churn.
    private func raiseToFront(in textView: TextView) {
        let visible = [verticalScroller, horizontalScroller].filter { !$0.isHidden }
        guard !visible.isEmpty else {
            return
        }
        let topmost = Array(textView.subviews.suffix(visible.count))
        guard !zip(topmost, visible).allSatisfy({ $0 === $1 }) else {
            return
        }
        for scroller in visible {
            textView.bringSubviewToFront(scroller)
        }
    }

    // MARK: - Scrolling feedback

    /// The editor scrolled: re-frame the knobs and reveal the scrollers.
    func handleScroll() {
        for scroller in [verticalScroller, horizontalScroller] where !scroller.isHidden {
            scroller.updateKnob()
            scroller.flash()
        }
    }

    /// Reveals the visible scrollers without a scroll (e.g. a wheel event that hit the end).
    func flash() {
        verticalScroller.flash()
        horizontalScroller.flash()
    }

    /// Reveals a scroller when the pointer approaches the edge it sits on, as macOS does.
    /// `point` is in the text view's coordinate space.
    func mouseMoved(to point: CGPoint) {
        guard let textView else {
            return
        }
        let bounds = textView.bounds
        if !verticalScroller.isHidden, point.x >= bounds.maxX - Self.revealEdgeDistance {
            verticalScroller.flash()
        }
        if !horizontalScroller.isHidden,
           point.y >= bounds.maxY - Self.revealEdgeDistance,
           point.x <= horizontalScroller.frame.maxX {
            horizontalScroller.flash()
        }
    }

    /// Hides or restores the scrollers along with the rest of the editor chrome
    /// (distraction-free mode).
    func setChromeVisible(_ isVisible: Bool, duration: TimeInterval) {
        for scroller in [verticalScroller, horizontalScroller] {
            scroller.suppressionDuration = duration
            scroller.isSuppressed = !isVisible
        }
    }
}
