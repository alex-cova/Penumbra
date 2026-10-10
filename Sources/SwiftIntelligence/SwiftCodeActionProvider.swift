import EditorIntelligence
import Foundation

/// The native Swift organize-imports action. SourceKit-LSP does not provide one.
public struct SwiftCodeActionProvider: CodeActionProviding {
    public init() {}

    public func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return [] }
        let edits = SwiftImportOrganizer.edits(in: document.text)
        guard !edits.isEmpty else { return [] }
        return [CodeAction(title: "Organize Imports", kind: CodeAction.organizeImportsKind, edits: edits)]
    }
}
