import Foundation

/// Actor-isolated navigation engine that queries registered providers concurrently.
///
/// `navigate(context:)` returns the first non-nil result in provider (priority) order.
/// `collect(context:)` returns all results in provider order. When any provider is primary for a
/// context, only the primary providers are consulted.
///
/// Providers run as unstructured tasks (not a task group): a group waits for every child before
/// it returns, so a provider that ignores cancellation — a stalled server request — would still
/// hold the answer back after it was chosen. After ``priorityGrace`` the best answer in hand wins,
/// so one hung provider can never block go-to-definition indefinitely.
public actor NavigationEngine {
    private let providers: [NavigationProvider]
    /// How long the best answer in hand waits for higher-priority providers that have not
    /// answered yet. A stalled provider must not hold navigation back.
    private let priorityGrace: Duration

    public init(providers: [NavigationProvider], priorityGrace: Duration = .milliseconds(250)) {
        self.providers = providers
        self.priorityGrace = priorityGrace
    }

    /// The providers to ask for `context`: the primary ones when any claim it, otherwise all.
    private func providers(for context: NavigationContext) -> [NavigationProvider] {
        let primary = providers.filter { $0.isPrimary(for: context) }
        return primary.isEmpty ? providers : primary
    }

    /// Return the first non-nil navigation result from the registered providers.
    public func navigate(context: NavigationContext) async -> NavigationResult? {
        let providers = providers(for: context)
        guard !providers.isEmpty else { return nil }
        let (arrivals, finish) = race(providers: providers, context: context)
        defer { finish() }
        var finished = Set<Int>()
        var answers: [Int: NavigationResult] = [:]
        var graceElapsed = false
        for await arrival in arrivals {
            switch arrival {
            case .graceElapsed:
                graceElapsed = true
            case .provider(let index, let answer):
                finished.insert(index)
                if let answer { answers[index] = answer }
            }
            // Provider order is priority. The best answer so far wins once every provider ahead
            // of it has finished; after the grace period the best answer in hand wins, so one
            // stalled high-priority provider cannot hold navigation back indefinitely.
            if let best = answers.keys.min(),
               graceElapsed || (0..<best).allSatisfy(finished.contains) {
                return answers[best]
            }
            if finished.count == providers.count {
                return answers.keys.min().flatMap { answers[$0] }
            }
        }
        return answers.keys.min().flatMap { answers[$0] }
    }

    /// Collect all non-nil navigation results from the registered providers, in provider order.
    /// The wait is bounded by the grace period: a stalled provider yields a partial result
    /// rather than hanging the caller.
    public func collect(context: NavigationContext) async -> [NavigationResult] {
        let providers = providers(for: context)
        guard !providers.isEmpty else { return [] }
        let (arrivals, finish) = race(providers: providers, context: context)
        defer { finish() }
        var finished = Set<Int>()
        var answers: [Int: NavigationResult] = [:]
        for await arrival in arrivals {
            switch arrival {
            case .graceElapsed:
                break
            case .provider(let index, let answer):
                finished.insert(index)
                if let answer { answers[index] = answer }
            }
            if finished.count == providers.count { break }
            if case .graceElapsed = arrival { break }
        }
        return answers.keys.sorted().compactMap { answers[$0] }
    }

    private enum Arrival {
        case provider(Int, NavigationResult?)
        case graceElapsed
    }

    /// Run every provider plus the grace timer. The caller must call the returned finisher
    /// (via `defer`): it cancels the tasks and ends the stream, so breaking out early never
    /// waits for stalled providers — even ones that ignore cancellation.
    private func race(providers: [NavigationProvider], context: NavigationContext) -> (AsyncStream<Arrival>, () -> Void) {
        let grace = priorityGrace
        let (arrivals, continuation) = AsyncStream.makeStream(of: Arrival.self)
        var tasks: [Task<Void, Never>] = providers.enumerated().map { index, provider in
            Task { continuation.yield(.provider(index, await provider.provide(context: context))) }
        }
        tasks.append(Task {
            try? await Task.sleep(for: grace)
            continuation.yield(.graceElapsed)
        })
        let finish = {
            for task in tasks { task.cancel() }
            continuation.finish()
        }
        return (arrivals, finish)
    }
}
