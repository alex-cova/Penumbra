@preconcurrency import AppKit

/// Pins the headers of the blocks around the first visible line — class, method, `if`, `for` —
/// to the top of the editor while their bodies scroll by (IntelliJ's sticky lines).
///
/// Per scrolled frame this does a handful of row lookups: the scopes around each probe row come
/// from ``StickyScopeResolver`` and are cached by row until an edit, a parse or a style change
/// drops them, and a row's highlighted text is cached the same way. Nothing here walks the
/// document or takes a line handle.
@MainActor
final class StickyLinesController {
    private weak var textView: TextView?
    let view = StickyLinesView()

    var isEnabled = false {
        didSet {
            if isEnabled != oldValue {
                if !isEnabled {
                    hide()
                }
                invalidate()
            }
        }
    }
    var maximumLineCount = 5 {
        didSet {
            maximumLineCount = min(max(maximumLineCount, 1), 10)
            if maximumLineCount != oldValue {
                invalidate()
            }
        }
    }
    /// Right-click on a pinned line; the host fills the menu.
    var contextMenuProvider: (() -> NSMenu?)?

    private var scopeCache: [Int: [StickyScope]] = [:]
    private var textCache: [Int: NSAttributedString] = [:]
    private var lastModel: Model?
    private static let cacheLimit = 64

    private struct Entry: Equatable {
        var scope: StickyScope
        /// Pushed up by the end of its block, in -rowHeight...0.
        var offset: CGFloat
    }

    private struct Model: Equatable {
        var entries: [Entry]
        var frame: CGRect
        var style: StickyLineStyle
    }

    init(textView: TextView) {
        self.textView = textView
    }

    /// Rows or text changed, or a style did: forget what was cached and recompute on the next pass.
    func invalidate() {
        scopeCache.removeAll(keepingCapacity: true)
        textCache.removeAll(keepingCapacity: true)
        lastModel = nil
        textView?.setNeedsLayout()
    }

    /// The scopes the panel currently shows, outermost first (tests and click handling).
    private(set) var shownScopes: [StickyScope] = []

