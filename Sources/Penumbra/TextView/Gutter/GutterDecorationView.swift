@preconcurrency import AppKit
import Foundation

/// Draws gutter decoration icons at document line Y positions and reports clicks.
final class GutterDecorationView: UIView {
    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    var decorations: [GutterDecoration] = [] {
        didSet { needsDisplay = true }
    }
    var onLineClicked: ((Int) -> Void)?
    var iconColor: UIColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    private let iconSize: CGFloat = 12

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
        guard let line = line(atLocalY: point.y) else {
            super.mouseDown(with: event)
            return
        }
        onLineClicked?(line)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let lineManager else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        for decoration in decorations {
            guard decoration.line >= 1, decoration.line <= lineManager.lineCount else { continue }
            let lineNode = lineManager.line(atRow: decoration.line - 1)
            let y = textContainerInsetTop + lineNode.yPosition + 2
            let rect = CGRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
            guard rect.intersects(dirtyRect) else { continue }
            guard let image = NSImage(systemSymbolName: decoration.symbolName, accessibilityDescription: decoration.accessibilityLabel)?
                .withSymbolConfiguration(symbolConfig) else { continue }
            context.saveGState()
            iconColor.setFill()
            let tinted = image.tinted(with: iconColor)
            tinted.draw(in: rect)
            context.restoreGState()
        }
    }

    private func line(atLocalY y: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        let contentY = y - textContainerInsetTop
        guard contentY >= 0,
              let lineNode = lineManager.line(containingYOffset: contentY) else { return nil }
        let lineNumber = lineNode.index + 1
        return decorations.contains(where: { $0.line == lineNumber }) ? lineNumber : nil
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
