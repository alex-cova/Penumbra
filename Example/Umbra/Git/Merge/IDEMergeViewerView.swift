import AppKit
import Penumbra
import SwiftUI

/// The three-way merge tab's content: the left side, the editable result and the right side, with a
/// ribbon divider between each pair and a toolbar. It lives inside the diff viewer, which the pane
/// host already lays over the editor, so a merge tab is shown and hidden like a diff tab.
@MainActor
final class IDEMergeViewerView: NSView {
    private(set) var session: IDEMergeSession?
    let leftTextView = TextView()
    let resultTextView = TextView()
    let rightTextView = TextView()
    private let leftDivider = IDEMergeDividerView(side: .left)
    private let rightDivider = IDEMergeDividerView(side: .right)
    private let toolbarModel = IDEMergeToolbarModel()
    private lazy var toolbarHost = NSHostingView(rootView: IDEMergeToolbar(model: toolbarModel))
    private let leftTitle = NSTextField(labelWithString: "")
    private let resultTitle = NSTextField(labelWithString: "Result")
    private let rightTitle = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private let delegateProxy = DelegateProxy()
    private var isSyncingScroll = false
    private var isLoadingTexts = false
    private var preferences: IDEPreferences?

    static let toolbarHeight: CGFloat = 30
    static let titleHeight: CGFloat = 22
    static let dividerWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        for label in [leftTitle, resultTitle, rightTitle, placeholder] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = IDEAppearance.NSToken.muted
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        placeholder.alignment = .center
        addSubview(toolbarHost)
        for textView in [leftTextView, resultTextView, rightTextView] {
            textView.backgroundColor = IDEAppearance.NSToken.editor
            textView.theme = IDEEditorTheme.shared.current
            textView.editorDelegate = delegateProxy
            addSubview(textView)
            textView.addScrollObserver { [weak self, weak textView] in self?.textViewDidScroll(textView) }
            textView.addKeyDownInterceptor { [weak self] event in self?.handleKeyDown(event) ?? false }
        }
        addSubview(leftDivider)
        addSubview(rightDivider)
        leftDivider.viewer = self
        rightDivider.viewer = self
        delegateProxy.owner = self
        toolbarModel.viewer = self
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Showing

    func show(_ session: IDEMergeSession, preferences: IDEPreferences) {
        self.preferences = preferences
        isHidden = false
        guard session !== self.session else {
            applyPreferences()
            return
        }
        self.session?.onTextsLoaded = nil
        self.session?.onChunksChanged = nil
        self.session?.currentResultText = nil
        self.session = session
        toolbarModel.session = session
        session.onTextsLoaded = { [weak self] in self?.loadTexts() }
        session.onChunksChanged = { [weak self] in self?.applyChunks() }
        session.currentResultText = { [weak self] in self?.resultTextView.text ?? "" }
        applyPreferences()
        loadTexts()
        if session.state == .loading { session.load() } else { applyChunks() }
    }

    func hide() {
        isHidden = true
    }

    func detach(_ closing: IDEMergeSession) {
        guard closing === session else { return }
        closing.onTextsLoaded = nil
        closing.onChunksChanged = nil
        closing.currentResultText = nil
        session = nil
        toolbarModel.session = nil
        for textView in [leftTextView, resultTextView, rightTextView] {
            textView.setState(TextViewState(text: ""))
        }
        isHidden = true
    }

    func focus() {
        window?.makeFirstResponder(resultTextView)
    }

    private func applyPreferences() {
        guard let preferences else { return }
        for textView in [leftTextView, resultTextView, rightTextView] {
            preferences.apply(to: textView)
            textView.showMinimap = false
            textView.isTypewriterScrollingEnabled = false
            textView.isDistractionFreeModeEnabled = false
            textView.isFocusModeEnabled = false
            textView.showMethodSeparators = false
            textView.backgroundColor = IDEAppearance.NSToken.editor
        }
        leftTextView.isEditable = false
        rightTextView.isEditable = false
        resultTextView.isEditable = true
    }

    // MARK: - Content

    private var language: TreeSitterLanguage? {
        let url = URL(fileURLWithPath: session?.request.path ?? "")
        return IDELanguageSupport.language(forIdentifier: LanguageIdentifier.identifier(for: url), fileURL: url)
    }

