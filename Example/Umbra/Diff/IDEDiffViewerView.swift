import AppKit
import Penumbra
import SwiftUI

/// The diff tab's content, laid over the pane's editor while a diff tab is selected: a toolbar,
/// then either the two sides with the ribbon divider between them, or the unified text.
@MainActor
final class IDEDiffViewerView: NSView {
    private(set) var session: IDEDiffSession?
    let leftTextView = TextView()
    let rightTextView = TextView()
    let unifiedTextView = TextView()
    private let divider = IDEDiffDividerView()
    private let toolbarModel = IDEDiffToolbarModel()
    private lazy var toolbarHost = NSHostingView(rootView: IDEDiffToolbar(model: toolbarModel))
    private let leftTitle = NSTextField(labelWithString: "")
    private let rightTitle = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private let delegateProxy = DelegateProxy()
    private var isSyncingScroll = false
    /// True while texts are being set, so their change callbacks are not taken for edits.
    private var isLoadingTexts = false
    private var unifiedLayout: IDEDiffUnifiedLayout?
    /// Set when new texts are shown: the first chunks that arrive for them move to the first change.
    private var revealsFirstChange = false
    private var preferences: IDEPreferences?

    /// Opens the working-tree file at a 0-based line (F4, Jump to Source).
    var onJumpToSource: ((String, Int) -> Void)?

    static let toolbarHeight: CGFloat = 30
    static let titleHeight: CGFloat = 22
    static let dividerWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        for label in [leftTitle, rightTitle, placeholder] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = IDEAppearance.NSToken.muted
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        placeholder.alignment = .center
        addSubview(toolbarHost)
        for textView in [leftTextView, rightTextView, unifiedTextView] {
            textView.backgroundColor = IDEAppearance.NSToken.editor
            textView.theme = IDEEditorTheme.shared.current
            addSubview(textView)
        }
        addSubview(divider)
        divider.viewer = self
        delegateProxy.owner = self
        rightTextView.editorDelegate = delegateProxy
        leftTextView.editorDelegate = delegateProxy
        unifiedTextView.editorDelegate = delegateProxy
        leftTextView.addScrollObserver { [weak self] in self?.textViewDidScroll(self?.leftTextView) }
        rightTextView.addScrollObserver { [weak self] in self?.textViewDidScroll(self?.rightTextView) }
        for textView in [leftTextView, rightTextView, unifiedTextView] {
            textView.addKeyDownInterceptor { [weak self, weak textView] event in
                guard let self, let textView else { return false }
                return self.handleKeyDown(event, in: textView)
            }
        }
        toolbarModel.viewer = self
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Showing

    func show(_ session: IDEDiffSession, preferences: IDEPreferences) {
        self.preferences = preferences
        isHidden = false
        guard session !== self.session else {
            applyPreferences()
            return
        }
        self.session?.onTextsLoaded = nil
        self.session?.onChunksChanged = nil
        self.session?.onPresentationChanged = nil
        self.session?.currentRightText = nil
        self.session = session
        toolbarModel.session = session
        session.onTextsLoaded = { [weak self] in self?.loadTexts() }
        session.onChunksChanged = { [weak self] in self?.applyChunks() }
        session.onPresentationChanged = { [weak self] in self?.applyPresentation() }
        session.currentRightText = { [weak self] in self?.rightTextView.text ?? "" }
        applyPreferences()
        loadTexts()
        if session.state == .loading, session.chunks.isEmpty {
            session.reload()
        } else {
            applyChunks()
        }
    }

    /// Hides the viewer, saving the right side's edits (IntelliJ saves diff edits the same way).
    func hide() {
        guard !isHidden else { return }
        session?.save()
        isHidden = true
    }

    /// Drops the session when its tab closes.
    func detach(_ closing: IDEDiffSession) {
        guard closing === session else { return }
        closing.save()
        closing.onTextsLoaded = nil
        closing.onChunksChanged = nil
        closing.onPresentationChanged = nil
        closing.currentRightText = nil
        session = nil
        toolbarModel.session = nil
        for textView in [leftTextView, rightTextView, unifiedTextView] {
            textView.setState(TextViewState(text: ""))
        }
        isHidden = true
    }

    func focus() {
        let target = session?.settings.layout == .unified ? unifiedTextView : rightTextView
        window?.makeFirstResponder(target)
    }

