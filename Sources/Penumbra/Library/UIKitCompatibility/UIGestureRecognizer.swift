@preconcurrency import AppKit
import Foundation

public enum UIGestureRecognizerState: Int {
    case possible, began, changed, ended, cancelled, failed
}

@MainActor
public protocol UIGestureRecognizerDelegate: AnyObject {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool
}

extension UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { true }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

open class UIGestureRecognizer: NSObject {
    public weak var delegate: UIGestureRecognizerDelegate?
    weak var view: UIView?
    public var state: UIGestureRecognizerState = .possible
    private weak var target: AnyObject?
    private var action: Selector?
    public func addTarget(_ target: AnyObject, action: Selector) { self.target = target; self.action = action }
    public func require(toFail otherGestureRecognizer: UIGestureRecognizer) {}
    public func location(in view: UIView?) -> CGPoint { .zero }
    fileprivate func sendAction() { _ = target?.perform(action, with: self) }
    func handleMouseDown(_ event: NSEvent) { state = .ended; sendAction(); state = .possible }
}

open class UITapGestureRecognizer: UIGestureRecognizer {}
open class QuickTapGestureRecognizer: UITapGestureRecognizer {
    open var maximumPressDuration: TimeInterval = 0.3
}
open class UIPanGestureRecognizer: UIGestureRecognizer {}

open class UILabel: UIView {
    @objc open var text: String? {
        didSet { needsDisplay = true }
    }
    @objc open var textColor: UIColor = .label {
        didSet { needsDisplay = true }
    }
    @objc open var font: UIFont? {
        didSet { needsDisplay = true }
    }
    @objc open var textAlignment: NSTextAlignment = .left {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Frame-laid-out by LineNumberView; keep Auto Layout from using
        // intrinsicContentSize as a SwiftUI/AppKit measurement input.
        translatesAutoresizingMaskIntoConstraints = true
        // Layer-backed ancestors (TextView) otherwise skip draw(_:) unless
        // redraw is requested explicitly — without this, line numbers exist
        // as empty views in the gutter.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open var intrinsicContentSize: NSSize {
        // Always no-metric — LineNumberView frames the label manually.
        // Returning live text metrics feeds SwiftUI/AppKit measuring loops.
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Measured size for frame-based layout (not Auto Layout intrinsic).
    var measuredTextSize: NSSize {
        guard let font, let text else { return .zero }
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override open func draw(_ dirtyRect: NSRect) {
        guard let text, let font, !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        switch textAlignment {
        case .right:
            paragraph.alignment = .right
        case .center:
            paragraph.alignment = .center
        default:
            paragraph.alignment = .left
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let drawRect = NSRect(
            x: 0,
            y: max((bounds.height - textSize.height) / 2, 0),
            width: bounds.width,
            height: textSize.height
        )
        (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }
}
