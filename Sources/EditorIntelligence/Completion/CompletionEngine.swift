import Foundation

/// Asynchronous completion engine that orchestrates providers, merges results, ranks them, and
/// filters out low-scoring suggestions.
///
/// Calls to `complete(context:)` and `completeUpdates(context:)` are debounced and cancel any
/// in-flight request. Providers are run concurrently. Each provider may yield more than once;
/// every merged snapshot is ranked and published. The returned items are deduplicated.
public actor CompletionEngine {
    public let providers: [CompletionProvider]
    public nonisolated let ranker: Ranker
    public let debounceInterval: TimeInterval
    private var currentTask: Task<Void, Never>?

    public init(
        providers: [CompletionProvider],
        ranker: Ranker = DefaultRanker(),
        debounceInterval: TimeInterval = 0.05
    ) {
        self.providers = providers
        self.ranker = ranker
        self.debounceInterval = debounceInterval
    }

    /// Request completions for the given context, returning the final ranked list.
    ///
    /// Throws `CancellationError` if the request is cancelled before completion.
    public func complete(context: CompletionContext) async throws -> [CompletionItem] {
        var items: [CompletionItem] = []
        for try await update in completeUpdates(context: context) {
            items = update.items
        }
        return items
    }

    /// Ranked snapshots as providers yield. Explicit requests are not debounced.
    public func completeUpdates(context: CompletionContext) -> AsyncThrowingStream<CompletionUpdate, Error> {
        currentTask?.cancel()
        let providers = self.providers
        let ranker = self.ranker
        let debounce = context.trigger == .manual ? 0 : debounceInterval
        let (stream, continuation) = AsyncThrowingStream<CompletionUpdate, Error>.makeStream()
        let task = Task {
            do {
                if debounce > 0 {
                    try await Task.sleep(for: .seconds(debounce))
                }
                try Task.checkCancellation()
                try await emit(context: context, providers: providers, ranker: ranker, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        currentTask = task
        return stream
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

private func emit(
    context: CompletionContext,
    providers: [CompletionProvider],
    ranker: Ranker,
    continuation: AsyncThrowingStream<CompletionUpdate, Error>.Continuation
) async throws {
    let primaryNames = Set(providers.filter { $0.isPrimary(for: context) }.map(\.name))
    let state = CompletionMergeState(names: providers.map(\.name))
    try await withThrowingTaskGroup(of: Void.self) { group in
        for provider in providers {
            group.addTask {
                var sawFinished = false
                for await update in provider.provideUpdates(context: context) {
                    try Task.checkCancellation()
                    let snapshot = await state.absorb(
                        name: provider.name,
                        items: update.items,
                        finished: update.isFinished,
                        advertisement: update.advertisement,
                        emptyText: update.emptyText,
                        primaryNames: primaryNames,
                        context: context,
                        ranker: ranker
                    )
                    continuation.yield(snapshot)
                    if update.isFinished {
                        sawFinished = true
                    }
                }
                if !sawFinished {
                    let snapshot = await state.absorb(
                        name: provider.name,
                        items: [],
                        finished: true,
                        advertisement: nil,
                        emptyText: nil,
                        primaryNames: primaryNames,
                        context: context,
                        ranker: ranker,
                        keepExistingItems: true
                    )
                    continuation.yield(snapshot)
                }
            }
        }
        try await group.waitForAll()
    }
}

/// Latest items from each provider, merged under a lock because providers yield concurrently.
private final class CompletionMergeState: @unchecked Sendable {
    private let lock = NSLock()
    private var itemsByProvider: [String: [CompletionItem]] = [:]
    private var finished: Set<String> = []
    private let providerOrder: [String]
    private var advertisement: String?
    private var emptyText: String?

    init(names: [String]) {
        providerOrder = names
    }

    func absorb(
        name: String,
        items: [CompletionItem],
        finished isFinished: Bool,
        advertisement: String?,
        emptyText: String?,
        primaryNames: Set<String>,
        context: CompletionContext,
        ranker: Ranker,
        keepExistingItems: Bool = false
    ) async -> CompletionUpdate {
        let stored = store(
            name: name, items: items, finished: isFinished, advertisement: advertisement, emptyText: emptyText,
            keepExistingItems: keepExistingItems
        )

        var combined = stored.items
        let done = stored.done
        let ad = stored.advertisement
        let empty = stored.emptyText
        if !primaryNames.isEmpty {
            let primaryItems = combined.filter { primaryNames.contains($0.source) }
            if !primaryItems.isEmpty || context.isMemberAccess {
                combined = primaryItems
            }
        }
        var seen = Set<String>()
        let unique = combined.filter { seen.insert($0.identityKey).inserted }
        let ranked = await ranker.rank(items: unique, context: context)
        let merged = ranked.filter { $0.score > 0 }.map(\.item)
        return CompletionUpdate(items: merged, isFinished: done, advertisement: ad, emptyText: empty)
    }

    private func store(
        name: String, items: [CompletionItem], finished isFinished: Bool, advertisement: String?, emptyText: String?,
        keepExistingItems: Bool
    ) -> (items: [CompletionItem], done: Bool, advertisement: String?, emptyText: String?) {
        lock.lock()
        defer { lock.unlock() }
        if !keepExistingItems || itemsByProvider[name] == nil {
            itemsByProvider[name] = items
        }
        if isFinished {
            finished.insert(name)
        }
        if let advertisement {
            self.advertisement = advertisement
        }
        if let emptyText {
            self.emptyText = emptyText
        }
        var combined: [CompletionItem] = []
        for providerName in providerOrder {
            combined.append(contentsOf: itemsByProvider[providerName] ?? [])
        }
        let done = !providerOrder.isEmpty && providerOrder.allSatisfy { finished.contains($0) }
        return (combined, done, self.advertisement, self.emptyText)
    }
}
