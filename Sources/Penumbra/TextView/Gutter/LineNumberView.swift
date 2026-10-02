import Foundation
@preconcurrency import AppKit

final class LineNumberView: EditorView, ReusableView {
    var textColor: NSColor {
        get {
            titleLabel.textColor
        }
        set {
            titleLabel.textColor = newValue
        }
    }
    var font: NSFont {
        get {
            titleLabel.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        }
        set {
            titleLabel.font = newValue
        }
    }
    var text: String? {
        get {
            titleLabel.text
        }
        set {
            titleLabel.text = newValue
        }
    }
    /// Drawn in place of the number (a breakpoint).
    var decoration: GutterDecoration? {
        get {
            decorationView?.decoration
        }
        set {
            guard newValue != decorationView?.decoration else { return }
            titleLabel.isHidden = newValue != nil
            if newValue != nil && decorationView == nil {
                let decorationView = LineNumberDecorationView()
                addSubview(decorationView)
                self.decorationView = decorationView
            }
            decorationView?.decoration = newValue
            decorationView?.isHidden = newValue == nil
            layoutSubviews()
        }
    }
    /// The color of a decoration without a tint.
    var decorationColor: NSColor = .systemGreen {
        didSet { decorationView?.defaultColor = decorationColor }
    }

    private let titleLabel: EditorLabel = {
        let this = EditorLabel()
        this.textAlignment = .right
        return this
    }()
    private var decorationView: LineNumberDecorationView?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays the label out with the new width at once. The gutter narrows the digits when other
    /// columns appear, and a label left at the old width until AppKit's next layout pass drew its
    /// number off the column's right edge.
    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = newSize != frame.size
        super.setFrameSize(newSize)
        if sizeChanged {
            layoutSubviews()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = titleLabel.measuredTextSize
        titleLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: size.height)
        if let decorationView, !decorationView.isHidden {
            // About the height of the digits' capitals, scaled with the line-number font.
            let side = min(ceil(font.capHeight * 1.4), bounds.height)
            decorationView.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        }
    }
}

/// The decoration a ``LineNumberView`` shows instead of its number.
private final class LineNumberDecorationView: EditorView {
    var decoration: GutterDecoration? {
        didSet {
            if decoration != oldValue { needsDisplay = true }
        }
    }
    var defaultColor: NSColor = .systemGreen {
        didSet {
            if defaultColor != oldValue { needsDisplay = true }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = newSize != frame.size
        super.setFrameSize(newSize)
        if sizeChanged {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        decoration?.drawIcon(in: bounds, defaultColor: defaultColor)
    }
}
