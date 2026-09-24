import Foundation

/// A provider that resolves navigation requests for a given editor context.
public protocol NavigationProvider: Sendable {
    /// Human-readable provider name, used for tracing.
    var name: String { get }

    /// Produce a navigation result for the given context, or `nil` if the provider has no match.
    func provide(context: NavigationContext) async -> NavigationResult?

    /// Whether this provider is the semantic authority for the context's document (a language
    /// provider for its own language). When any provider claims a context, ``NavigationEngine``
    /// asks only the primary providers, so a name-matching fallback can never answer for a
    /// language that has a real resolver, even when that resolver finds nothing.
    func isPrimary(for context: NavigationContext) -> Bool
}

public extension NavigationProvider {
    func isPrimary(for context: NavigationContext) -> Bool {
        false
    }
}
