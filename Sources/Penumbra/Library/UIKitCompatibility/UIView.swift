@preconcurrency import AppKit
import Foundation

public typealias UIResponder = NSResponder

open class UIView: NSView {
    open var isFirstResponder: Bool { window?.firstResponder === self }
    open var backgroundColor: UIColor? {
        didSet { wantsLayer = true; layer?.backgroundColor = backgroundColor?.cgColor }
    }

    /// `backgroundColor` above bakes `NSColor` to `CGColor` once, at assignment time. A dynamic
    /// (appearance-adaptive) color resolves against the current appearance at that moment and
    /// never re-resolves on its own, so it goes stale when the effective appearance changes later
    /// — including when a caller forces a specific appearance via `NSView.appearance` independent
    /// of the system setting. Re-bake whenever the effective appearance actually changes.
    override open func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = backgroundColor?.cgColor
    }
    open var isUserInteractionEnabled = true
    open var traitCollection: UITraitCollection { UITraitCollection() }
    open var inputAccessoryView: UIView?
    open var inputAssistantItem: UITextInputAssistantItem { UITextInputAssistantItem() }
    open func reloadInputViews() {}
    private var uiGestureRecognizers: [UIGestureRecognizer] = []

    override open var isFlipped: Bool { true }

    /// Frame-driven UIKit port: never participate in Auto Layout measuring.
    override open var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    open func layoutSubviews() {}

    /// Frame-first layout. Calling `super.layout()` before mutating frames made AppKit
    /// finish the subtree pass, then `layoutSubviews` dirtied it again — a known
    /// "Update Constraints in Window" abort when hosted in SwiftUI.
    override open func layout() {
        layoutSubviews()
    }

    open func setNeedsLayout() { needsLayout = true }
    open func layoutIfNeeded() { layoutSubtreeIfNeeded() }
    open func setNeedsDisplay() { needsDisplay = true }

    /// Reorder without remove+readd (which dirties the window during layout).
    open func bringSubviewToFront(_ view: UIView) {
        guard view.superview === self else {
            addSubview(view)
            return
        }
        if subviews.last !== view {
            addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    open func sendSubviewToBack(_ view: UIView) {
        guard view.superview === self else {
            if let first = subviews.first {
                addSubview(view, positioned: .below, relativeTo: first)
            } else {
                addSubview(view)
            }
            return
        }
        if let first = subviews.first, first !== view {
            addSubview(view, positioned: .below, relativeTo: first)
        }
    }

    open func safeAreaInsetsDidChange() {}
    open func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {}
    open func addInteraction(_ interaction: Any) {}
    open func removeInteraction(_ interaction: Any) {}
    open func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        gestureRecognizer.view = self; uiGestureRecognizers.append(gestureRecognizer)
    }
    open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    open func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override open func hitTest(_ point: NSPoint) -> NSView? { isUserInteractionEnabled ? super.hitTest(point) : nil }
    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindow()
    }
    open func didMoveToWindow() {}
    open override var acceptsFirstResponder: Bool { false }
    override open func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        uiGestureRecognizers.forEach { $0.handleMouseDown(event) }
        super.mouseDown(with: event)
    }
}
