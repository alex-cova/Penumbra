import AppKit
import Penumbra

extension IDEWorkspace {
    /// The Tools submenu of the editor's right-click menu, built from `IDETextTransforms`, one
    /// submenu per group; only offered while text is selected.
    func textToolsContextMenuItems(context: EditorContextMenuContext, textView: TextView) -> [NSMenuItem] {
        let hasSelection = textView.selectedRanges.contains { $0.length > 0 } || (context.selectedRange?.length ?? 0) > 0
        guard hasSelection else { return [] }
        let tools = NSMenu(title: "Tools")
        tools.autoenablesItems = false
        for group in IDETextTransform.Group.allCases {
            let transforms = IDETextTransforms.all.filter { $0.group == group }
            guard !transforms.isEmpty else { continue }
            let submenu = NSMenu(title: group.title)
            submenu.autoenablesItems = false
            for transform in transforms {
                let item = IDEClosureMenuItem(title: transform.title) { [weak textView] in
                    guard let textView else { return }
                    Self.applyTextTransform(transform, in: textView, wholeDocumentWithoutSelection: false)
                }
                item.isEnabled = textView.isEditable
                submenu.addItem(item)
            }
            if group == .encoding {
                submenu.addItem(.separator())
                submenu.addItem(IDEClosureMenuItem(title: "Decode JWT…") { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.showJWTDecoding(in: textView, fallbackToClipboard: false)
                })
            }
            let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            tools.addItem(parent)
        }
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        item.submenu = tools
        return [.separator(), item]
    }

    /// One palette command per transform, plus the ones that need no selection. Transforms convert
    /// the whole document when nothing is selected.
    func textToolsPaletteCommands() -> [EditorCommand] {
        let transforms = IDETextTransforms.all.map { transform in
            EditorCommand(id: "tools.\(transform.id)", title: transform.title, group: "Tools") { [weak self] in
                self?.applyTextTransformToActiveEditor(transform)
            }
        }
        let insertions = IDETextInsertions.all.map { insertion in
            EditorCommand(id: "tools.\(insertion.id)", title: insertion.title, group: "Tools") { [weak self] in
                guard let self else { return }
                Self.applyTextInsertion(insertion, in: self.host(for: self.workbench.activePaneID).textView)
            }
        }
        let jwt = EditorCommand(id: "tools.jwt.decode", title: "Decode JWT", group: "Tools") { [weak self] in
            guard let self else { return }
            self.showJWTDecoding(in: self.host(for: self.workbench.activePaneID).textView, fallbackToClipboard: true)
        }
        return transforms + insertions + [jwt]
    }

    func applyTextTransformToActiveEditor(_ transform: IDETextTransform) {
        let textView = host(for: workbench.activePaneID).textView
        Self.applyTextTransform(transform, in: textView, wholeDocumentWithoutSelection: true)
    }

    /// Replaces every non-empty selection (the whole document when there is none and
    /// `wholeDocumentWithoutSelection`) with the transform of its text, as one undo step, and
    /// selects the results. Beeps and changes nothing when any selection cannot be transformed.
    @MainActor
    static func applyTextTransform(_ transform: IDETextTransform, in textView: TextView, wholeDocumentWithoutSelection: Bool) {
        guard textView.isEditable else { return }
        var ranges = textView.selectedRanges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        if ranges.isEmpty, wholeDocumentWithoutSelection, textView.documentLength > 0 {
            ranges = [NSRange(location: 0, length: textView.documentLength)]
        }
        var replacements: [BatchReplaceSet.Replacement] = []
        var results: [String] = []
        for range in ranges {
            guard let text = textView.text(in: range),
                  let result = transform.apply(text, transformContext(for: range, in: textView)) else {
                NSSound.beep()
                return
            }
            replacements.append(.init(range: range, text: result))
            results.append(result)
        }
        guard !replacements.isEmpty else { return }
        textView.replaceText(in: BatchReplaceSet(replacements: replacements))
        var delta = 0
        var newRanges: [NSRange] = []
        for (range, result) in zip(ranges, results) {
            let length = (result as NSString).length
            newRanges.append(NSRange(location: range.location + delta, length: length))
            delta += length - range.length
        }
        textView.selectedRanges = newRanges
    }

    @MainActor
    private static func transformContext(for range: NSRange, in textView: TextView) -> IDETextTransformContext {
        var context = IDETextTransformContext()
        switch textView.indentStrategy {
        case .tab: context.indentUnit = "\t"
        case .space(let length): context.indentUnit = String(repeating: " ", count: max(length, 1))
        }
        if let position = textView.textLocation(at: range.location),
           let lineStart = textView.location(at: TextLocation(lineNumber: position.lineNumber, column: 0)),
           lineStart < range.location,
           let prefix = textView.text(in: NSRange(location: lineStart, length: range.location - lineStart)) {
            context.baseIndent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        }
        return context
    }

    /// Puts a fresh value at every caret, over every selection, as one undo step.
    @MainActor
    static func applyTextInsertion(_ insertion: IDETextInsertion, in textView: TextView) {
        guard textView.isEditable else { return }
        let ranges = textView.selectedRanges.sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return }
        let values = ranges.map { _ in insertion.make() }
        textView.replaceText(in: BatchReplaceSet(replacements: zip(ranges, values).map { .init(range: $0, text: $1) }))
        var delta = 0
        var carets: [NSRange] = []
        for (range, value) in zip(ranges, values) {
            let length = (value as NSString).length
            carets.append(NSRange(location: range.location + delta + length, length: 0))
            delta += length - range.length
        }
        textView.selectedRanges = carets
    }

    // MARK: - JWT

    /// Decodes the selected JWT (or, from the palette with no selection, the one on the clipboard)
    /// into the read-only sheet. Nothing in the document changes.
    func showJWTDecoding(in textView: TextView, fallbackToClipboard: Bool) {
        let selection = textView.selectedRanges.first { $0.length > 0 }
        var source = selection.flatMap { textView.text(in: $0) }
        if source == nil, fallbackToClipboard { source = NSPasteboard.general.string(forType: .string) }
        guard let source, var decoding = IDEJWTText.decode(source) else {
            NSSound.beep()
            return
        }
        decoding.anchorOffset = selection?.upperBound
        jwtDecoding = decoding
    }

    /// "Insert as Comment" in the JWT sheet: the decoded header and payload go on the lines after the
    /// token's line, commented with the file's own comment syntax when it has one.
    func insertJWTAsComment(_ decoding: IDEJWTDecoding) {
        jwtDecoding = nil
        let textView = host(for: workbench.activePaneID).textView
        guard textView.isEditable else { return }
        let anchor = min(decoding.anchorOffset ?? textView.selectedRange.upperBound, textView.documentLength)
        let block = "JWT header\n\(decoding.header)\nJWT payload\n\(decoding.payload)"
        let nextLine = textView.textLocation(at: anchor).flatMap {
            textView.location(at: TextLocation(lineNumber: $0.lineNumber + 1, column: 0))
        }
        let inserted: NSRange
        if let nextLine {
            textView.replace(NSRange(location: nextLine, length: 0), withText: block + "\n")
            inserted = NSRange(location: nextLine, length: (block as NSString).length)
        } else {
            let end = textView.documentLength
            textView.replace(NSRange(location: end, length: 0), withText: "\n" + block)
            inserted = NSRange(location: end + 1, length: (block as NSString).length)
        }
        textView.selectedRange = inserted
        textView.toggleComment()
        focusActiveEditor()
    }
}
