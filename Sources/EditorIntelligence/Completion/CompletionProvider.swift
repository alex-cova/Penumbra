import Foundation

/// A provider that produces completion suggestions for a given context.
public protocol CompletionProvider: Sendable {
    /// Human-readable provider name, used for tracing and ranking weights.
    var name: String { get }

    /// Produce completion items for the given context.
    func provide(context: CompletionContext) async -> [CompletionItem]

    /// Whether this provider is the semantic authority for the context's document (a language
    /// provider for its own language, an LSP client for its documents). When any provider claims
    /// a document, ``CompletionEngine`` treats the others as fallbacks: their items are only
    /// shown when the primary providers return nothing, and never after a member-access `.`.
    func isPrimary(for context: CompletionContext) -> Bool
}

public extension CompletionProvider {
    func isPrimary(for context: CompletionContext) -> Bool {
        false
    }
}
