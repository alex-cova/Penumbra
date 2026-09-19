@preconcurrency import AppKit
import Foundation

/// One floating scroller (vertical or horizontal) for ``TextView``, in the style of macOS overlay
/// scrollers: a slim rounded knob that appears while the document scrolls, fades out when idle,
/// and widens over a track when hovered or dragged.
///
/// `TextView` is a clip-view-backed `UIScrollView` shim, not an `NSScrollView`, so AppKit never
/// provides scrollers for it. This view fills that gap the way ``MinimapView`` does — a
/// viewport-anchored overlay (added through `addFixedOverlaySubview`) that reads the editor's
/// scroll metrics through ``ScrollerGeometry`` and scrolls it by assigning `contentOffset`.
///
/// With the system's "Show scroll bars: Always" (legacy style) the scroller never fades and always
/// draws its track.
final class OverlayScrollerView: UIView {
    enum Axis {
        case vertical
        case horizontal
    }

    /// Thickness of the scroller's slot, in points — the size it occupies across its axis.
    static let thickness: CGFloat = 15

    private static let idleKnobThickness: CGFloat = 7
    private static let expandedKnobThickness: CGFloat = 11
    private static let knobInset: CGFloat = 2
    private static let minKnobLength: CGFloat = 24
    private static let hideDelay: TimeInterval = 1.2
    private static let fadeDuration: TimeInterval = 0.3

    let axis: Axis
    /// The scroll view whose `contentOffset` this scroller reflects and controls.
    weak var scrollView: TextView?
    /// Source of the theme the scroller is colored from. Not owned.
    weak var themeSource: TextInputView?
    /// Called before the scroller changes `scrollView.contentOffset` from a click or drag.
    var onUserScroll: (() -> Void)?
    /// Whether the system shows always-visible (legacy) scrollers. Set by the controller from
    /// `NSScroller.preferredScrollerStyle`.
    var usesLegacyStyle = false {
        didSet {
            if usesLegacyStyle != oldValue {
                refreshAppearance(animated: false)
            }
        }
    }
    /// Set while a host chrome mode (distraction-free) wants every overlay hidden.
    var isSuppressed = false {
        didSet {
            if isSuppressed != oldValue {
                refreshAppearance(animated: true, duration: suppressionDuration)
            }
        }
    }
    var suppressionDuration: TimeInterval = OverlayScrollerView.fadeDuration

    private let knobView = UIView()
    private var theme: Theme?
    private var isRevealed = false
    private var isHovered = false
    private var isDragging = false
    private var dragStartPosition: CGFloat = 0
    private var dragStartContentOffset: CGFloat = 0
    private var hideTimer: Timer?
    private var hoverTrackingArea: NSTrackingArea?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        knobView.wantsLayer = true
        addSubview(knobView)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    /// The scroll geometry for `axis`, with a track of `trackLength` points.
    static func geometry(axis: Axis, trackLength: CGFloat, in textView: TextView) -> ScrollerGeometry {
        let visibleOffset = textView.visibleContentOffset
        let minimum = textView.minimumContentOffset
        let maximum = textView.maximumContentOffset
        switch axis {
        case .vertical:
            return ScrollerGeometry(
                trackLength: trackLength,
                viewportLength: textView.bounds.height,
                contentOffset: visibleOffset.y,
                minimumContentOffset: minimum.y,
                maximumContentOffset: maximum.y,
                minKnobLength: minKnobLength
            )
        case .horizontal:
            return ScrollerGeometry(
                trackLength: trackLength,
                viewportLength: textView.bounds.width,
                contentOffset: visibleOffset.x,
                minimumContentOffset: minimum.x,
                maximumContentOffset: maximum.x,
                minKnobLength: minKnobLength
            )
        }
    }

    private var trackLength: CGFloat {
        axis == .vertical ? bounds.height : bounds.width
    }

    private var currentGeometry: ScrollerGeometry? {
        guard let scrollView, trackLength > 0 else {
            return nil
        }
        return Self.geometry(axis: axis, trackLength: trackLength, in: scrollView)
    }

    /// Coordinate of `point` along the scroller's axis.
    private func position(of point: CGPoint) -> CGFloat {
        axis == .vertical ? point.y : point.x
    }

    // MARK: - Layout

    private var isExpanded: Bool {
        usesLegacyStyle || isHovered || isDragging
    }

