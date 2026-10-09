import Foundation

/// A lookup from language identifier (`"swift"`, `"typescript"`, …) to ``LanguageConfiguration``.
///
/// The registry pattern mirrors ``SurroundTemplate`` — built-in entries plus host registration —
/// keyed on the same identifier strings produced by ``LanguageIdentifier`` and stored on
/// ``TextView/languageIdentifier``.
public struct LanguageConfigurationRegistry: Sendable {
    private var configurations: [String: LanguageConfiguration]
    /// Returned by ``configuration(for:)`` when no entry (built-in or registered) matches.
    public var fallback: LanguageConfiguration

    public init(
        configurations: [String: LanguageConfiguration] = [:],
        fallback: LanguageConfiguration = .generic
    ) {
        self.configurations = configurations
        self.fallback = fallback
    }

    /// The configurations of every language in ``LanguageDefinitionRegistry/shared`` that has one: the
    /// bundled `javascript`, `jsx`, `typescript`, `tsx`, `java` and `swift`, plus any a host registered
    /// through ``LanguageDefinition/configuration``. Everything else resolves to
    /// ``LanguageConfiguration/generic``. Read each time it is used, so a text view created after a
    /// registration sees it.
    public static var builtIns: LanguageConfigurationRegistry {
        LanguageConfigurationRegistry(configurations: LanguageDefinitionRegistry.shared.configurations)
    }

    /// The configuration for `identifier`, or ``fallback`` (default: ``LanguageConfiguration/generic``)
    /// when the identifier is `nil` or unknown.
    public func configuration(for identifier: String?) -> LanguageConfiguration {
        guard let identifier, let configuration = configurations[identifier] else {
            return fallback
        }
        return configuration
    }

    /// Whether an explicit entry exists for `identifier` (ignoring the fallback).
    public func hasConfiguration(for identifier: String) -> Bool {
        configurations[identifier] != nil
    }

    /// Add or replace the configuration for `identifier`.
    public mutating func register(_ configuration: LanguageConfiguration, for identifier: String) {
        configurations[identifier] = configuration
    }
}
