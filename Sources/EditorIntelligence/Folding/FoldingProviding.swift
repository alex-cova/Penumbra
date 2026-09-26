import Foundation

/// Supplies foldable regions for a document snapshot.
public protocol FoldingProviding: Sendable {
    /// Human-readable provider name, used for tracing.
    var name: String { get }

    /// Whether this provider is the semantic authority for the document's language.
    func isPrimary(for languageIdentifier: String?) -> Bool

    /// Discover foldable regions in `document`. May run off the main actor.
    func foldRegions(for document: Document) async -> [FoldingDescriptor]
}

public extension FoldingProviding {
    func isPrimary(for languageIdentifier: String?) -> Bool {
        false
    }
}
