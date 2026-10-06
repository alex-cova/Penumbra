import AppKit
import Penumbra

extension IDEWorkspace {
    /// The Tools submenu of the editor's right-click menu, built from `IDETextTransforms`; only
    /// offered while text is selected.
    func textToolsContextMenuItems(context: EditorContextMenuContext, textView: TextView) -> [NSMenuItem] {
        let hasSelection = textView.selectedRanges.contains { $0.length > 0 } || (context.selectedRange?.length ?? 0) > 0
        guard hasSelection else { return [] }
        let submenu = NSMenu(title: "Tools")
        submenu.autoenablesItems = false
        for (index, group) in IDETextTransform.Group.allCases.enumerated() {
            let transforms = IDETextTransforms.all.filter { $0.group == group }
            guard !transforms.isEmpty else { continue }
            if index > 0, !submenu.items.isEmpty { submenu.addItem(.separator()) }
            for transform in transforms {
                let item = IDEClosureMenuItem(title: transform.title) { [weak textView] in
                    guard let textView else { return }
                    Self.applyTextTransform(transform, in: textView, wholeDocumentWithoutSelection: false)
                }
                item.isEnabled = textView.isEditable
                submenu.addItem(item)
            }
        }
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return [.separator(), item]
    }

    /// One palette command per transform. Without a selection they convert the whole document.
    func textToolsPaletteCommands() -> [EditorCommand] {
        IDETextTransforms.all.map { transform in
            EditorCommand(id: "tools.\(transform.id)", title: transform.title, group: "Tools") { [weak self] in
                self?.applyTextTransformToActiveEditor(transform)
            }
        }
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
}
