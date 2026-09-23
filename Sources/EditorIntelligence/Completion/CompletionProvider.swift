import Foundation

/// One snapshot from a completion provider. Later snapshots replace earlier ones; `isFinished`
/// means this provider will not yield again.
public struct CompletionUpdate: Sendable {
    public var items: [CompletionItem]
    public var isFinished: Bool
    public var advertisement: String?
    public var emptyText: String?

    public init(items: [CompletionItem], isFinished: Bool, advertisement: String? = nil, emptyText: String? = nil) {
        self.items = items
        self.isFinished = isFinished
        self.advertisement = advertisement
        self.emptyText = emptyText
    }
}

/// A provider that produces completion suggestions for a given context.
public protocol CompletionProvider: Sendable {
    /// Human-readable provider name, used for tracing and ranking weights.
    var name: String { get }

    /// Produce completion items for the given context.
    func provide(context: CompletionContext) async -> [CompletionItem]

    /// Incremental results. The default yields ``provide(context:)`` once, already finished.
    /// A language provider can yield a fast batch first and a slower one after it.
    func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate>

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

    func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                let items = await provide(context: context)
                if !Task.isCancelled {
                    continuation.yield(CompletionUpdate(items: items, isFinished: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
