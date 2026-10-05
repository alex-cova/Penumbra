@preconcurrency import AppKit
import Foundation

/// Colors of the change stripe, chosen from how light the gutter is.
struct GutterChangeColors: Equatable {
    var added: NSColor
    var modified: NSColor
    var deleted: NSColor

    static func forBackground(_ background: NSColor) -> GutterChangeColors {
        isDark(background) ? dark : light
    }

    static func isDark(_ background: NSColor) -> Bool {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        var brightness: CGFloat = 0
        rgb.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return brightness < 0.5
    }

    private static let dark = GutterChangeColors(
        added: NSColor(srgbRed: 0x5C / 255, green: 0x9E / 255, blue: 0x62 / 255, alpha: 1),
        modified: NSColor(srgbRed: 0x6B / 255, green: 0xA3 / 255, blue: 0xD6 / 255, alpha: 1),
        deleted: NSColor(srgbRed: 0xE0 / 255, green: 0x6C / 255, blue: 0x75 / 255, alpha: 1)
    )
    private static let light = GutterChangeColors(
        added: NSColor(srgbRed: 0x2E / 255, green: 0x7D / 255, blue: 0x32 / 255, alpha: 1),
        modified: NSColor(srgbRed: 0x15 / 255, green: 0x65 / 255, blue: 0xC0 / 255, alpha: 1),
        deleted: NSColor(srgbRed: 0xC6 / 255, green: 0x28 / 255, blue: 0x28 / 255, alpha: 1)
    )

    func color(for kind: GutterChangeKind) -> NSColor {
        switch kind {
        case .added: added
        case .modified: modified
        case .deleted: deleted
        }
    }
}

/// The change stripe: a 3 pt bar in a 4 pt column just to the right of the line numbers.
///
/// Like ``GutterLineMarkerView`` it only covers the viewport (`frame.minY` is the document y of
/// its top). A redraw paints the spans that touch the visible rows, found by a binary search,
/// and reads their y positions with `yPosition(ofRow:)` / `lineInfo(atRow:)` — never a line handle.
final class GutterChangeView: EditorView, NSViewToolTipOwner {
    static let columnWidth: CGFloat = 4
    static let barWidth: CGFloat = 3
    static let triangleSize: CGFloat = 5

    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    let store = GutterChangeStore()
    private var colors = GutterChangeColors.forBackground(.black)
    private var toolTipTag: NSView.ToolTipTag?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The stripe sits in the gutter's interactive area so it can show a tooltip. The click stays
    /// here: forwarding it would make `TextInputView` treat the column as a line number.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override var frame: NSRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            if let toolTipTag { removeToolTip(toolTipTag) }
            toolTipTag = addToolTip(bounds, owner: self, userData: nil)
        }
    }

    func apply(background: NSColor) {
        let next = GutterChangeColors.forBackground(background)
        guard next != colors else { return }
        colors = next
        needsDisplay = true
    }

    func changesDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let lineManager, lineManager.lineCount > 0,
              !store.isEmpty else { return }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1)
        guard minRow <= maxRow else { return }
        let firstLine = minRow + 1
        let lastLine = maxRow + 1
        for change in store.changes(touchingLines: firstLine, lastLine + 1) {
            if change.kind == .deleted {
                guard let rect = deletionRect(change, lineManager: lineManager) else { continue }
                context.setFillColor(colors.deleted.cgColor)
                context.addPath(triangle(in: rect))
                context.fillPath()
            } else if let rect = barRect(change, lineManager: lineManager) {
                context.setFillColor(colors.color(for: change.kind).cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                context.fillPath()
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        change(atLocalY: point.y)?.tooltip ?? ""
    }

    // MARK: - Geometry

    private func barRect(_ change: GutterChange, lineManager: LineManager) -> CGRect? {
        let first = change.firstRow
        let last = change.endRow - 1
        guard first >= 0, last >= first, last < lineManager.lineCount else { return nil }
        let top = textContainerInsetTop + lineManager.yPosition(ofRow: first)
        let bottom = textContainerInsetTop + lineManager.yPosition(ofRow: last) + lineManager.lineInfo(atRow: last).lineHeight
        guard bottom > top else { return nil }
        let x = (bounds.width - Self.barWidth) / 2
        return CGRect(x: x, y: top - frame.minY, width: Self.barWidth, height: bottom - top)
    }

    private func deletionRect(_ change: GutterChange, lineManager: LineManager) -> CGRect? {
        let lineCount = lineManager.lineCount
        let boundary: CGFloat
        if change.line <= 1 {
            boundary = textContainerInsetTop
        } else if change.line > lineCount {
            let last = lineCount - 1
            boundary = textContainerInsetTop + lineManager.yPosition(ofRow: last) + lineManager.lineInfo(atRow: last).lineHeight
        } else {
            let row = change.line - 1
            guard lineManager.lineInfo(atRow: row).lineHeight > 0 || row == 0 else { return nil }
            boundary = textContainerInsetTop + lineManager.yPosition(ofRow: row)
        }
        let size = Self.triangleSize
        let x = (bounds.width - size) / 2
        return CGRect(x: x, y: boundary - frame.minY - size / 2, width: size, height: size)
    }

    private func triangle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func change(atLocalY localY: CGFloat) -> GutterChange? {
        guard let lineManager, let row = row(atLocalY: localY) else { return nil }
        let line = row + 1
        let marks = store.changes(touchingLines: line, line)
        let boundary = textContainerInsetTop + lineManager.yPosition(ofRow: row)
        if abs((localY + frame.minY) - boundary) < Self.triangleSize,
           let deletion = marks.first(where: { $0.kind == .deleted && $0.line == line }) {
            return deletion
        }
        return marks.first { $0.kind != .deleted && $0.line <= line && line < $0.line + $0.lineCount }
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        return lineManager.row(containingYOffset: max(localY + frame.minY - textContainerInsetTop, 0))
    }
}