    func update() {
        guard isEnabled, let textView else {
            hide()
            return
        }
        let input = textView.stickyLinesInput
        guard input.hasStickyScopeSource, input.lineManager.lineCount > 1 else {
            hide()
            return
        }
        let rowHeight = input.stickyRowHeight
        let area = textView.stickyLinesAvailableFrame
        guard rowHeight > 0, area.width > 0 else {
            hide()
            return
        }
        let viewportTop = textView.contentOffset.y + textView.adjustedContentInset.top
        let entries = resolveEntries(input: input, viewportTop: viewportTop, rowHeight: rowHeight)
        guard !entries.isEmpty else {
            hide()
            return
        }
        let frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: CGFloat(entries.count) * rowHeight)
        let style = makeStyle(input: input, textView: textView, contentOffsetX: textView.contentOffset.x)
        let model = Model(entries: entries, frame: frame, style: style)
        guard model != lastModel else {
            return
        }
        lastModel = model
        apply(model, rowHeight: rowHeight, input: input)
    }

    // MARK: - Resolving

    private func scopes(aroundRow row: Int, input: TextInputView) -> [StickyScope] {
        if let cached = scopeCache[row] {
            return cached
        }
        if scopeCache.count >= Self.cacheLimit {
            scopeCache.removeAll(keepingCapacity: true)
        }
        let resolved = input.stickyScopes(containingRow: row)
        scopeCache[row] = resolved
        return resolved
    }

    /// Slot `d` shows the `d`-th enclosing block of the row at the top of that slot, so a block
    /// stays pinned until its end has scrolled past the top of its slot; its header slides up as
    /// the end approaches the bottom of the slot.
    private func resolveEntries(input: TextInputView, viewportTop: CGFloat, rowHeight: CGFloat) -> [Entry] {
        let inset = input.textContainerInset.top
        func entries(dropOuter: Int) -> (entries: [Entry], lastChainCount: Int) {
            var result: [Entry] = []
            var lastChainCount = 0
            for slot in 0 ..< maximumLineCount {
                let slotTop = viewportTop + CGFloat(slot) * rowHeight
                guard let row = input.lineManager.row(containingYOffset: slotTop - inset) else {
                    break
                }
                let chain = scopes(aroundRow: row, input: input)
                lastChainCount = chain.count
                let index = slot + dropOuter
                guard index < chain.count else {
                    break
                }
                let scope = chain[index]
                if let previous = result.last, scope.headerRow <= previous.scope.headerRow {
                    break
                }
                let endBottom = input.yPosition(ofRow: scope.endRow + 1)
                let offset = min(0, endBottom - slotTop - rowHeight)
                result.append(Entry(scope: scope, offset: offset))
            }
            return (result, lastChainCount)
        }
        let first = entries(dropOuter: 0)
        // More blocks around the last slot than there are slots: keep the innermost ones.
        if first.entries.count == maximumLineCount, first.lastChainCount > maximumLineCount {
            return entries(dropOuter: first.lastChainCount - maximumLineCount).entries
        }
        return first.entries
    }

    // MARK: - Showing

    private func hide() {
        lastModel = nil
        shownScopes = []
        if !view.isHidden {
            view.isHidden = true
        }
    }

    private func makeStyle(input: TextInputView, textView: TextView, contentOffsetX: CGFloat) -> StickyLineStyle {
        let theme = textView.theme
        let gutterWidth = input.stickyGutterWidth
        let background = theme.stickyLinesBackgroundColor ?? textView.backgroundColor ?? .textBackgroundColor
        return StickyLineStyle(
            background: background,
            hoverBackground: theme.stickyLinesHoverColor.blended(over: background),
            gutterBackground: theme.gutterBackgroundColor.blended(over: background),
            lineNumberColor: theme.lineNumberColor,
            lineNumberFont: theme.lineNumberFont,
            border: theme.stickyLinesBorderColor,
            gutterWidth: gutterWidth,
            textOriginX: input.stickyTextOriginX - contentOffsetX
        )
    }

    private func apply(_ model: Model, rowHeight: CGFloat, input: TextInputView) {
        shownScopes = model.entries.map(\.scope)
        view.frame = model.frame
        view.rowViews.forEach { $0.frame.size.width = model.frame.width }
        for (index, entry) in model.entries.enumerated() {
            let row = view.rowView(at: index)
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight + entry.offset, width: model.frame.width, height: rowHeight)
            row.configure(lineNumber: entry.scope.headerRow + 1,
                          text: text(forRow: entry.scope.headerRow, input: input),
                          style: model.style,
                          drawsBorder: index == model.entries.count - 1)
            row.onClick = { [weak self] in self?.select(slot: index) }
            row.onContextMenu = { [weak self] _ in self?.contextMenuProvider?() }
        }
        view.showRows(count: model.entries.count)
        view.isHidden = false
    }

    private func text(forRow row: Int, input: TextInputView) -> NSAttributedString? {
        if let cached = textCache[row] {
            return cached
        }
        if textCache.count >= Self.cacheLimit {
            textCache.removeAll(keepingCapacity: true)
        }
        let content = input.stickyLineContent(forRow: row)
        textCache[row] = content
        return content
    }

    // MARK: - Interaction

    /// Puts the caret on the header of the block in `slot` and scrolls so that header lands just
    /// below the lines still pinned above it.
    func select(slot: Int) {
        guard let textView, slot >= 0, slot < shownScopes.count else {
            return
        }
        let input = textView.stickyLinesInput
        let headerRow = shownScopes[slot].headerRow
        guard headerRow < input.lineManager.lineCount else {
            return
        }
        let range = input.lineManager.contentRange(atRow: headerRow)
        var caret = range.location
        if let line = input.stringView.substring(in: range) {
            let indent = line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
            caret += indent
        }
        textView.selectedRange = NSRange(location: caret, length: 0)
        let rowHeight = input.stickyRowHeight
        let targetY = input.yPosition(ofRow: headerRow) - CGFloat(slot) * rowHeight - textView.adjustedContentInset.top
        textView.contentOffset = CGPoint(x: textView.contentOffset.x, y: max(targetY, -textView.adjustedContentInset.top))
        update()
    }
}

private extension NSColor {
    /// A translucent color composited over an opaque background, so a pinned line stays opaque.
    func blended(over background: NSColor) -> NSColor {
        guard alphaComponent < 1 else { return self }
        return background.blended(withFraction: alphaComponent, of: self.withAlphaComponent(1)) ?? self
    }
}
