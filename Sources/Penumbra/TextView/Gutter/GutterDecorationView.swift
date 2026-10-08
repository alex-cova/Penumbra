@preconcurrency import AppKit
import Foundation

/// Draws gutter decoration icons at document line Y positions and reports clicks.
final class GutterDecorationView: EditorView {
    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    var decorations: [GutterDecoration] = [] {
        didSet { needsDisplay = true }
    }
    var onLineClicked: ((Int) -> Void)?
    /// A click on a line without a decoration, or any secondary click. Returns whether it was
    /// handled.
    var onGutterLineClicked: ((GutterLineClick) -> Bool)?
    var iconColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    private let iconSize: CGFloat = 15

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let line = anyLine(atLocalY: point.y) else {
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.control) {
            let decoration = decorations.first { $0.line == line }
            if onGutterLineClicked?(GutterLineClick(line: line, isSecondary: true, event: event, decoration: decoration)) != true {
                super.mouseDown(with: event)
            }
            return
        }
        if decorations.contains(where: { $0.line == line }), let onLineClicked {
            onLineClicked(line)
            return
        }
        if onGutterLineClicked?(GutterLineClick(line: line, isSecondary: false, event: event)) != true {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let line = anyLine(atLocalY: point.y),
              onGutterLineClicked?(GutterLineClick(
                  line: line, isSecondary: true, event: event, decoration: decorations.first { $0.line == line }
              )) == true else {
            super.rightMouseDown(with: event)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let lineManager else { return }
        let lineCount = lineManager.lineCount
        for decoration in decorations {
            guard decoration.line >= 1, decoration.line <= lineCount else { continue }
            // Positions only: a `line(atRow:)` handle per decoration would be walked by every edit.
            let y = textContainerInsetTop + lineManager.yPosition(ofRow: decoration.line - 1)
                + lineManager.textTopInset(ofRow: decoration.line - 1) + 2
            let rect = CGRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
            guard rect.intersects(dirtyRect) else { continue }
            decoration.drawIcon(in: rect, defaultColor: iconColor)
        }
    }

    /// The 1-based line at `y`, decorated or not; `nil` above the first line or below the last.
    private func anyLine(atLocalY y: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        let contentY = y - textContainerInsetTop
        guard contentY >= 0, let row = lineManager.row(containingYOffset: contentY) else { return nil }
        let info = lineManager.lineInfo(atRow: row)
        guard contentY < lineManager.yPosition(ofRow: row) + info.lineHeight else { return nil }
        return row + 1
    }
}

extension GutterDecoration {
    /// Draws the icon, and its badge, filling the square `rect`.
    func drawIcon(in rect: CGRect, defaultColor: NSColor) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
        guard let context = NSGraphicsContext.current?.cgContext,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
                .withSymbolConfiguration(symbolConfig) else { return }
        let color = tintColor.flatMap { NSColor(cgColor: $0) } ?? defaultColor
        context.saveGState()
        image.tinted(with: color).draw(in: rect)
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: rect.height * 0.55, weight: .bold)
        if let badgeSymbolName,
           let badge = NSImage(systemSymbolName: badgeSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeConfig) {
            let side = rect.height * 0.6
            let badgeRect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            badge.tinted(with: .white).draw(in: badgeRect)
        }
        context.restoreGState()
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
