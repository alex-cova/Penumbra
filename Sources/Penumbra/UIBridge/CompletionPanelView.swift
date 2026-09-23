@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit completion popup in the style of IntelliJ's lookup list. Each row shows a
/// colored kind icon, the label with the typed characters in bold, a dimmed tail (a method's
/// parameter list) and a right-aligned type (return type, field type, package). Deprecated items
/// are struck through. The list scrolls: at most `maxVisibleRows` rows are drawn and the
/// selected row is kept in view.
@MainActor
public final class CompletionPanelView: NSView {
    private var model: CompletionPanelModel
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?
    /// Index of the first drawn row.
    private(set) var firstVisibleIndex = 0

    /// Called when the user clicks a row (without accepting it) -- wire this to move the host's
    /// selection index.
    public var onSelectRow: ((Int) -> Void)?
    /// Called when the user double-clicks a row -- wire this to accept that completion.
    public var onAcceptRow: ((Int) -> Void)?

    public static let rowHeight: CGFloat = 22
    public static let maxVisibleRows = 12
    public static let minimumWidth: CGFloat = 280
    public static let maximumWidth: CGFloat = 640
    /// Kept for source compatibility; the panel now sizes its width to its content.
    public static let defaultWidth: CGFloat = minimumWidth

    private static let iconSize: CGFloat = 16
    private static let horizontalPadding: CGFloat = 6
    private static let iconGap: CGFloat = 6
    private static let columnGap: CGFloat = 16
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let boldLabelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let iconFont = NSFont.systemFont(ofSize: 10, weight: .bold)

    public init(model: CompletionPanelModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool {
        true
    }

    public func update(model: CompletionPanelModel) {
        let itemsChanged = model.items.map(\.id) != self.model.items.map(\.id)
        self.model = model
        hoveredIndex = nil
        if itemsChanged {
            firstVisibleIndex = 0
        }
        scrollSelectionIntoView()
        needsDisplay = true
    }

    /// The size this panel should have for `model`: up to `maxVisibleRows` rows, and wide enough
    /// for the widest row's label, tail and type (clamped to `minimumWidth...maximumWidth`).
    public static func preferredSize(for model: CompletionPanelModel, width: CGFloat? = nil) -> NSSize {
        let rows = max(1, min(model.items.count, maxVisibleRows))
        let height = CGFloat(rows) * rowHeight + 2
        if let width {
            return NSSize(width: width, height: height)
        }
        var widest: CGFloat = 0
        for item in model.items.prefix(200) {
            widest = max(widest, contentWidth(of: item))
        }
        if model.items.isEmpty, let emptyText = model.emptyText {
            widest = (emptyText as NSString).size(withAttributes: [.font: detailFont]).width + 2 * horizontalPadding
        }
        let scrollerAllowance: CGFloat = model.items.count > maxVisibleRows ? 6 : 0
        return NSSize(width: min(maximumWidth, max(minimumWidth, ceil(widest + scrollerAllowance))), height: height)
    }

    private static func contentWidth(of item: CompletionItem) -> CGFloat {
        var width = horizontalPadding + iconSize + iconGap
        width += (item.label as NSString).size(withAttributes: [.font: boldLabelFont]).width
        if let tail = item.labelDetail, !tail.isEmpty {
            width += (tail as NSString).size(withAttributes: [.font: detailFont]).width
        }
        if let detail = item.detail, !detail.isEmpty {
            width += columnGap + (detail as NSString).size(withAttributes: [.font: detailFont]).width
        }
        return width + horizontalPadding
    }

    // MARK: - Scrolling

    private var visibleRowCount: Int {
        min(model.items.count, Self.maxVisibleRows)
    }

    private func scrollSelectionIntoView() {
        let count = model.items.count
        let maxFirst = max(0, count - Self.maxVisibleRows)
        guard let selected = model.selectedIndex, count > 0 else {
            firstVisibleIndex = min(firstVisibleIndex, maxFirst)
            return
        }
        if selected < firstVisibleIndex {
            firstVisibleIndex = selected
        } else if selected >= firstVisibleIndex + Self.maxVisibleRows {
            firstVisibleIndex = selected - Self.maxVisibleRows + 1
        }
        firstVisibleIndex = max(0, min(firstVisibleIndex, maxFirst))
    }

    public override func scrollWheel(with event: NSEvent) {
        let count = model.items.count
        guard count > Self.maxVisibleRows else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / Self.rowHeight : event.scrollingDeltaY
        let rows = Int(delta.rounded(delta > 0 ? .up : .down))
        guard rows != 0 else { return }
        firstVisibleIndex = max(0, min(count - Self.maxVisibleRows, firstVisibleIndex - rows))
        needsDisplay = true
    }

    // MARK: - Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHovered = rowIndex(at: point)
        guard newHovered != hoveredIndex else { return }
        hoveredIndex = newHovered
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else { return }
        if event.clickCount >= 2 {
            onAcceptRow?(index)
        } else {
            onSelectRow?(index)
        }
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let row = Int((point.y - 1) / Self.rowHeight)
        let index = firstVisibleIndex + row
        guard row >= 0, row < visibleRowCount, model.items.indices.contains(index) else { return nil }
        return index
    }

