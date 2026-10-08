@preconcurrency import AppKit
import Foundation

/// One line of a fold preview: its 1-based line number and the highlighted text.
struct FoldPreviewLine {
    let number: Int
    let text: NSAttributedString
}

/// What the fold preview shows: the header line, the lines a collapsed fold hides and the closing
/// bracket line, highlighted like the editor.
struct FoldPreviewContent {
    var lines: [FoldPreviewLine]
    var isTruncated: Bool
    var rowHeight: CGFloat
    var textBackgroundColor: NSColor
    var textColor: NSColor
    var lineNumberColor: NSColor
    var lineNumberFont: NSFont
    var borderColor: NSColor
    /// The header line's full-width rect in the text input's coordinates. The panel opens just below it.
    var anchorRect: CGRect
}

/// Shows a hover preview of the code a collapsed fold region hides, like a tooltip under the
/// `{...}` chip: the header line and the folded lines with their line numbers, in the editor's
/// colours. The panel ignores the mouse, so moving onto it reaches the text view and dismisses it.
@MainActor
final class FoldPreviewController {
    weak var textInputView: TextInputView?

    private var hoverTask: Task<Void, Never>?
    private var previewPanel: NSPanel?
    private var hoveredRegionID: UUID?

    private let maxPreviewLines = 20
    /// How long the pointer rests on the chip before the preview opens.
    var hoverDelay: TimeInterval = 0.5

    func mouseMoved(at pointInTextInput: CGPoint, placeholderRect: CGRect?, region: FoldRegion?) {
        guard let region, let placeholderRect, placeholderRect.contains(pointInTextInput), region.isCollapsed else {
            dismiss()
            return
        }
        // Still over the chip that is pending or showing.
        guard hoveredRegionID != region.id else {
            return
        }
        hoverTask?.cancel()
        hidePreview()
        hoveredRegionID = region.id
        hoverTask = Task { [weak self] in
            let delay = self?.hoverDelay ?? 0.5
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.showPreview(for: region)
        }
    }

    func dismiss() {
        hoverTask?.cancel()
        hoveredRegionID = nil
        hidePreview()
    }

    private func showPreview(for region: FoldRegion) {
        guard let textInputView, let window = textInputView.window,
              let content = textInputView.foldPreviewContent(for: region, maximumLines: maxPreviewLines) else {
            return
        }
        let contentView = FoldPreviewContentView(content: content)
        let size = contentView.fittingSize(maximumWidth: max(240, content.anchorRect.width - 16))
        contentView.frame = CGRect(origin: .zero, size: size)
        contentView.applyAppearance(from: textInputView)

        let anchor = window.convertToScreen(textInputView.convert(content.anchorRect, to: nil))
        var origin = CGPoint(x: anchor.minX + 8, y: anchor.minY - size.height)
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visibleFrame.minY {
                origin.y = anchor.maxY
            }
            origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        }

        let panel = previewPanel ?? makePanel()
        previewPanel = panel
        panel.contentView = contentView
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func hidePreview() {
        guard let panel = previewPanel else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        return panel
    }
}

/// Draws the preview rows: a right-aligned line-number column and the highlighted text.
private final class FoldPreviewContentView: NSView {
    private let content: FoldPreviewContent
    private let padding = CGSize(width: 10, height: 6)
    private let numberGap: CGFloat = 12
    private let numberColumnWidth: CGFloat

    override var isFlipped: Bool { true }

    init(content: FoldPreviewContent) {
        self.content = content
        let digits = String(content.lines.map(\.number).max() ?? 0).count
        let sample = String(repeating: "8", count: max(digits, 2)) as NSString
        numberColumnWidth = ceil(sample.size(withAttributes: [.font: content.lineNumberFont]).width)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func fittingSize(maximumWidth: CGFloat) -> CGSize {
        let textWidth = content.lines.map { ceil($0.text.size().width) }.max() ?? 0
        let width = padding.width * 2 + numberColumnWidth + numberGap + textWidth
        let rowCount = content.lines.count + (content.isTruncated ? 1 : 0)
        return CGSize(
            width: min(maximumWidth, max(240, width)),
            height: padding.height * 2 + CGFloat(rowCount) * content.rowHeight
        )
    }

    /// Resolves the dynamic colours against the editor's appearance; a layer keeps a baked `CGColor`.
    func applyAppearance(from view: NSView) {
        appearance = view.effectiveAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = content.textBackgroundColor.cgColor
            layer?.borderColor = content.borderColor.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let textX = padding.width + numberColumnWidth + numberGap
        for (index, line) in content.lines.enumerated() {
            let rowY = padding.height + CGFloat(index) * content.rowHeight
            let number = NSAttributedString(string: String(line.number), attributes: [
                .font: content.lineNumberFont,
                .foregroundColor: content.lineNumberColor
            ])
            let numberSize = number.size()
            number.draw(at: CGPoint(x: padding.width + numberColumnWidth - numberSize.width,
                                    y: rowY + (content.rowHeight - numberSize.height) / 2))
            let textHeight = line.text.size().height
            line.text.draw(at: CGPoint(x: textX, y: rowY + (content.rowHeight - textHeight) / 2))
        }
        if content.isTruncated {
            let ellipsis = NSAttributedString(string: "…", attributes: [
                .font: content.lineNumberFont,
                .foregroundColor: content.lineNumberColor
            ])
            let rowY = padding.height + CGFloat(content.lines.count) * content.rowHeight
            ellipsis.draw(at: CGPoint(x: textX, y: rowY + (content.rowHeight - ellipsis.size().height) / 2))
        }
    }
}