    private func state(for text: String) -> TextViewState {
        let theme = IDEEditorTheme.shared.current
        let multiplier = preferences.map { CGFloat($0.lineHeightMultiplier) } ?? TextView.defaultLineHeightMultiplier
        if let language {
            return TextViewState(text: text, theme: theme, lineHeightMultiplier: multiplier, language: language)
        }
        return TextViewState(text: text, theme: theme, lineHeightMultiplier: multiplier)
    }

    private func loadTexts() {
        guard let session else { return }
        isLoadingTexts = true
        defer { isLoadingTexts = false }
        leftTitle.stringValue = session.request.leftTitle
        rightTitle.stringValue = session.request.rightTitle
        let ready = session.state == .ready
        for view in [leftTextView, resultTextView, rightTextView, leftDivider, rightDivider] as [NSView] {
            view.isHidden = !ready
        }
        switch session.state {
        case .ready:
            placeholder.isHidden = true
            leftTextView.setState(state(for: session.left.string))
            resultTextView.setState(state(for: session.result.string))
            rightTextView.setState(state(for: session.right.string))
            for textView in [leftTextView, resultTextView, rightTextView] {
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            applyPreferences()
        case .loading:
            placeholder.stringValue = "Loading…"
            placeholder.isHidden = false
        case .binary:
            placeholder.stringValue = "Binary files are not merged here: use Accept Yours or Accept Theirs."
            placeholder.isHidden = false
        case .failed(let message):
            placeholder.stringValue = message
            placeholder.isHidden = false
        }
        toolbarModel.refresh()
        needsLayout = true
    }

    private func applyChunks() {
        guard let session, session.state == .ready else { return }
        func band(_ conflicting: Bool, _ range: Range<Int>) -> LineBackground {
            LineBackground(
                line: range.lowerBound + 1, lineCount: range.count,
                color: conflicting ? NSColor.systemRed.withAlphaComponent(0.16).cgColor
                    : NSColor.systemBlue.withAlphaComponent(0.13).cgColor)
        }
        leftTextView.lineBackgrounds = session.leftChunks.indices.map { index in
            band(session.isConflicting(leftChunkAt: index), session.leftChunks[index].left)
        }
        rightTextView.lineBackgrounds = session.rightChunks.indices.map { index in
            band(session.isConflicting(rightChunkAt: index), session.rightChunks[index].right)
        }
        var resultBands: [LineBackground] = []
        for index in session.leftChunks.indices {
            resultBands.append(band(session.isConflicting(leftChunkAt: index), session.leftChunks[index].right))
        }
        for index in session.rightChunks.indices where !session.isConflicting(rightChunkAt: index) {
            resultBands.append(band(false, session.rightChunks[index].left))
        }
        resultTextView.lineBackgrounds = resultBands.filter { $0.lineCount > 0 }
        leftDivider.needsDisplay = true
        rightDivider.needsDisplay = true
        toolbarModel.refresh()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let titleY = Self.toolbarHeight
        let contentY = titleY + Self.titleHeight
        let contentHeight = max(0, bounds.height - contentY)
        toolbarHost.frame = CGRect(x: 0, y: 0, width: width, height: Self.toolbarHeight)
        placeholder.frame = CGRect(x: 16, y: contentY + 40, width: max(0, width - 32), height: 40)
        let pane = max(0, (width - 2 * Self.dividerWidth) / 3).rounded(.down)
        let leftX: CGFloat = 0
        let leftDividerX = pane
        let resultX = pane + Self.dividerWidth
        let rightDividerX = resultX + pane
        let rightX = rightDividerX + Self.dividerWidth
        leftTextView.frame = CGRect(x: leftX, y: contentY, width: pane, height: contentHeight)
        leftDivider.frame = CGRect(x: leftDividerX, y: contentY, width: Self.dividerWidth, height: contentHeight)
        resultTextView.frame = CGRect(x: resultX, y: contentY, width: pane, height: contentHeight)
        rightDivider.frame = CGRect(x: rightDividerX, y: contentY, width: Self.dividerWidth, height: contentHeight)
        rightTextView.frame = CGRect(x: rightX, y: contentY, width: max(0, width - rightX), height: contentHeight)
        leftTitle.frame = CGRect(x: 10, y: titleY + 3, width: max(0, pane - 20), height: 16)
        resultTitle.frame = CGRect(x: resultX + 10, y: titleY + 3, width: max(0, pane - 20), height: 16)
        rightTitle.frame = CGRect(x: rightX + 10, y: titleY + 3, width: max(0, width - rightX - 20), height: 16)
        leftDivider.needsDisplay = true
        rightDivider.needsDisplay = true
    }

    // MARK: - Scrolling

    private func textViewDidScroll(_ source: TextView?) {
        leftDivider.needsDisplay = true
        rightDivider.needsDisplay = true
        guard let session, let source, !isSyncingScroll, session.state == .ready else { return }
        // The line in the middle of the scrolled pane, as a position in the result.
        let middle = source.contentOffset.y + source.bounds.height / 2
        let line = source.line(atYPosition: middle)
        let top = source.yPosition(ofLine: line)
        let height = max(source.yPosition(ofLine: line + 1) - top, 1)
        let fractional = Double(line - 1) + Double((middle - top) / height)
        let resultLine: Double
        switch source {
        case leftTextView: resultLine = Self.map(fractional, through: session.leftChunks.map { ($0.left, $0.right) })
        case rightTextView: resultLine = Self.map(fractional, through: session.rightChunks.map { ($0.right, $0.left) })
        default: resultLine = fractional
        }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        if source !== resultTextView { scroll(resultTextView, toMiddleLine: resultLine) }
        if source !== leftTextView {
            scroll(leftTextView, toMiddleLine: Self.map(resultLine, through: session.leftChunks.map { ($0.right, $0.left) }))
        }
        if source !== rightTextView {
            scroll(rightTextView, toMiddleLine: Self.map(resultLine, through: session.rightChunks.map { ($0.left, $0.right) }))
        }
    }

    /// Maps a (fractional, 0-based) line of one text to the matching line of another, through the
    /// chunks as (range in the source, range in the target) pairs: lines between chunks move 1:1,
    /// lines inside one are stretched over the target's range.
    static func map(_ line: Double, through chunks: [(Range<Int>, Range<Int>)]) -> Double {
        var delta = 0.0
        for (source, target) in chunks {
            if line < Double(source.lowerBound) { return max(0, line + delta) }
            if line < Double(source.upperBound) {
                let fraction = (line - Double(source.lowerBound)) / Double(max(source.count, 1))
                return Double(target.lowerBound) + fraction * Double(target.count)
            }
            delta = Double(target.upperBound) - Double(source.upperBound)
        }
        return max(0, line + delta)
    }

    private func scroll(_ target: TextView, toMiddleLine mapped: Double) {
        let floorLine = Int(mapped.rounded(.down))
        let targetLine = floorLine + 1
        let targetTop = target.yPosition(ofLine: targetLine)
        let targetHeight = max(target.yPosition(ofLine: targetLine + 1) - targetTop, 1)
        let middle = targetTop + CGFloat(mapped - Double(floorLine)) * targetHeight
        let maxOffset = max(0, target.contentSize.height - target.bounds.height)
        let offset = min(max(0, middle - target.bounds.height / 2), maxOffset)
        guard abs(target.contentOffset.y - offset) > 0.5 else { return }
        target.contentOffset = CGPoint(x: target.contentOffset.x, y: offset)
    }

    /// Divider-space y of a 1-based line in one of the three panes.
    func dividerY(ofLine line: Int, in pane: IDEMergeDividerView.Pane) -> CGFloat {
        let textView: TextView
        switch pane {
        case .left: textView = leftTextView
        case .result: textView = resultTextView
        case .right: textView = rightTextView
        }
        return textView.yPosition(ofLine: line) - textView.contentOffset.y
    }

    // MARK: - Actions

    /// The chevron of a left-vs-result chunk: the left lines replace the result's (⌥ appends).
    func acceptLeft(chunk index: Int, append: Bool) {
        guard let replacement = session?.replacement(forLeftChunkAt: index) else { return }
        replaceResult(replacement.range, with: replacement.text, append: append)
    }

    func acceptRight(chunk index: Int, append: Bool) {
        guard let replacement = session?.replacement(forRightChunkAt: index) else { return }
        replaceResult(replacement.range, with: replacement.text, append: append)
    }

    private func replaceResult(_ range: NSRange, with text: String, append: Bool) {
        var replacement = text
        let resultText = resultTextView.text
        let endsWithBreak = resultText.utf16.last.map { $0 == 10 || $0 == 13 } ?? true
        if range.length == 0, range.location == (resultText as NSString).length, !endsWithBreak, !text.isEmpty {
            replacement = "\n" + text
        }
        if append {
            resultTextView.replace(NSRange(location: NSMaxRange(range), length: 0), withText: replacement)
        } else {
            resultTextView.replace(range, withText: replacement)
        }
        session?.resultTextDidChange()
    }

    /// Takes every change of `side` that does not conflict with the other side, bottom first so the
    /// lines of the earlier ones stay where they are.
    func applyNonConflicting(from side: IDEMergeSide?) {
        guard let session, session.state == .ready else { return }
        var edits: [(range: NSRange, text: String, line: Int)] = []
        if side != .right {
            for index in session.leftChunks.indices where !session.isConflicting(leftChunkAt: index) {
                if let replacement = session.replacement(forLeftChunkAt: index) {
                    edits.append((replacement.range, replacement.text, session.leftChunks[index].right.lowerBound))
                }
            }
        }
        if side != .left {
            for index in session.rightChunks.indices where !session.isConflicting(rightChunkAt: index) {
                if let replacement = session.replacement(forRightChunkAt: index) {
                    edits.append((replacement.range, replacement.text, session.rightChunks[index].left.lowerBound))
                }
            }
        }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            resultTextView.replace(edit.range, withText: edit.text)
        }
        session.resultTextDidChange()
    }