    private func rowRect(forVisibleRow row: Int) -> NSRect {
        NSRect(x: 0, y: 1 + CGFloat(row) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        if model.items.isEmpty, let emptyText = model.emptyText {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: NSColor.secondaryLabelColor]
            let size = (emptyText as NSString).size(withAttributes: attributes)
            (emptyText as NSString).draw(
                at: NSPoint(x: Self.horizontalPadding, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }

        for row in 0..<visibleRowCount {
            let index = firstVisibleIndex + row
            guard model.items.indices.contains(index) else { break }
            draw(item: model.items[index], in: rowRect(forVisibleRow: row), isSelected: index == model.selectedIndex, isHovered: index == hoveredIndex)
        }

        drawScrollIndicator()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.separatorColor.setStroke()
        border.stroke()
    }

    private func drawScrollIndicator() {
        let count = model.items.count
        guard count > Self.maxVisibleRows else { return }
        let trackHeight = bounds.height - 4
        let thumbHeight = max(12, trackHeight * CGFloat(Self.maxVisibleRows) / CGFloat(count))
        let progress = CGFloat(firstVisibleIndex) / CGFloat(count - Self.maxVisibleRows)
        let thumb = NSRect(x: bounds.width - 5, y: 2 + (trackHeight - thumbHeight) * progress, width: 3, height: thumbHeight)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func draw(item: CompletionItem, in rect: NSRect, isSelected: Bool, isHovered: Bool) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            rect.fill()
        } else if isHovered {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            rect.fill()
        }

        let labelColor = isSelected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondaryColor = isSelected ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75) : NSColor.secondaryLabelColor

        // Kind icon.
        let iconRect = NSRect(
            x: rect.minX + Self.horizontalPadding,
            y: rect.midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        Self.drawIcon(for: item.kind, in: iconRect)

        let textX = iconRect.maxX + Self.iconGap
        let rightEdge = rect.maxX - Self.horizontalPadding - (model.items.count > Self.maxVisibleRows ? 6 : 0)

        // Right-aligned type column, truncated first from the left edge budget.
        var detailWidth: CGFloat = 0
        if let detail = item.detail, !detail.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byTruncatingHead
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: secondaryColor, .paragraphStyle: paragraph]
            let labelWidth = (item.label as NSString).size(withAttributes: [.font: Self.boldLabelFont]).width
            let available = max(40, rightEdge - textX - labelWidth - Self.columnGap)
            detailWidth = min((detail as NSString).size(withAttributes: attributes).width, available)
            let detailRect = NSRect(x: rightEdge - detailWidth, y: rect.minY + 4, width: detailWidth, height: rect.height - 4)
            (detail as NSString).draw(in: detailRect, withAttributes: attributes)
        }

        // Label (+ tail) with matched characters in bold.
        let text = NSMutableAttributedString(string: item.label, attributes: [.font: Self.labelFont, .foregroundColor: labelColor])
        if !model.prefix.isEmpty, let match = CompletionMatcher.match(model.prefix, in: item.label) {
            for range in match.matchedRanges where NSMaxRange(range) <= text.length {
                text.addAttribute(.font, value: Self.boldLabelFont, range: range)
            }
        }
        if item.isDeprecated {
            text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.length))
        }
        if let tail = item.labelDetail, !tail.isEmpty {
            text.append(NSAttributedString(string: tail, attributes: [.font: Self.detailFont, .foregroundColor: secondaryColor]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        let labelWidth = max(20, rightEdge - textX - (detailWidth > 0 ? detailWidth + Self.columnGap : 0))
        text.draw(in: NSRect(x: textX, y: rect.minY + 3, width: labelWidth, height: rect.height - 3))
    }

    /// IntelliJ-style kind icon: a colored disc with a one-letter glyph.
    private static func drawIcon(for kind: CompletionItemKind, in rect: NSRect) {
        guard let (letter, color) = iconStyle(for: kind) else { return }
        color.setFill()
        let disc: NSBezierPath
        switch kind {
        case .keyword, .snippet, .text, .file, .package, .module:
            disc = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        default:
            disc = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        }
        disc.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: iconFont, .foregroundColor: NSColor.white]
        let size = (letter as NSString).size(withAttributes: attributes)
        (letter as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private static func iconStyle(for kind: CompletionItemKind) -> (String, NSColor)? {
        switch kind {
        case .method, .function: return ("m", NSColor.systemRed.blended(withFraction: 0.2, of: .systemPink) ?? .systemRed)
        case .constructor: return ("m", NSColor.systemRed)
        case .field, .property: return ("f", NSColor.systemOrange)
        case .enumMember: return ("e", NSColor.systemOrange)
        case .variable: return ("v", NSColor.systemPurple)
        case .class, .type: return ("c", NSColor.systemBlue)
        case .interface: return ("i", NSColor.systemGreen)
        case .enum: return ("e", NSColor.systemTeal)
        case .annotation: return ("@", NSColor.systemGreen.blended(withFraction: 0.3, of: .systemTeal) ?? .systemGreen)
        case .keyword: return ("k", NSColor.systemGray)
        case .snippet: return ("s", NSColor.systemGray)
        case .module, .package: return ("p", NSColor.systemBrown)
        case .file: return ("•", NSColor.systemGray)
        case .text: return ("a", NSColor.systemGray.withAlphaComponent(0.6))
        }
    }
}
