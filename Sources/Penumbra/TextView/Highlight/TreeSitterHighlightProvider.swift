import Foundation

/// Wraps the built-in tree-sitter language mode as a ``HighlightProviding`` source.
@MainActor
public final class TreeSitterHighlightProvider: HighlightProviding {
    private weak var textView: TextView?

    public init() {}

    public func setUp(textView: TextView) {
        self.textView = textView
    }

    public func applyEdit(
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        var indices = IndexSet(integersIn: range.location..<(range.location + max(0, range.length + delta)))
        if delta > 0 {
            indices.insert(integersIn: range.location..<(range.location + delta))
        }
        completion(.success(indices))
    }

    public func queryHighlightsFor(
        range: NSRange,
        completion: @escaping @MainActor (Result<[SyntaxHighlightRange], Error>) -> Void
    ) {
        guard let textView else {
            completion(.success([]))
            return
        }
        let captures = textView.syntaxHighlightCaptures(in: range)
        let results = captures.compactMap { capture -> SyntaxHighlightRange? in
            let captureRange = NSRange(capture.byteRange)
            let capped = captureRange.intersection(range) ?? captureRange
            guard capped.length > 0 else {
                return nil
            }
            return SyntaxHighlightRange(range: capped, highlightName: capture.name)
        }
        completion(.success(results))
    }
}
