import EditorIntelligence
import Foundation

/// The last check before Replace in Files writes anything: an edit is only made when the text it
/// was planned against is still there. Files change between the search and the click on Apply (an
/// editor, a build, git), and a range that has drifted would otherwise overwrite something else.
enum IDEReplaceInFilesGuard {
    struct Outcome {
        /// The edit with every stale replacement removed.
        var edit: WorkspaceEdit
        /// How many replacements were dropped, per file.
        var staleCounts: [URL: Int]
    }

    /// - Parameters:
    ///   - plan: the plan the edit was chosen from; its entries remember the text they replace.
    ///   - texts: the current text of each file in `edit`, as the editor or disk has it now. A file
    ///     missing here counts as changed.
    static func verified(_ edit: WorkspaceEdit, against plan: WorkspaceEditPlan, texts: [URL: String]) -> Outcome {
        var expected: [String: String] = [:]
        for entry in plan.entries {
            expected[key(entry.url, entry.range)] = entry.oldText
        }
        var kept: [URL: [TextEdit]] = [:]
        var stale: [URL: Int] = [:]
        for (url, edits) in edit.changes {
            let text = texts[url].map { $0 as NSString }
            for textEdit in edits {
                if let text, let oldText = expected[key(url, textEdit.range)],
                   Self.current(in: text, at: textEdit.range) == oldText {
                    kept[url, default: []].append(textEdit)
                } else {
                    stale[url, default: 0] += 1
                }
            }
        }
        return Outcome(
            edit: WorkspaceEdit(changes: kept, fileRenames: edit.fileRenames, fileDeletions: edit.fileDeletions, warnings: edit.warnings),
            staleCounts: stale
        )
    }

    private static func key(_ url: URL, _ range: EditorIntelligence.TextRange) -> String {
        "\(url.standardizedFileURL.path):\(range.start.utf16Offset)-\(range.end.utf16Offset)"
    }

    private static func current(in text: NSString, at range: EditorIntelligence.TextRange) -> String? {
        let start = range.start.utf16Offset
        let end = range.end.utf16Offset
        guard start >= 0, end >= start, end <= text.length else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
