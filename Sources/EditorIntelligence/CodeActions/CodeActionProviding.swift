import Foundation

/// Offers quick fixes and refactorings at a cursor position. ``LSPCodeActionProvider`` is one
/// implementation; a language can provide a native one.
public protocol CodeActionProviding: Sendable {
    /// The actions available at `position`. `diagnostics` are the document's current problems,
    /// so a provider can offer fixes for the ones under the caret.
    func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction]
}

public extension CodeAction {
    /// The `kind` of the action that removes unused imports and sorts the rest.
    static let organizeImportsKind = "source.organizeImports"
}
