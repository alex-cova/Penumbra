@preconcurrency import AppKit
import Foundation

final class SelectionHandleView: UIView {
    enum Kind {
        case start
        case end
    }

    let kind: Kind
    var handleColor: UIColor = .label {
        didSet {
            setNeedsDisplay()
        }
    }
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    private let handleSize = CGSize(width: 8, height: 10)

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    func frame(anchoredTo caretRect: CGRect) -> CGRect {
        CGRect(x: caretRect.midX - handleSize.width / 2,
               y: caretRect.maxY - 2,
               width: handleSize.width,
               height: handleSize.height)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.saveGState()
        context.setFillColor(handleColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}
