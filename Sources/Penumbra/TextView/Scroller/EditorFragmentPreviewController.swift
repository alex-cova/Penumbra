@preconcurrency import AppKit
import Foundation

/// One highlighted line in the scrollbar preview.
struct EditorFragmentPreviewLine {
    /// 1-based line number.
    let number: Int
    let text: NSAttributedString
}

/// The lines, colours and metrics the preview panel draws.
struct EditorFragmentPreviewContent {
    var lines: [EditorFragmentPreviewLine]
    var rowHeight: CGFloat
    var textBackgroundColor: NSColor
    var lineNumberColor: NSColor
    var lineNumberFont: NSFont
    var borderColor: NSColor
}

/// Shows the code under a scrollbar or minimap hover, and jumps to the popup's first line on click.
///
/// The popup ignores the mouse, so the click lands on the strip. It opens after a short pause
/// (immediately with Option held) and only for a position whose line is off screen.
@MainActor
final class EditorFragmentPreviewController {
    weak var textView: TextView?
    /// How long the pointer rests before the first popup. Zero shows it on the next move.
    var hoverDelay: TimeInterval = 0.3

    private var hoverTask: Task<Void, Never>?
    private var previewPanel: NSPanel?
    private var pending: Pending?
    private var rows: [Int] = []
    private var anchorRow: Int?
    private var popupTopInTextView: CGFloat = 0
    private var wheelRemainder: CGFloat = 0
    private var isStripDrag = false

    private struct Pending {
        var anchorRow: Int
        var point: CGPoint
        var stripFrame: CGRect
    }

    var isShowing: Bool {
        guard let previewPanel else {
            return false
        }
        return previewPanel.parent != nil && previewPanel.isVisible
    }

    var shownRows: [Int] { rows }
    var popupTopForTesting: CGFloat { popupTopInTextView }
    var panelFrameForTesting: CGRect? { previewPanel?.frame }

    func mouseMoved(to point: CGPoint, showsImmediately: Bool) {
        guard !isStripDrag, let textView else {
            return
        }
        guard let hit = textView.editorFragmentHit(at: point), !hit.isOnScreen else {
            dismiss()
            return
        }
        pending = Pending(anchorRow: hit.anchorRow, point: point, stripFrame: hit.stripFrame)
        if isShowing {
            showPending(reposition: true)
            return
        }
        if showsImmediately || hoverDelay <= 0 {
            hoverTask?.cancel()
            hoverTask = nil
            showPending(reposition: true)
            return
        }
        guard hoverTask == nil else {
            return
        }
        hoverTask = Task { [weak self] in
            let delay = self?.hoverDelay ?? 0.3
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.hoverTask = nil
            self?.showPending(reposition: true)
        }
    }

    func dismiss() {
        hoverTask?.cancel()
        hoverTask = nil
        pending = nil
        rows = []
        anchorRow = nil
        wheelRemainder = 0
        hidePanel()
    }

    func beginDrag() {
        isStripDrag = true
        dismiss()
    }

    func endDrag() {
        isStripDrag = false
    }

    /// Jump to the first line in the popup. Returns false when nothing is showing.
    func consumeClick() -> Bool {
        guard isShowing, let textView, let row = rows.first else {
            return false
        }
        let top = popupTopInTextView
        dismiss()
        textView.jumpToEditorFragment(row: row, aligningWith: top)
        return true
    }

    /// Move the previewed line instead of the editor. Returns false when the popup is closed,
    /// so the caller can scroll the editor.
    func consumeScroll(deltaY: CGFloat) -> Bool {
        guard isShowing, let textView, let anchorRow, var pending else {
            return false
        }
        let lineHeight = max(textView.editorFragmentRowHeight, 1)
        wheelRemainder += deltaY
        let steps = Int(wheelRemainder / lineHeight)
        guard steps != 0 else {
            return true
        }
        wheelRemainder -= CGFloat(steps) * lineHeight
        // A positive delta is a scroll upward: show the lines above the current anchor.
        let next = textView.editorFragmentAnchor(from: anchorRow, movingBy: -steps)
        pending.anchorRow = next
        self.pending = pending
        showPending(reposition: false)
        return true
    }

