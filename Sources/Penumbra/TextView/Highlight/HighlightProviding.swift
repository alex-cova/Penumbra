import Foundation

/// Error thrown when a highlight provider cancels an in-flight operation.
public enum HighlightProvidingError: Error {
    case operationCancelled
}

/// A highlight range returned by a ``HighlightProviding`` object.
public struct SyntaxHighlightRange: Sendable, Hashable {
    public let range: NSRange
    public let highlightName: String

    public init(range: NSRange, highlightName: String) {
        self.range = range
        self.highlightName = highlightName
    }
}

/// Protocol for pluggable syntax-highlight sources (tree-sitter, LSP semantic tokens, etc.).
public protocol HighlightProviding: AnyObject {
    @MainActor
    func setUp(textView: TextView)

    @MainActor
    func willApplyEdit(range: NSRange)

    @MainActor
    func applyEdit(
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    )

    @MainActor
    func queryHighlightsFor(
        range: NSRange,
        completion: @escaping @MainActor (Result<[SyntaxHighlightRange], Error>) -> Void
    )
}

public extension HighlightProviding {
    func willApplyEdit(range: NSRange) {}
}