    /// Replaces the whole result with one side.
    func acceptWhole(_ side: IDEMergeSide) {
        guard let session, session.state == .ready else { return }
        let text = side == .left ? session.left.string : session.right.string
        resultTextView.replace(NSRange(location: 0, length: (resultTextView.text as NSString).length), withText: text)
        session.resultTextDidChange()
    }

    func goToChange(forward: Bool) {
        guard let session else { return }
        let starts = session.changeStartLines
        guard !starts.isEmpty else { return }
        let line = resultTextView.textLocation(at: resultTextView.selectedRange.location)?.lineNumber ?? 0
        let target = forward ? starts.first { $0 > line } ?? starts[0] : starts.last { $0 < line } ?? starts[starts.count - 1]
        if let location = resultTextView.location(at: TextLocation(lineNumber: target, column: 0)) {
            resultTextView.selectedRange = NSRange(location: location, length: 0)
            resultTextView.scrollRangeToCenter(NSRange(location: location, length: 0))
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
              Int(key) == NSF7FunctionKey else { return false }
        if flags.isEmpty { goToChange(forward: true); return true }
        if flags == [.shift] { goToChange(forward: false); return true }
        return false
    }

    fileprivate func textDidChange(_ textView: TextView) {
        guard !isLoadingTexts, textView === resultTextView else { return }
        session?.resultTextDidChange()
    }

    private final class DelegateProxy: TextViewDelegate {
        weak var owner: IDEMergeViewerView?

        func textViewDidChange(_ textView: TextView) {
            MainActor.assumeIsolated { owner?.textDidChange(textView) }
        }
    }
}

// MARK: - Divider

/// The strip between two panes: a ribbon per change, and the chevron that moves it into the result.
@MainActor
final class IDEMergeDividerView: NSView {
    enum Pane { case left, result, right }

