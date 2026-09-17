import Penumbra

/// Thread-safe resolver for every ``TreeSitterLanguage`` shipped in ``PenumbraLanguages``.
///
/// Identifiers follow ``LanguageIdentifier`` (`"javascript"`, `"shell"`, `"xml"`, …). Callers
/// that already have an app-specific language enum can map to these strings and use this type
/// instead of re-implementing the grammar switch.
public enum BundledLanguages {
    private static let cache = TreeSitterLanguageCache<String>()

    /// Returns a prepared language for `identifier`, or `nil` when no bundled grammar exists.
    public static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        guard let identifier else { return nil }
        return cache.language(for: identifier) {
            TreeSitterLanguage.bundled(forIdentifier: identifier)
        }
    }

    /// Clears the cache. Useful in tests that want to measure prepare cost again.
    public static func resetCacheForTesting() {
        cache.reset()
    }
}
