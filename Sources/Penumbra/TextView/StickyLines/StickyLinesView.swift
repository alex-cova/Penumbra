@preconcurrency import AppKit

/// What one pinned line looks like. Colors come from the theme; the rest from the document.
struct StickyLineStyle: Equatable {
    var background: NSColor
    var hoverBackground: NSColor
    var gutterBackground: NSColor
    var lineNumberColor: NSColor
    var lineNumberFont: NSFont
    var border: NSColor
    var gutterWidth: CGFloat
    /// Where the text starts, in this view's coordinates (past the gutter, shifted by horizontal scrolling).
    var textOriginX: CGFloat
}

/// One pinned line: the gutter with its line number and the line's highlighted text.
final class StickyLineRowView: EditorView {
    private(set) var lineNumber = 0
    private var text: NSAttributedString?
    private var style: StickyLineStyle?
    private var drawsBorder = false
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Redraws only when something it shows changed, so moving a row while scrolling costs nothing.
    func configure(lineNumber: Int, text: NSAttributedString?, style: StickyLineStyle, drawsBorder: Bool) {
        let changed = self.lineNumber != lineNumber || self.drawsBorder != drawsBorder || self.style != style
            || !(self.text === text || self.text?.isEqual(to: text ?? NSAttributedString()) == true)
        self.lineNumber = lineNumber
        self.text = text
        self.style = style
        self.drawsBorder = drawsBorder
        if changed {
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // The panel has nothing to scroll; the editor under it does.
        nextResponder?.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let background = isHovered ? style.hoverBackground : style.background
        background.setFill()
        bounds.fill()
        if style.gutterWidth > 0 {
            style.gutterBackground.setFill()
            NSRect(x: 0, y: 0, width: style.gutterWidth, height: bounds.height).fill()
        }
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: style.gutterWidth, y: 0, width: max(bounds.width - style.gutterWidth, 0), height: bounds.height).clip()
            let size = text.size()
            text.draw(at: CGPoint(x: style.textOriginX, y: max((bounds.height - size.height) / 2, 0)))
            NSGraphicsContext.restoreGraphicsState()
        }
        if style.gutterWidth > 0 {
            let number = NSAttributedString(string: "\(lineNumber)", attributes: [
                .font: style.lineNumberFont,
                .foregroundColor: style.lineNumberColor
            ])
            let size = number.size()
            number.draw(at: CGPoint(x: max(style.gutterWidth - size.width - 6, 0),
                                    y: max((bounds.height - size.height) / 2, 0)))
        }
        if drawsBorder {
            style.border.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// Clips and hosts the pinned lines. Empty space passes clicks through to the editor.
final class StickyLinesView: EditorView {
    private(set) var rowViews: [StickyLineRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// A reusable row view for slot `index`; slots past the visible count stay hidden.
    func rowView(at index: Int) -> StickyLineRowView {
        while rowViews.count <= index {
            let row = StickyLineRowView(frame: .zero)
            rowViews.append(row)
        }
        return rowViews[index]
    }

    /// Shows `count` rows, outermost on top: a line pushed up slides under the one above it.
    func showRows(count: Int) {
        for (index, row) in rowViews.enumerated() {
            row.isHidden = index >= count
        }
        // Subviews are in paint order, so the innermost row goes first and outer rows cover it.
        let wanted: [NSView] = rowViews.prefix(count).reversed()
        if subviews.count != wanted.count || zip(subviews, wanted).contains(where: { $0 !== $1 }) {
            subviews.forEach { $0.removeFromSuperview() }
            wanted.forEach { addSubview($0) }
        }
    }
}
