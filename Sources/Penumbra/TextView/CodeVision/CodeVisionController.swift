@preconcurrency import AppKit
import EditorIntelligence

/// Draws the lenses of the rows on screen and sends clicks to the host.
///
/// Per frame this reads the lenses on the visible rows from the store (a binary search and a few
/// row lookups), moves reused label views and gives them their entries; a label only redraws when
/// its entries changed. It never takes a line handle or reads the document beyond the leading
/// whitespace of the lens rows it shows.
@MainActor
final class CodeVisionController {
    private weak var textView: TextView?
    let view = CodeVisionView()

    /// Called with the clicked label and the UTF-16 offset of the declaration's name.
    var handler: ((CodeVisionEntry, Int) -> Void)?

    init(textView: TextView) {
        self.textView = textView
    }

    /// The rows whose lens is shown, for tests.
    private(set) var shownRows: [Int] = []

    func update() {
        guard let textView else { return }
        let input = textView.stickyLinesInput
        let store = input.codeVisionStore
        guard !store.isEmpty, store.rowHeight > 0, input.lineManager.lineCount > 0 else {
            hide()
            return
        }
        let inset = input.textContainerInset.top
        let top = textView.contentOffset.y
        let bottom = top + textView.bounds.height
        let lineManager = input.lineManager
        let firstRow = lineManager.row(containingYOffset: top - inset) ?? 0
        let lastRow = lineManager.row(containingYOffset: bottom - inset) ?? max(lineManager.lineCount - 1, 0)
        let gutterWidth = input.stickyGutterWidth
        let reservedTrailing = textView.showMinimap ? textView.minimapWidth : 0
        view.frame = CGRect(x: gutterWidth, y: 0, width: max(textView.bounds.width - gutterWidth - reservedTrailing, 0),
                            height: textView.bounds.height)
        let appearance = input.inlayHintAppearanceForTesting
        var rows: [Int] = []
        var count = 0
        for lens in store.lenses(inRows: firstRow ... max(lastRow, firstRow)) where !lens.entries.isEmpty {
            guard lens.row < lineManager.lineCount, lineManager.lineInfo(atRow: lens.row).lineHeight > 0 else { continue }
            let label = view.labelView(at: count)
            count += 1
            rows.append(lens.row)
            label.configure(entries: lens.entries, appearance: appearance)
            let rowTop = input.yPosition(ofRow: lens.row) - top
            let x = textStartX(ofRow: lens.row, in: textView, input: input) - gutterWidth
            label.frame = CGRect(x: x, y: rowTop, width: max(label.contentWidth + 2, 0), height: store.rowHeight)
            let row = lens.row
            let column = lens.column
            label.onClick = { [weak self] entry in
                guard let self, let textView = self.textView else { return }
                let offset = textView.stickyLinesInput.lineManager.location(ofRow: row) + column
                self.handler?(entry, offset)
            }
        }
        shownRows = rows
        view.showLabels(count: count)
        view.isHidden = count == 0
    }

    private func hide() {
        shownRows = []
        if !view.isHidden { view.isHidden = true }
    }

    /// X, in the text view's coordinates, of the first non-blank character of `row`, so the lens
    /// lines up with the declaration under it.
    private func textStartX(ofRow row: Int, in textView: TextView, input: TextInputView) -> CGFloat {
        let range = input.lineManager.contentRange(atRow: row)
        var indent = 0
        if let line = input.stringView.substring(in: range) {
            indent = line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
        }
        return textView.caretRectInViewport(at: range.location + indent).minX
    }
}
