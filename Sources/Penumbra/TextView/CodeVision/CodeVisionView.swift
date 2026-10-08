@preconcurrency import AppKit
import EditorIntelligence

/// One lens: its labels in a row above a declaration, drawn in the hint font. The labels that
/// carry a count are clickable.
final class CodeVisionLabelView: EditorView {
    private(set) var entries: [CodeVisionEntry] = []
    private var hintAppearance = InlayHintAppearance.standard
    private var entryRects: [CGRect] = []
    private var hoveredIndex: Int? {
        didSet {
            if hoveredIndex != oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onClick: ((CodeVisionEntry) -> Void)?
    private var trackingArea: NSTrackingArea?

    private static let separator = "  ·  "

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays the labels out; redraws only when they or the look changed.
    func configure(entries: [CodeVisionEntry], appearance: InlayHintAppearance) {
        guard entries != self.entries || appearance != hintAppearance else { return }
        self.entries = entries
        hintAppearance = appearance
        hoveredIndex = nil
        var x: CGFloat = 0
        var rects: [CGRect] = []
        let separatorWidth = (Self.separator as NSString).size(withAttributes: [.font: appearance.font]).width
        for entry in entries {
            let width = (entry.text as NSString).size(withAttributes: [.font: appearance.font]).width
            rects.append(CGRect(x: x, y: 0, width: ceil(width), height: 0))
            x += ceil(width) + ceil(separatorWidth)
        }
        entryRects = rects
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The width the labels need.
    var contentWidth: CGFloat {
        entryRects.last.map { $0.maxX } ?? 0
    }

    private func rect(at index: Int) -> CGRect {
        var rect = entryRects[index]
        rect.size.height = bounds.height
        return rect
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return entryRects.indices.contains { rect(at: $0).contains(local) } ? self : nil
    }

    private func index(at point: CGPoint) -> Int? {
        entryRects.indices.first { rect(at: $0).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(entries[index])
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        for index in entryRects.indices {
            addCursorRect(rect(at: index), cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let separator = NSAttributedString(string: Self.separator, attributes: [
            .font: hintAppearance.font, .foregroundColor: hintAppearance.textColor.withAlphaComponent(0.6)
        ])
        for (index, entry) in entries.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: hintAppearance.font, .foregroundColor: hintAppearance.textColor]
            if index == hoveredIndex {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let text = NSAttributedString(string: entry.text, attributes: attributes)
            let size = text.size()
            let y = max((bounds.height - size.height) / 2, 0)
            text.draw(at: CGPoint(x: entryRects[index].minX, y: y))
            if index < entries.count - 1 {
                separator.draw(at: CGPoint(x: entryRects[index].maxX, y: y))
            }
        }
    }
}

/// Hosts the lenses of the rows on screen. Empty space passes clicks through to the editor.
final class CodeVisionView: EditorView {
    private var labelViews: [CodeVisionLabelView] = []

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

    func labelView(at index: Int) -> CodeVisionLabelView {
        while labelViews.count <= index {
            let label = CodeVisionLabelView(frame: .zero)
            labelViews.append(label)
            addSubview(label)
        }
        return labelViews[index]
    }

    func showLabels(count: Int) {
        for (index, label) in labelViews.enumerated() {
            label.isHidden = index >= count
        }
    }

    var visibleLabelViews: [CodeVisionLabelView] {
        labelViews.filter { !$0.isHidden }
    }
}
