import Foundation

/// Builds a copyable reference for the symbol at a position, e.g. `pkg.Class#method(int)`
/// or `pkg.Class.FIELD`. Backs the Copy Reference command in read-only command completion.
public protocol SymbolReferenceProviding: Sendable {
    func symbolReference(for document: Document, at position: TextPosition) async -> String?
}