    /// `.left` joins the left pane to the result, `.right` the result to the right pane.
    enum Side { case left, right }

    weak var viewer: IDEMergeViewerView?
    private let side: Side
    private struct Button {
        let rect: CGRect
        let chunk: Int
    }
    private var buttons: [Button] = []
    private static let buttonSize: CGFloat = 14

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        IDEAppearance.NSToken.editor.setFill()
        bounds.fill()
        buttons = []
        removeAllToolTips()
        guard let viewer, let session = viewer.session, session.state == .ready else { return }
        let width = bounds.width
        let chunks = side == .left ? session.leftChunks : session.rightChunks
        for (index, chunk) in chunks.enumerated() {
            // Source pane lines on this divider's far side, the result's on the near side.
            let farRange = side == .left ? chunk.left : chunk.right
            let nearRange = side == .left ? chunk.right : chunk.left
            let farPane: Pane = side == .left ? .left : .right
            let farTop = viewer.dividerY(ofLine: farRange.lowerBound + 1, in: farPane)
            let farBottom = viewer.dividerY(ofLine: farRange.upperBound + 1, in: farPane)
            let nearTop = viewer.dividerY(ofLine: nearRange.lowerBound + 1, in: .result)
            let nearBottom = viewer.dividerY(ofLine: nearRange.upperBound + 1, in: .result)
            if max(farBottom, nearBottom) < -Self.buttonSize { continue }
            if min(farTop, nearTop) > bounds.height + Self.buttonSize { break }
            let conflicting = side == .left ? session.isConflicting(leftChunkAt: index) : session.isConflicting(rightChunkAt: index)
            let color: NSColor = conflicting ? .systemRed : .systemBlue
            // Left divider: far side is x = 0; right divider: far side is x = width.
            let farX: CGFloat = side == .left ? 0 : width
            let nearX: CGFloat = side == .left ? width : 0
            let ribbon = NSBezierPath()
            ribbon.move(to: CGPoint(x: farX, y: farTop))
            ribbon.curve(to: CGPoint(x: nearX, y: nearTop),
                         controlPoint1: CGPoint(x: width / 2, y: farTop),
                         controlPoint2: CGPoint(x: width / 2, y: nearTop))
            ribbon.line(to: CGPoint(x: nearX, y: nearBottom))
            ribbon.curve(to: CGPoint(x: farX, y: farBottom),
                         controlPoint1: CGPoint(x: width / 2, y: nearBottom),
                         controlPoint2: CGPoint(x: width / 2, y: farBottom))
            ribbon.close()
            color.withAlphaComponent(0.16).setFill()
            ribbon.fill()
            color.withAlphaComponent(0.55).setStroke()
            ribbon.lineWidth = 1
            ribbon.stroke()

            let rect = CGRect(
                x: side == .left ? 2 : width - Self.buttonSize - 2,
                y: max(0, farTop) + 1, width: Self.buttonSize, height: Self.buttonSize)
            drawSymbol(side == .left ? "chevron.right.2" : "chevron.left.2", in: rect, color: color)
            buttons.append(Button(rect: rect, chunk: index))
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    private func drawSymbol(_ name: String, in rect: CGRect, color: NSColor) {
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
        let append = event.modifierFlags.contains(.option)
        switch side {
        case .left: viewer?.acceptLeft(chunk: button.chunk, append: append)
        case .right: viewer?.acceptRight(chunk: button.chunk, append: append)
        }
    }

    override func resetCursorRects() {
        for button in buttons { addCursorRect(button.rect, cursor: .pointingHand) }
    }
}

extension IDEMergeDividerView: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Use this side's lines in the result (⌥-click to add them after)"
    }
}

