import AppKit
import Penumbra

/// Base64 conversion of editor text, kept free of AppKit so it can be tested on its own.
enum IDEBase64Text {
    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decodes Base64 text leniently: whitespace and line breaks are ignored, the URL-safe alphabet
    /// is accepted and missing padding is added. Returns `nil` when the text is not Base64 or the
    /// bytes are not UTF-8, so binary never lands in the buffer.
    static func decode(_ text: String) -> String? {
        var cleaned = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !cleaned.isEmpty else { return nil }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension IDEWorkspace {
    /// The Tools submenu of the editor's right-click menu; only offered while text is selected.
    func textToolsContextMenuItems(context: EditorContextMenuContext, textView: TextView) -> [NSMenuItem] {
        let hasSelection = textView.selectedRanges.contains { $0.length > 0 } || (context.selectedRange?.length ?? 0) > 0
        guard hasSelection else { return [] }
        let submenu = NSMenu(title: "Tools")
        submenu.autoenablesItems = false
        let encode = IDEClosureMenuItem(title: "Encode Base64") { [weak textView] in
            guard let textView else { return }
            Self.transformSelections(in: textView) { IDEBase64Text.encode($0) }
        }
        let decode = IDEClosureMenuItem(title: "Decode Base64") { [weak textView] in
            guard let textView else { return }
            Self.transformSelections(in: textView, IDEBase64Text.decode)
        }
        encode.isEnabled = textView.isEditable
        decode.isEnabled = textView.isEditable
        submenu.addItem(encode)
        submenu.addItem(decode)
        let item = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return [.separator(), item]
    }

    /// Replaces every non-empty selection with `transform` of its text, as one undo step, and
    /// selects the results. Beeps and changes nothing when any selection cannot be transformed.
    @MainActor
    static func transformSelections(in textView: TextView, _ transform: (String) -> String?) {
        let ranges = textView.selectedRanges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var replacements: [BatchReplaceSet.Replacement] = []
        var results: [String] = []
        for range in ranges {
            guard let text = textView.text(in: range), let result = transform(text) else {
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
}
