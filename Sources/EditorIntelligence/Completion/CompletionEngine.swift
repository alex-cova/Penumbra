import Foundation

/// Asynchronous completion engine that orchestrates providers, merges results, ranks them, and
/// filters out low-scoring suggestions.
///
/// Calls to `complete(context:)` are debounced and cancel any in-flight request. Providers are run
/// concurrently in a task group. The returned items are deduplicated, ranked, and filtered.
public actor CompletionEngine {
    public let providers: [CompletionProvider]
    public nonisolated let ranker: Ranker
    public let debounceInterval: TimeInterval
    private var currentTask: Task<[CompletionItem], Error>?

    public init(
        providers: [CompletionProvider],
        ranker: Ranker = DefaultRanker(),
        debounceInterval: TimeInterval = 0.05
    ) {
        self.providers = providers
        self.ranker = ranker
        self.debounceInterval = debounceInterval
    }

    /// Request completions for the given context.
    ///
    /// This method debounces rapid calls and cancels any previous in-flight request. It throws
    /// `CancellationError` if the request is cancelled before completion.
    public func complete(context: CompletionContext) async throws -> [CompletionItem] {
        currentTask?.cancel()
        let task = Task { [providers, ranker, debounceInterval] in
            try await Task.sleep(for: .seconds(debounceInterval))
            try Task.checkCancellation()
            return try await performComplete(context: context, providers: providers, ranker: ranker)
        }
        currentTask = task
        return try await task.value
    }

    /// Remember that the user accepted `item`, so it ranks higher next time.
    public nonisolated func recordAcceptance(of item: CompletionItem) {
        (ranker as? DefaultRanker)?.recency.record(item)
    }

    /// Cancel any in-flight completion request.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}

private func performComplete(
    context: CompletionContext,
    providers: [CompletionProvider],
    ranker: Ranker
) async throws -> [CompletionItem] {
    let primaryNames = Set(providers.filter { $0.isPrimary(for: context) }.map(\.name))
    var items: [CompletionItem] = []
    try await withThrowingTaskGroup(of: [CompletionItem].self) { group in
        for provider in providers {
            group.addTask {
                try Task.checkCancellation()
                return await provider.provide(context: context)
            }
        }
        for try await providerItems in group {
            items.append(contentsOf: providerItems)
        }
    }

    if !primaryNames.isEmpty {
        let primaryItems = items.filter { primaryNames.contains($0.source) }
        if !primaryItems.isEmpty || context.isMemberAccess {
            items = primaryItems
        }
    }

    // Merge duplicates across providers, keeping the first (overloads differ in `labelDetail`
    // and so survive), in provider order.
    var seen = Set<String>()
    let unique = items.filter { seen.insert($0.identityKey).inserted }

    let ranked = await ranker.rank(items: unique, context: context)
    let filtered = ranked.filter { $0.score > 0 }
    return filtered.map(\.item)
}