    private func showPending(reposition: Bool) {
        guard let pending, let textView, textView.window != nil else {
            return
        }
        let window = textView.editorFragmentRowWindow(anchorRow: pending.anchorRow)
        guard !window.rows.isEmpty else {
            dismiss()
            return
        }
        let rowsChanged = window.rows != rows || previewPanel?.parent == nil
        rows = window.rows
        anchorRow = window.anchorRow
        if rowsChanged {
            guard let content = textView.editorFragmentPreviewContent(forRows: window.rows) else {
                return
            }
            let width = max(pending.stripFrame.minX - 8, 120)
            let contentView = EditorFragmentPreviewView(content: content)
            let size = contentView.fittingSize(width: width)
            contentView.frame = CGRect(origin: .zero, size: size)
            contentView.applyAppearance(from: textView)
            place(contentView: contentView, size: size, pending: pending, reposition: reposition)
        } else if reposition {
            place(contentView: nil, size: previewPanel?.frame.size ?? .zero, pending: pending, reposition: true)
        } else if let panel = previewPanel {
            rememberPopupTop(of: panel, in: textView)
        }
    }

    private func place(contentView: NSView?, size: CGSize, pending: Pending, reposition: Bool) {
        guard let textView, let window = textView.window, size.width > 0, size.height > 0 else {
            return
        }
        let panel = previewPanel ?? makePanel()
        previewPanel = panel
        if let contentView {
            panel.contentView = contentView
        }
        if reposition || panel.parent == nil {
            let anchorInWindow = textView.convert(pending.point, to: nil)
            let anchorScreen = window.convertToScreen(CGRect(origin: anchorInWindow, size: .zero)).origin
            let stripScreen = window.convertToScreen(textView.convert(pending.stripFrame, to: nil))
            var origin = CGPoint(x: stripScreen.minX - size.width - 4, y: anchorScreen.y - size.height / 2)
            let viewScreen = window.convertToScreen(textView.convert(textView.bounds, to: nil))
            origin.y = min(max(origin.y, viewScreen.minY), max(viewScreen.minY, viewScreen.maxY - size.height))
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
                origin.x = max(origin.x, visible.minX)
            }
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        } else {
            let top = panel.frame.maxY
            panel.setFrame(
                CGRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                display: true
            )
        }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        rememberPopupTop(of: panel, in: textView)
    }

    private func rememberPopupTop(of panel: NSPanel, in textView: TextView) {
        guard let window = textView.window else {
            return
        }
        let topScreen = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let topWindow = window.convertFromScreen(NSRect(origin: topScreen, size: .zero)).origin
        popupTopInTextView = textView.convert(topWindow, from: nil).y
    }

    private func hidePanel() {
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

/// Draws the preview rows: a line-number column and the highlighted text, clipped to the panel.
private final class EditorFragmentPreviewView: NSView {
    private let content: EditorFragmentPreviewContent
    private let padding = CGSize(width: 10, height: 6)
    private let numberGap: CGFloat = 12
    private let numberColumnWidth: CGFloat

    override var isFlipped: Bool { true }

    init(content: EditorFragmentPreviewContent) {
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

    func fittingSize(width: CGFloat) -> CGSize {
        CGSize(width: max(width, 120), height: padding.height * 2 + CGFloat(content.lines.count) * content.rowHeight)
    }

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
        let textWidth = max(bounds.width - textX - padding.width, 0)
        for (index, line) in content.lines.enumerated() {
            let rowY = padding.height + CGFloat(index) * content.rowHeight
            let number = NSAttributedString(string: String(line.number), attributes: [
                .font: content.lineNumberFont,
                .foregroundColor: content.lineNumberColor
            ])
            let numberSize = number.size()
            number.draw(at: CGPoint(
                x: padding.width + numberColumnWidth - numberSize.width,
                y: rowY + (content.rowHeight - numberSize.height) / 2
            ))
            let rect = CGRect(x: textX, y: rowY, width: textWidth, height: content.rowHeight)
            line.text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }
}
