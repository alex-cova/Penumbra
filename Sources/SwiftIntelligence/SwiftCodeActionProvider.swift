import EditorIntelligence
import Foundation

/// The native Swift code actions: the quick fixes of the inspections at the caret
/// (``SwiftInspectionService``) and organize imports, which SourceKit-LSP does not provide.
public struct SwiftCodeActionProvider: CodeActionProviding {
    private let inspections: SwiftInspectionService?

    public init(inspections: SwiftInspectionService? = nil) {
        self.inspections = inspections
    }

    public func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return [] }
        var actions = inspections?.codeActions(for: document, at: position) ?? []
        let edits = SwiftImportOrganizer.edits(in: document.text)
        if !edits.isEmpty {
            actions.append(CodeAction(title: "Organize Imports", kind: CodeAction.organizeImportsKind, edits: edits))
        }
        return actions
    }
}
