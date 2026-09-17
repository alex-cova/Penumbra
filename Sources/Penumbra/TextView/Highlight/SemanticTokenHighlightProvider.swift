import Foundation
import EditorIntelligence

/// Highlight provider that reads semantic tokens from a ``SemanticTokenStorage``.
@MainActor
public final class SemanticTokenHighlightProvider: HighlightProviding {
    private weak var textView: TextView?
    private let storage: SemanticTokenStorage
    private let tokenMap: SemanticTokenMap
    private let client: LSPClient?
    private var documentProvider: (() -> Document?)?

    public init(
        storage: SemanticTokenStorage,
        tokenMap: SemanticTokenMap,
        client: LSPClient? = nil,
        documentProvider: (() -> Document?)? = nil
    ) {
        self.storage = storage
        self.tokenMap = tokenMap
        self.client = client
        self.documentProvider = documentProvider
    }

    public func setUp(textView: TextView) {
        self.textView = textView
        Task {
            await refreshTokens()
        }
    }

    public func applyEdit(
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        Task {
            await refreshTokens()
            completion(.success(IndexSet(integersIn: range.location..<(range.location + max(0, range.length + delta)))))
        }
    }

    public func queryHighlightsFor(
        range: NSRange,
        completion: @escaping @MainActor (Result<[SyntaxHighlightRange], Error>) -> Void
    ) {
        let lspRange = LSPRange(
            start: LSPPosition(line: 0, character: range.location),
            end: LSPPosition(line: Int.max, character: range.location + range.length)
        )
        let tokens = storage.tokens(in: lspRange)
        let highlights = tokens.compactMap { token -> SyntaxHighlightRange? in
            guard let textView,
                  let start = textView.location(at: TextLocation(lineNumber: token.line, column: token.character)),
                  let end = textView.location(at: TextLocation(lineNumber: token.line, column: token.character + token.length)) else {
                return nil
            }
            let tokenRange = NSRange(location: start, length: max(0, end - start))
            guard tokenRange.intersection(range)?.length ?? 0 > 0 else {
                return nil
            }
            return SyntaxHighlightRange(range: tokenRange, highlightName: tokenMap.highlightName(for: token))
        }
        completion(.success(highlights))
    }

    private func refreshTokens() async {
        guard let client, let document = documentProvider?() else {
            return
        }
        if let resultId = storage.lastResultId {
            let delta = try? await client.requestSemanticTokensDelta(for: document, previousResultId: resultId)
            if let delta {
                storage.applyDelta(delta)
                return
            }
        }
        if let tokens = try? await client.requestSemanticTokens(for: document) {
            storage.setData(tokens)
        }
    }
}
