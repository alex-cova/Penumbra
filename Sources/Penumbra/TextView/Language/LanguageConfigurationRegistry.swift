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

    /// The built-in registry: dedicated tables for `javascript`, `typescript`, `java`, `swift`,
    /// everything else resolving to ``LanguageConfiguration/generic``.
    public static let builtIns: LanguageConfigurationRegistry = {
        var map: [String: LanguageConfiguration] = [:]
        for identifier in ["javascript", "jsx", "typescript", "tsx", "java", "swift"] {
            if let configuration = LanguageConfiguration.builtIn(forIdentifier: identifier) {
                map[identifier] = configuration
            }
        }
        return LanguageConfigurationRegistry(configurations: map)
    }()

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
