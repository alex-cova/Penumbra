import AppKit

/// The strip between the two sides: a ribbon joining each change's lines on the left to its lines
/// on the right, and per change the chevron (put the left lines in place of the right ones, ⌥ to
/// add them after instead) and, for index comparisons, Stage or Unstage.
@MainActor
final class IDEDiffDividerView: NSView {
    weak var viewer: IDEDiffViewerView?

    private enum Action {
        case applyLeft
        case index(IDEDiffRequest.IndexAction)
    }

    private struct Button {
        let rect: CGRect
        let chunk: Int
        let action: Action
    }

    private var buttons: [Button] = []
    private static let buttonSize: CGFloat = 14

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        IDEAppearance.NSToken.editor.setFill()
        bounds.fill()
        buttons = []
        removeAllToolTips()
        guard let viewer, let session = viewer.session, session.state == .ready else { return }
        let width = bounds.width
        let canApply = session.isRightEditable && !session.isStale && !session.isBusy
        let indexAction = session.isStale || session.isBusy ? nil : session.request.indexAction
        for (index, chunk) in session.chunks.enumerated() {
            let leftTop = viewer.dividerY(ofLine: chunk.left.lowerBound + 1, onRight: false)
            let leftBottom = viewer.dividerY(ofLine: chunk.left.upperBound + 1, onRight: false)
            let rightTop = viewer.dividerY(ofLine: chunk.right.lowerBound + 1, onRight: true)
            let rightBottom = viewer.dividerY(ofLine: chunk.right.upperBound + 1, onRight: true)
            if max(leftBottom, rightBottom) < -Self.buttonSize { continue }
            if min(leftTop, rightTop) > bounds.height + Self.buttonSize { break }
            let color = IDEDiffViewerView.ribbonColor(chunk.kind)
            let ribbon = NSBezierPath()
            ribbon.move(to: CGPoint(x: 0, y: leftTop))
            ribbon.curve(to: CGPoint(x: width, y: rightTop),
                         controlPoint1: CGPoint(x: width / 2, y: leftTop),
                         controlPoint2: CGPoint(x: width / 2, y: rightTop))
            ribbon.line(to: CGPoint(x: width, y: rightBottom))
            ribbon.curve(to: CGPoint(x: 0, y: leftBottom),
                         controlPoint1: CGPoint(x: width / 2, y: rightBottom),
                         controlPoint2: CGPoint(x: width / 2, y: leftBottom))
            ribbon.close()
            color.withAlphaComponent(0.16).setFill()
            ribbon.fill()
            color.withAlphaComponent(0.55).setStroke()
            ribbon.lineWidth = 1
            ribbon.stroke()

            if canApply {
                let rect = CGRect(x: 2, y: max(0, leftTop) + 1, width: Self.buttonSize, height: Self.buttonSize)
                draw(symbol: "chevron.right.2", in: rect, color: color)
                buttons.append(Button(rect: rect, chunk: index, action: .applyLeft))
                addToolTip(rect, owner: self, userData: nil)
            }
            if let indexAction {
                let rect = CGRect(x: width - Self.buttonSize - 2, y: max(0, rightTop) + 1, width: Self.buttonSize, height: Self.buttonSize)
                draw(symbol: indexAction == .stage ? "plus.circle" : "minus.circle", in: rect, color: color)
                buttons.append(Button(rect: rect, chunk: index, action: .index(indexAction)))
                addToolTip(rect, owner: self, userData: nil)
            }
        }
    }

    private func draw(symbol name: String, in rect: CGRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = buttons.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        switch button.action {
        case .applyLeft:
            viewer?.applyLeftToRight(chunk: button.chunk, append: event.modifierFlags.contains(.option))
        case .index:
            viewer?.session?.applyToIndex(chunkAt: button.chunk)
        }
    }

    override func resetCursorRects() {
        for button in buttons {
            addCursorRect(button.rect, cursor: .pointingHand)
        }
    }
}

extension IDEDiffDividerView: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            guard let button = buttons.first(where: { $0.rect.contains(point) }) else { return "" }
            switch button.action {
            case .applyLeft: return "Replace with the left side (⌥-click to append)"
            case .index(.stage): return "Stage this change"
            case .index(.unstage): return "Unstage this change"
            }
        }
    }
}
