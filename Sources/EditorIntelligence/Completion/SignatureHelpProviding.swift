import Foundation

/// Produces parameter info (the signatures of the call around the caret), shown after `(` or `,`
/// and after accepting a method completion. ``LSPSignatureHelpProvider`` is the LSP-backed one.
public protocol SignatureHelpProviding: Sendable {
    func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel?
}
