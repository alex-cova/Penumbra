import Foundation

/// Fans a query out to every registered ``SearchEverywhereProvider`` concurrently, debounces
/// keystrokes, cancels superseded runs, and returns the merged, section-grouped result.
@MainActor
public final class SearchEverywhereEngine {
    public private(set) var providers: [SearchEverywhereProvider]
    /// Debounce applied before a query is dispatched, in milliseconds.
    public var debounceMilliseconds: UInt64 = 120
    /// Max rows requested from each provider per query.
    public var perProviderLimit = 15

    private var runToken = 0
    private var pendingTask: Task<Void, Never>?

    public init(providers: [SearchEverywhereProvider] = []) {
        self.providers = providers
    }

    public func setProviders(_ providers: [SearchEverywhereProvider]) {
        self.providers = providers
    }

    public func addProvider(_ provider: SearchEverywhereProvider) {
        providers.append(provider)
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        runToken += 1
    }

    /// Runs `query` after the debounce and delivers grouped results to `completion` on the main
    /// actor. A newer call supersedes an older one; the superseded call never calls back.
    public func search(_ query: String, completion: @escaping @MainActor ([PaletteSection]) -> Void) {
        runToken += 1
        let token = runToken
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTask?.cancel()
        let providers = self.providers
        let limit = perProviderLimit
        let delay = debounceMilliseconds
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard !Task.isCancelled else { return }
            let sections = await Self.collect(providers: providers, query: trimmed, limit: limit)
            guard !Task.isCancelled, let self, token == self.runToken else { return }
            completion(sections)
        }
    }

    /// Synchronous single-shot for tests and non-debounced callers.
    public func sectionsNow(for query: String) async -> [PaletteSection] {
        await Self.collect(
            providers: providers,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: perProviderLimit
        )
    }

    private static func collect(providers: [SearchEverywhereProvider], query: String, limit: Int) async -> [PaletteSection] {
        let collected: [(order: Int, title: String, items: [PaletteItem])] = await withTaskGroup(
            of: (Int, String, [PaletteItem]).self
        ) { group in
            for provider in providers {
                group.addTask {
                    let items = await provider.items(matching: query, limit: limit)
                    return (provider.sectionOrder, provider.sectionTitle, items)
                }
            }
            var results: [(Int, String, [PaletteItem])] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        return collected
            .filter { !$0.items.isEmpty }
            .sorted { lhs, rhs in
                lhs.order != rhs.order ? lhs.order < rhs.order : lhs.title < rhs.title
            }
            .map { entry in
                PaletteSection(
                    title: entry.title,
                    items: entry.items.sorted { $0.score > $1.score }
                )
            }
    }
}
