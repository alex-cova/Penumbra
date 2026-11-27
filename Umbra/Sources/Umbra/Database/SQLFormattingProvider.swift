import DatabaseKit
import EditorIntelligence
import Foundation

struct SQLFormattingProvider: FormattingProviding {
    let store: SQLSnapshotStore
    let indentUnit: @Sendable () async -> String

    func supportsFormatting(_ document: Document) -> Bool {
        document.languageIdentifier == "sql" && store.snapshot(for: document.id)?.dialect != nil
    }

    func formatDocument(_ document: Document) async -> [TextEdit] {
        await edits(in: document)
    }

    func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        await edits(in: document, selection: range)
    }

    private func edits(in document: Document, selection: EditorIntelligence.TextRange? = nil) async -> [TextEdit] {
        guard document.languageIdentifier == "sql", let dialect = store.snapshot(for: document.id)?.dialect,
              document.contentSnapshot.utf16Length <= SQLDiagnosticProvider.maximumLength else { return [] }
        let text = document.text
        let unit = await indentUnit()
        return await runDetached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [] }
            let lines = SQLDiagnosticProvider.lineStarts(text)
            return SQLFormatter.edits(in: text, dialect: dialect, indentUnit: unit).compactMap { edit in
                let start = edit.range.location
                let end = NSMaxRange(edit.range)
                if let selection, start < selection.start.utf16Offset || end > selection.end.utf16Offset { return nil }
                return TextEdit(
                    range: EditorIntelligence.TextRange(start: SQLDiagnosticProvider.position(start, lines),
                                                        end: SQLDiagnosticProvider.position(end, lines)),
                    replacement: edit.newText
                )
            }
        }
    }
}
