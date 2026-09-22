@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit completion panel view that renders a `CompletionPanelModel` as a real list: every
/// item (not just the first), the selected row highlighted, a short kind badge, and a dimmed
/// detail string when the item has one. Capped at `maxVisibleRows` items with no scrolling for
/// anything beyond that -- a real scroll view is a reasonable follow-up, not attempted here to
/// keep this a plain custom-drawn view like its predecessor.
@MainActor
public final class CompletionPanelView: NSView {
    private var model: CompletionPanelModel
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    /// Called when the user clicks a row (without accepting it) -- wire this to move the host's
    /// selection index.
    public var onSelectRow: ((Int) -> Void)?
    /// Called when the user double-clicks a row -- wire this to accept that completion.
    public var onAcceptRow: ((Int) -> Void)?

    public static let rowHeight: CGFloat = 20
    public static let maxVisibleRows = 10
    public static let defaultWidth: CGFloat = 280

    public init(model: CompletionPanelModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: CompletionPanelModel) {
        self.model = model
        hoveredIndex = nil
        setNeedsDisplay(bounds)
    }

    /// The size this panel should be given `model.items.count`, capped at `maxVisibleRows` rows
    /// (a minimum of one row's height even when empty, so the panel never collapses to nothing
    /// while still visible during a request).
    public static func preferredSize(for model: CompletionPanelModel, width: CGFloat = defaultWidth) -> NSSize {
        let rows = max(1, min(model.items.count, maxVisibleRows))
        return NSSize(width: width, height: CGFloat(rows) * rowHeight + 2)
    }

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
        setNeedsDisplay(bounds)
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        setNeedsDisplay(bounds)
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
        let visibleCount = min(model.items.count, Self.maxVisibleRows)
        for i in 0..<visibleCount where rowRect(for: i).contains(point) {
            return i
        }
        return nil
    }

    private func rowRect(for index: Int) -> NSRect {
        NSRect(x: 0, y: bounds.height - CGFloat(index + 1) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let visibleCount = min(model.items.count, Self.maxVisibleRows)
        for i in 0..<visibleCount {
            draw(item: model.items[i], at: i, isSelected: i == model.selectedIndex, isHovered: i == hoveredIndex)
        }

        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.separatorColor.setStroke()
        border.stroke()
    }

    private func draw(item: CompletionItem, at index: Int, isSelected: Bool, isHovered: Bool) {
        let rect = rowRect(for: index)
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            rect.fill()
        } else if isHovered {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            rect.fill()
        }

        let labelColor = isSelected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let badgeColor = isSelected ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 12)
        let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        let badgeRect = NSRect(x: 6, y: rect.minY + 4, width: 14, height: rect.height - 4)
        Self.badge(for: item.kind).draw(in: badgeRect, withAttributes: [.font: badgeFont, .foregroundColor: badgeColor])

        let labelRect = NSRect(x: 24, y: rect.minY + 3, width: rect.width - 24 - 90, height: rect.height - 3)
        var labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
        if item.kind == .keyword {
            labelAttributes[.font] = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        (item.label as NSString).draw(in: labelRect, withAttributes: labelAttributes)

        if let detail = item.documentation, !detail.isEmpty {
            let detailColor = isSelected ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor
            let detailRect = NSRect(x: rect.width - 88, y: rect.minY + 4, width: 82, height: rect.height - 4)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byTruncatingTail
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: detailColor, .paragraphStyle: paragraph
            ]
            (detail as NSString).draw(in: detailRect, withAttributes: detailAttributes)
        }
    }

    /// A short kind badge in the style of IntelliJ's completion popup. `CompletionItemKind`
    /// doesn't yet distinguish class/interface/enum/field from their nearest existing case
    /// (`.type`/`.property`), so those share one letter for now.
    private static func badge(for kind: CompletionItemKind) -> String {
        switch kind {
        case .method, .function: return "m"
        case .property: return "f"
        case .variable: return "v"
        case .type: return "c"
        case .keyword: return "k"
        case .snippet: return "s"
        case .module: return "M"
        case .file: return "•"
        case .text: return " "
        }
    }
}