// MARK: - Toolbar

@MainActor
@Observable
final class IDEMergeToolbarModel {
    @ObservationIgnored weak var viewer: IDEMergeViewerView?
    @ObservationIgnored var session: IDEMergeSession? {
        didSet { refresh() }
    }

    private(set) var unresolved = 0
    private(set) var isReady = false
    private(set) var isApplying = false
    private(set) var error: String?

    func refresh() {
        unresolved = session?.unresolvedCount ?? 0
        isReady = session?.state == .ready
        isApplying = session?.isApplying ?? false
        error = session?.applyError
    }
}

struct IDEMergeToolbar: View {
    let model: IDEMergeToolbarModel

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button { model.viewer?.goToChange(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Change (⇧F7)")
            Button { model.viewer?.goToChange(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next Change (F7)")
            Menu {
                Button("Apply Non-Conflicting Changes from Left") { model.viewer?.applyNonConflicting(from: .left) }
                Button("Apply Non-Conflicting Changes from Right") { model.viewer?.applyNonConflicting(from: .right) }
                Button("Apply All Non-Conflicting Changes") { model.viewer?.applyNonConflicting(from: nil) }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Apply Non-Conflicting Changes")
            Divider().frame(height: 14)
            Button("Accept Left") { model.viewer?.acceptWhole(.left) }
                .help("Replace the result with the left side")
            Button("Accept Right") { model.viewer?.acceptWhole(.right) }
                .help("Replace the result with the right side")
            Spacer(minLength: 0)
            if let error = model.error {
                Text(error).foregroundStyle(IDEAppearance.ColorToken.error).lineLimit(1)
            }
            Text(model.unresolved == 0 ? "No conflicts left" : "\(model.unresolved) conflict\(model.unresolved == 1 ? "" : "s") left")
                .foregroundStyle(model.unresolved == 0 ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.gitConflict)
            Button("Apply") { model.session?.apply() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.isReady || model.isApplying)
                .help("Save the result and mark the file resolved (⌘↩)")
        }
        .buttonStyle(.borderless)
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEMergeViewerView.toolbarHeight)
        .background(IDEAppearance.ColorToken.tabBar)
    }
}
