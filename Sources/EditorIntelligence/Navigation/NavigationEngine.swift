import Foundation

/// Actor-isolated navigation engine that queries registered providers in order.
///
/// `navigate(context:)` returns the first non-nil result. `collect(context:)` returns all results.
/// When any provider is primary for a context, only the primary providers are consulted.
public actor NavigationEngine {
    private let providers: [NavigationProvider]

    public init(providers: [NavigationProvider]) {
        self.providers = providers
    }

    /// The providers to ask for `context`: the primary ones when any claim it, otherwise all.
    private func providers(for context: NavigationContext) -> [NavigationProvider] {
        let primary = providers.filter { $0.isPrimary(for: context) }
        return primary.isEmpty ? providers : primary
    }

    /// Return the first non-nil navigation result from the registered providers.
    public func navigate(context: NavigationContext) async -> NavigationResult? {
        for provider in providers(for: context) {
            if let result = await provider.provide(context: context) {
                return result
            }
        }
        return nil
    }

    /// Collect all non-nil navigation results from the registered providers.
    public func collect(context: NavigationContext) async -> [NavigationResult] {
        var results: [NavigationResult] = []
        for provider in providers(for: context) {
            if let result = await provider.provide(context: context) {
                results.append(result)
            }
        }
        return results
    }
}
