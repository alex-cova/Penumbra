import Foundation

/// Which bulb to draw on the caret line. A quick fix wins over an intention.
public enum CodeActionBulb: Sendable, Equatable {
    case none
    case intention
    case quickFix
}

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

    /// Whether the caret line has a quick fix or an intention, for the bulb. The default is none,
    /// so a provider that only lists actions draws no bulb.
    func bulb(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> CodeActionBulb
}

public extension CodeActionProviding {
    func bulb(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> CodeActionBulb {
        .none
    }
}

public extension CodeAction {
    /// The `kind` of the action that removes unused imports and sorts the rest.
    static let organizeImportsKind = "source.organizeImports"
}
