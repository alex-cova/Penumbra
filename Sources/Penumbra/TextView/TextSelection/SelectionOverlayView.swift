@preconcurrency import AppKit
import Foundation

final class SelectionOverlayView: UIView {
    var selectionRects: [TextSelectionRect] = [] {
        didSet {
            setNeedsDisplay()
        }
    }
    var highlightColor: UIColor = UIColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1) {
        didSet {
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else {
            return
        }
        // Prefer setFill() so appearance-adaptive colors resolve against this
        // view's drawing context rather than NSApp.effectiveAppearance via cgColor.
        highlightColor.setFill()
        for selectionRect in selectionRects {
            selectionRect.rect.fill()
        }
    }
}