    func applyPreferences() {
        guard let preferences else { return }
        for textView in [leftTextView, rightTextView, unifiedTextView] {
            preferences.apply(to: textView)
            textView.showMinimap = false
            textView.isTypewriterScrollingEnabled = false
            textView.isDistractionFreeModeEnabled = false
            textView.isFocusModeEnabled = false
            textView.showMethodSeparators = false
            textView.backgroundColor = IDEAppearance.NSToken.editor
        }
        unifiedTextView.showLineNumbers = false
        applyEditability()
        applyFolding()
    }

    // MARK: - Content

    private var language: TreeSitterLanguage? {
        guard let path = session?.request.filePath else { return nil }
        return IDELanguageSupport.language(forIdentifier: LanguageIdentifier.identifier(for: URL(fileURLWithPath: path)))
    }

    private func state(for text: String) -> TextViewState {
        let theme = IDEEditorTheme.shared.current
        if let language {
            return TextViewState(text: text, theme: theme, language: language)
        }
        return TextViewState(text: text, theme: theme)
    }

    private func loadTexts() {
        guard let session else { return }
        isLoadingTexts = true
        defer { isLoadingTexts = false }
        leftTitle.stringValue = session.request.left.title
        rightTitle.stringValue = session.request.right.title + (session.request.isRightEditable ? "" : " (read-only)")
        switch session.state {
        case .ready:
            placeholder.isHidden = true
            leftTextView.setState(state(for: session.left.string))
            rightTextView.setState(state(for: session.right.string))
            for textView in [leftTextView, rightTextView] {
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            revealsFirstChange = true
            unifiedLayout = nil
            unifiedTextView.setState(TextViewState(text: ""))
        case .loading:
            placeholder.stringValue = "Loading…"
            placeholder.isHidden = false
        case .binary:
            placeholder.stringValue = "Binary files are not compared."
            placeholder.isHidden = false
        case .failed(let message):
            placeholder.stringValue = message
            placeholder.isHidden = false
        }
        applyEditability()
        applyPresentation()
    }

    private func applyEditability() {
        leftTextView.isEditable = false
        unifiedTextView.isEditable = false
        rightTextView.isEditable = session?.isRightEditable ?? false
    }

    /// Layout switch, collapse, sync scroll: what changes without a new diff.
    private func applyPresentation() {
        guard let session else { return }
        let unified = session.settings.layout == .unified
        let ready = session.state == .ready
        leftTextView.isHidden = unified || !ready
        rightTextView.isHidden = unified || !ready
        divider.isHidden = unified || !ready
        leftTitle.isHidden = unified
        unifiedTextView.isHidden = !unified || !ready
        if unified {
            rightTitle.stringValue = "\(session.request.left.title) → \(session.request.right.title)"
            rebuildUnified()
        } else {
            rightTitle.stringValue = session.request.right.title + (session.request.isRightEditable ? "" : " (read-only)")
        }
        applyEditability()
        applyFolding()
        needsLayout = true
        toolbarModel.refresh()
    }

    // MARK: - Chunks

    private func applyChunks() {
        guard let session, session.state == .ready else { return }
        let chunks = session.chunks
        leftTextView.lineBackgrounds = chunks.map { chunk in
            LineBackground(line: chunk.left.lowerBound + 1, lineCount: chunk.left.count, color: Self.bandColor(chunk.kind))
        }
        rightTextView.lineBackgrounds = chunks.map { chunk in
            LineBackground(line: chunk.right.lowerBound + 1, lineCount: chunk.right.count, color: Self.bandColor(chunk.kind))
        }
        leftTextView.highlightedRanges = chunks.flatMap(\.leftFragments).map {
            HighlightedRange(range: $0, color: Self.fragmentColor(.deleted), cornerRadius: 2)
        }
        rightTextView.highlightedRanges = chunks.flatMap(\.rightFragments).map {
            HighlightedRange(range: $0, color: Self.fragmentColor(.inserted), cornerRadius: 2)
        }
        if session.settings.layout == .unified {
            rebuildUnified()
        }
        applyFolding()
        divider.needsDisplay = true
        toolbarModel.refresh()
        if revealsFirstChange, !chunks.isEmpty {
            revealsFirstChange = false
            if session.settings.layout == .unified {
                goToUnifiedChange(forward: true)
            } else {
                select(chunk: 0)
            }
        }
    }

    private func rebuildUnified() {
        guard let session, session.state == .ready else { return }
        let layout = IDEDiffUnifiedLayout(left: session.left, right: session.right, chunks: session.chunks)
        guard layout != unifiedLayout else { return }
        unifiedLayout = layout
        isLoadingTexts = true
        unifiedTextView.setState(state(for: layout.text))
        isLoadingTexts = false
        var bands: [LineBackground] = []
        for rows in layout.chunkRows {
            if !rows.deleted.isEmpty {
                bands.append(LineBackground(line: rows.deleted.lowerBound + 1, lineCount: rows.deleted.count, color: Self.bandColor(.deleted)))
            }
            if !rows.inserted.isEmpty {
                bands.append(LineBackground(line: rows.inserted.lowerBound + 1, lineCount: rows.inserted.count, color: Self.bandColor(.inserted)))
            }
        }
        unifiedTextView.lineBackgrounds = bands
        unifiedTextView.highlightedRanges =
            layout.deletedFragments.map { HighlightedRange(range: $0, color: Self.fragmentColor(.deleted), cornerRadius: 2) }
            + layout.insertedFragments.map { HighlightedRange(range: $0, color: Self.fragmentColor(.inserted), cornerRadius: 2) }
        let width = String(max(layout.oldNumbers.compactMap { $0 }.max() ?? 1, layout.newNumbers.compactMap { $0 }.max() ?? 1)).count
        func pad(_ number: Int?) -> String {
            let text = number.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        unifiedTextView.setGutterAnnotations(layout.oldNumbers.indices.map { row in
            GutterAnnotation(id: row, text: "\(pad(layout.oldNumbers[row])) \(pad(layout.newNumbers[row]))")
        })
        // Keep the place: the change that was current, else the top.
        let row = session.currentChunkIndex.flatMap { layout.chunkRows.indices.contains($0) ? layout.chunkRows[$0].all.lowerBound : nil } ?? 0
        let start = unifiedTextView.location(at: TextLocation(lineNumber: row, column: 0)) ?? 0
        unifiedTextView.selectedRange = NSRange(location: start, length: 0)
        if row > 0 {
            unifiedTextView.scrollRangeToCenter(NSRange(location: start, length: 0))
        }
    }

    /// "Collapse Unchanged Fragments": folds every run of unchanged lines but three on each side
    /// of a change, through a fold provider that replaces the language's.
    private func applyFolding() {
        guard let session else { return }
        let collapse = session.settings.collapsesUnchanged && session.state == .ready
        let targets: [(TextView, [Range<Int>])]
        if session.settings.layout == .unified {
            targets = [(unifiedTextView, unifiedLayout?.chunkRows.map(\.all) ?? [])]
        } else {
            targets = [(leftTextView, session.chunks.map(\.left)), (rightTextView, session.chunks.map(\.right))]
        }
        for (textView, changed) in targets {
            guard collapse else {
                textView.foldingProviderOverride = nil
                textView.isLineFoldingEnabled = false
                continue
            }
            textView.foldingProviderOverride = IDEDiffUnchangedFoldingProvider(changedLines: changed, context: 3)
            textView.isLineFoldingEnabled = true
        }
    }

    // MARK: - Colors

    static func bandColor(_ kind: IDEDiffChunk.Kind) -> CGColor {
        switch kind {
        case .inserted: NSColor.systemGreen.withAlphaComponent(0.13).cgColor
        case .deleted: NSColor.systemRed.withAlphaComponent(0.12).cgColor
        case .modified: NSColor.systemBlue.withAlphaComponent(0.13).cgColor
        }
    }

    static func fragmentColor(_ kind: IDEDiffChunk.Kind) -> NSColor {
        switch kind {
        case .inserted: NSColor.systemGreen.withAlphaComponent(0.3)
        case .deleted: NSColor.systemRed.withAlphaComponent(0.28)
        case .modified: NSColor.systemBlue.withAlphaComponent(0.3)
        }
    }

    static func ribbonColor(_ kind: IDEDiffChunk.Kind) -> NSColor {
        switch kind {
        case .inserted: .systemGreen
        case .deleted: .systemRed
        case .modified: .systemBlue
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        toolbarHost.frame = CGRect(x: 0, y: 0, width: width, height: Self.toolbarHeight)
        let titleY = Self.toolbarHeight
        let contentY = titleY + Self.titleHeight
        let contentHeight = max(0, height - contentY)
        placeholder.frame = CGRect(x: 16, y: contentY + 40, width: max(0, width - 32), height: 20)
        if session?.settings.layout == .unified {
            rightTitle.frame = CGRect(x: 10, y: titleY + 3, width: max(0, width - 20), height: 16)
            unifiedTextView.frame = CGRect(x: 0, y: contentY, width: width, height: contentHeight)
        } else {
            let sideWidth = max(0, (width - Self.dividerWidth) / 2).rounded(.down)
            leftTitle.frame = CGRect(x: 10, y: titleY + 3, width: max(0, sideWidth - 20), height: 16)
            rightTitle.frame = CGRect(x: sideWidth + Self.dividerWidth + 10, y: titleY + 3, width: max(0, sideWidth - 20), height: 16)
            leftTextView.frame = CGRect(x: 0, y: contentY, width: sideWidth, height: contentHeight)
            divider.frame = CGRect(x: sideWidth, y: contentY, width: Self.dividerWidth, height: contentHeight)
            rightTextView.frame = CGRect(x: sideWidth + Self.dividerWidth, y: contentY, width: width - sideWidth - Self.dividerWidth, height: contentHeight)
        }
        divider.needsDisplay = true
    }

    // MARK: - Scrolling

    private func textViewDidScroll(_ source: TextView?) {
        divider.needsDisplay = true
        guard let session, let source, !isSyncingScroll, session.settings.synchronizesScrolling,
              session.settings.layout == .sideBySide, session.state == .ready else { return }
        let fromRight = source === rightTextView
        let target = fromRight ? leftTextView : rightTextView
        // Align the middle of the viewports, as IntelliJ does.
        let middle = source.contentOffset.y + source.bounds.height / 2
        let line = source.line(atYPosition: middle)
        let top = source.yPosition(ofLine: line)
        let height = max(source.yPosition(ofLine: line + 1) - top, 1)
        let fractionalLine = Double(line - 1) + Double((middle - top) / height)
        let mapped = session.mapLine(fractionalLine, fromRight: fromRight)
        let targetLine = Int(mapped.rounded(.down)) + 1
        let targetTop = target.yPosition(ofLine: targetLine)
        let targetHeight = max(target.yPosition(ofLine: targetLine + 1) - targetTop, 1)
        let targetMiddle = targetTop + CGFloat(mapped - mapped.rounded(.down)) * targetHeight
        let maxOffset = max(0, target.contentSize.height - target.bounds.height)
        let offset = min(max(0, targetMiddle - target.bounds.height / 2), maxOffset)
        guard abs(target.contentOffset.y - offset) > 0.5 else { return }
        isSyncingScroll = true
        target.contentOffset = CGPoint(x: target.contentOffset.x, y: offset)
        isSyncingScroll = false
    }

    /// Divider-space y (top of the text views' area is 0) of a 1-based line on one side.
    func dividerY(ofLine line: Int, onRight: Bool) -> CGFloat {
        let textView = onRight ? rightTextView : leftTextView
        return textView.yPosition(ofLine: line) - textView.contentOffset.y
    }

    // MARK: - Actions

    /// The 0-based line holding the caret of `textView`.
    private func caretLine(of textView: TextView) -> Int {
        textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0
    }

    private var activeTextView: TextView {
        if session?.settings.layout == .unified { return unifiedTextView }
        let responder = window?.firstResponder as? NSView
        return responder?.isDescendant(of: leftTextView) == true ? leftTextView : rightTextView
    }

    func goToChange(forward: Bool) {
        guard let session else { return }
        if session.settings.layout == .unified {
            goToUnifiedChange(forward: forward)
            return
        }
        let textView = activeTextView
        let onRight = textView === rightTextView
        let line = caretLine(of: textView)
        let index = forward ? session.chunkIndex(after: line, onRight: onRight) : session.chunkIndex(before: line, onRight: onRight)
        guard let index else {
            // Past the last change, F7 goes on to the next file (IntelliJ does the same).
            if session.canMoveToFile(by: forward ? 1 : -1) { session.moveToFile(by: forward ? 1 : -1) }
            return
        }
        select(chunk: index)
    }

    private func goToUnifiedChange(forward: Bool) {
        guard let session, let layout = unifiedLayout else { return }
        let line = caretLine(of: unifiedTextView)
        let index = forward
            ? layout.chunkRows.firstIndex { $0.all.lowerBound > line }
            : layout.chunkRows.lastIndex { $0.all.lowerBound < line }
        guard let index else {
            if session.canMoveToFile(by: forward ? 1 : -1) { session.moveToFile(by: forward ? 1 : -1) }
            return
        }
        session.currentChunkIndex = index
        let row = layout.chunkRows[index].all.lowerBound
        if let start = unifiedTextView.location(at: TextLocation(lineNumber: row, column: 0)) {
            unifiedTextView.selectedRange = NSRange(location: start, length: 0)
            unifiedTextView.scrollRangeToCenter(NSRange(location: start, length: 0))
        }
        toolbarModel.refresh()
    }

    /// Puts the caret at the start of chunk `index` on both sides and centers it.
    func select(chunk index: Int) {
        guard let session, session.chunks.indices.contains(index) else { return }
        session.currentChunkIndex = index
        let chunk = session.chunks[index]
        for (textView, line) in [(rightTextView, chunk.right.lowerBound), (leftTextView, chunk.left.lowerBound)] {
            let clamped = min(line, max(textView.lineCount - 1, 0))
            if let start = textView.location(at: TextLocation(lineNumber: clamped, column: 0)) {
                textView.selectedRange = NSRange(location: start, length: 0)
            }
        }
        isSyncingScroll = true
        for (textView, line) in [(rightTextView, chunk.right.lowerBound), (leftTextView, chunk.left.lowerBound)] {
            let clamped = min(line, max(textView.lineCount - 1, 0))
            if let start = textView.location(at: TextLocation(lineNumber: clamped, column: 0)) {
                textView.scrollRangeToCenter(NSRange(location: start, length: 0))
            }
        }
        isSyncingScroll = false
        divider.needsDisplay = true
        toolbarModel.refresh()
    }

    /// F4: the working-tree file at the line matching the caret.
    func jumpToSource() {
        guard let session, let path = session.request.workingTreePath ?? session.request.filePath else { return }
        let line: Int
        if session.settings.layout == .unified, let layout = unifiedLayout, !layout.newNumbers.isEmpty {
            // A deleted row has no line on the right: use the nearest right line above it.
            let row = min(caretLine(of: unifiedTextView), layout.newNumbers.count - 1)
            let number = layout.newNumbers[...row].compactMap { $0 }.last ?? 1
            line = number - 1
        } else if activeTextView === leftTextView {
            line = Int(session.mapLine(Double(caretLine(of: leftTextView)), fromRight: false))
        } else {
            line = caretLine(of: rightTextView)
        }
        session.save()
        onJumpToSource?(path, max(0, line))
    }

    /// The chevron: the left side's lines replace the chunk's right lines (revert the change in
    /// the working tree), or with `append` go in after them. One undo step.
    func applyLeftToRight(chunk index: Int, append: Bool) {
        guard let session, session.isRightEditable, !session.isStale, session.chunks.indices.contains(index) else { return }
        let chunk = session.chunks[index]
        let leftText = (session.left.string as NSString).substring(with: session.left.range(ofLines: chunk.left))
        let target = session.right.range(ofLines: chunk.right)
        var replacement = leftText
        // Lines going in after a last line that has no line break need one in front of them.
        let rightEndsWithBreak = session.right.string.utf16.last.map { $0 == 10 || $0 == 13 } ?? true
        if target.length == 0, target.location == session.right.utf16Length, !rightEndsWithBreak, !leftText.isEmpty {
            replacement = "\n" + leftText
        }
        if append {
            rightTextView.replace(NSRange(location: NSMaxRange(target), length: 0), withText: replacement)
        } else {
            rightTextView.replace(target, withText: replacement)
        }
        session.rightTextDidChange()
    }

    // MARK: - Keys

    private func handleKeyDown(_ event: NSEvent, in textView: TextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }
        switch (Int(key), flags) {
        case (NSF7FunctionKey, []):
            goToChange(forward: true)
            return true
        case (NSF7FunctionKey, [.shift]):
            goToChange(forward: false)
            return true
        case (NSF4FunctionKey, []):
            jumpToSource()
            return true
        default:
            return false
        }
    }

    fileprivate func textDidChange(_ textView: TextView) {
        guard !isLoadingTexts, textView === rightTextView else { return }
        session?.rightTextDidChange()
    }

    fileprivate func selectionDidChange(_ textView: TextView) {
        guard let session, !isLoadingTexts, session.settings.layout == .sideBySide,
              textView === leftTextView || textView === rightTextView else { return }
        let index = session.chunkIndex(containing: caretLine(of: textView), onRight: textView === rightTextView)
        if index != session.currentChunkIndex, index != nil {
            session.currentChunkIndex = index
            toolbarModel.refresh()
        }
    }

    private final class DelegateProxy: TextViewDelegate {
        weak var owner: IDEDiffViewerView?

        func textViewDidChange(_ textView: TextView) {
            MainActor.assumeIsolated { owner?.textDidChange(textView) }
        }

        func textViewDidChangeSelection(_ textView: TextView) {
            MainActor.assumeIsolated { owner?.selectionDidChange(textView) }
        }
    }
}