    /// Positions the knob for the editor's current scroll offset. Cheap — safe to call on every
    /// scroll tick.
    func updateKnob() {
        guard !isHidden, let geometry = currentGeometry, geometry.isScrollable else {
            knobView.isHidden = true
            return
        }
        let thickness = isExpanded ? Self.expandedKnobThickness : Self.idleKnobThickness
        // The knob hugs the outer edge of the slot, so the idle (thin) and expanded (wide) knobs
        // grow toward the text rather than away from it.
        let crossOrigin = Self.thickness - Self.knobInset - thickness
        knobView.isHidden = false
        switch axis {
        case .vertical:
            knobView.frame = CGRect(x: crossOrigin, y: geometry.knobOrigin, width: thickness, height: geometry.knobLength)
        case .horizontal:
            knobView.frame = CGRect(x: geometry.knobOrigin, y: crossOrigin, width: geometry.knobLength, height: thickness)
        }
        knobView.layer?.cornerRadius = thickness / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateKnob()
    }

    /// Collapses the scroller immediately so layer-backed chrome cannot linger at its last frame
    /// after the scroller stops applying (same defensive collapse as ``MinimapView``).
    func collapse() {
        cancelPendingHide()
        isRevealed = false
        isHovered = false
        isDragging = false
        isHidden = true
        frame = .zero
        knobView.isHidden = true
        knobView.frame = .zero
        alphaValue = 0
    }

    // MARK: - Theme

    func applyTheme() {
        guard let theme = themeSource?.theme else {
            return
        }
        self.theme = theme
        refreshColors()
    }

    private func refreshColors() {
        guard let theme else {
            return
        }
        knobView.backgroundColor = theme.textColor.withAlphaComponent(isExpanded ? 0.55 : 0.35)
        backgroundColor = isExpanded ? theme.gutterBackgroundColor : nil
    }

    // MARK: - Visibility

    /// The opacity the scroller should settle at given its reveal, hover, drag and style state.
    private var targetAlpha: CGFloat {
        if isSuppressed {
            return 0
        }
        return (usesLegacyStyle || isRevealed || isHovered || isDragging) ? 1 : 0
    }

    private func refreshAppearance(animated: Bool, duration: TimeInterval = OverlayScrollerView.fadeDuration) {
        refreshColors()
        updateKnob()
        let target = targetAlpha
        guard alphaValue != target else {
            return
        }
        guard animated, duration > 0 else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = target
        }
    }

    /// Reveals the scroller and schedules it to fade out again once the user stops interacting.
    func flash() {
        guard !isHidden else {
            return
        }
        isRevealed = true
        cancelPendingHide()
        // Reveal immediately — a scroll tick should never wait on an animation to show feedback.
        if !isSuppressed, alphaValue != 1 {
            alphaValue = 1
        }
        scheduleHide()
    }

    private func scheduleHide() {
        guard !usesLegacyStyle, !isHovered, !isDragging else {
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] timer in
            timer.invalidate()
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.hideTimer = nil
                self.isRevealed = false
                self.refreshAppearance(animated: true)
            }
        }
    }

    private func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    // MARK: - Hit testing & hover

    /// An invisible scroller must never swallow clicks meant for the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHidden else {
            return
        }
        isHovered = true
        cancelPendingHide()
        refreshAppearance(animated: false)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance(animated: false)
        if !isDragging {
            scheduleHide()
        }
    }

    // MARK: - Mouse handling

    /// `AppleScrollerPagingBehavior` is the system's "Click in the scroll bar to: Jump to the spot
    /// that's clicked" preference; absent or `false` means "Jump to the next page".
    private var jumpsToClickedSpot: Bool {
        UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let geometry = currentGeometry, geometry.isScrollable, let scrollView else {
            return
        }
        let along = position(of: point)
        if along >= geometry.knobOrigin, along <= geometry.knobOrigin + geometry.knobLength {
            isDragging = true
            dragStartPosition = along
            dragStartContentOffset = axis == .vertical ? scrollView.contentOffset.y : scrollView.contentOffset.x
            cancelPendingHide()
            refreshAppearance(animated: false)
        } else {
            isDragging = false
            let target = jumpsToClickedSpot
                ? geometry.contentOffset(forClickAt: along)
                : geometry.pagedContentOffset(forClickAt: along)
            scroll(to: target)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let geometry = currentGeometry else {
            return
        }
        let along = position(of: convert(event.locationInWindow, from: nil))
        scroll(to: geometry.contentOffset(forDragDelta: along - dragStartPosition, from: dragStartContentOffset))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else {
            return
        }
        isDragging = false
        // The pointer may have left the slot during the drag without a matching mouseExited.
        let point = convert(event.locationInWindow, from: nil)
        isHovered = bounds.contains(point)
        refreshAppearance(animated: false)
        if !isHovered {
            scheduleHide()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // The scroller doesn't scroll independently — forward wheel events to the real editor.
        scrollView?.scrollWheel(with: event)
    }

    private func scroll(to target: CGFloat) {
        guard let scrollView else {
            return
        }
        onUserScroll?()
        let current = scrollView.contentOffset
        scrollView.contentOffset = axis == .vertical
            ? CGPoint(x: current.x, y: target)
            : CGPoint(x: target, y: current.y)
        updateKnob()
    }
}
