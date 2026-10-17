import EditorIntelligence
import Foundation

/// Syntax errors from the tree-sitter tree as diagnostics, for any language with a grammar.
///
/// The tree comes from `tree`: a shared ``DocumentParseCache`` through the convenience
/// initializer below, or any other fetch. Positions are mapped with a ``SourceTextMap`` built
/// from the parsed bytes, so they always match the parsed text. The provider does no debouncing
/// of its own: `refreshDiagnostics` already follows the adapter's content-refresh debounce and
/// cancels superseded runs.
public struct SyntaxDiagnosticProvider: DiagnosticProvider {
    public let name: String
    private let languageIdentifiers: Set<String>
    private let severity: DiagnosticSeverity
    private let limit: Int
    private let tokenName: @Sendable (String) -> String
    /// Language-specific reinterpretation of a collected problem with the tree and source
    /// in hand (e.g. Java's missing-`;` spilling onto the next line). Defaults to identity.
    private let adjustProblem: @Sendable (SyntaxProblem, SyntaxTree, String) -> SyntaxProblem
    private let tree: @Sendable (Document) async -> SyntaxTree?

    public init(
        name: String,
        languageIdentifiers: Set<String>,
        severity: DiagnosticSeverity = .error,
        limit: Int = 100,
        tokenName: @Sendable @escaping (String) -> String = SyntaxProblem.defaultTokenName,
        adjustProblem: @Sendable @escaping (SyntaxProblem, SyntaxTree, String) -> SyntaxProblem = { problem, _, _ in problem },
        tree: @Sendable @escaping (Document) async -> SyntaxTree?
    ) {
        self.name = name
        self.languageIdentifiers = languageIdentifiers
        self.severity = severity
        self.limit = limit
        self.tokenName = tokenName
        self.adjustProblem = adjustProblem
        self.tree = tree
    }

    /// Trees from a shared cache, untitled buffers parsed directly. `language` is a
    /// `tree_sitter_*()` pointer and must stay valid for the provider's lifetime.
    public init(
        name: String,
        languageIdentifiers: Set<String>,
        severity: DiagnosticSeverity = .error,
        limit: Int = 100,
        tokenName: @Sendable @escaping (String) -> String = SyntaxProblem.defaultTokenName,
        adjustProblem: @Sendable @escaping (SyntaxProblem, SyntaxTree, String) -> SyntaxProblem = { problem, _, _ in problem },
        cache: DocumentParseCache,
        language: OpaquePointer
    ) {
        // `OpaquePointer` is not `Sendable`; the grammar pointer stays valid for the
        // provider's lifetime, so it crosses the boundary as its address.
        let address = UInt(bitPattern: language)
        self.init(name: name, languageIdentifiers: languageIdentifiers, severity: severity, limit: limit, tokenName: tokenName, adjustProblem: adjustProblem) { document in
            if document.url != nil {
                return await cache.tree(for: document)
            }
            guard !document.contentSnapshot.isElided else { return nil }
            guard let grammar = OpaquePointer(bitPattern: address) else { return nil }
            return SyntaxParser(language: grammar).parse(document.text)
        }
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard languageIdentifiers.contains(document.languageIdentifier ?? "") else { return [] }
        guard let tree = await tree(document) else { return [] }
        guard tree.rootNode.hasError else { return [] }
        let problems = SyntaxErrorCollector.problems(in: tree, limit: limit)
        guard !problems.isEmpty else { return [] }
        // Built only when there are problems, and from the parsed bytes.
        let source = String(decoding: tree.sourceBytes, as: UTF8.self)
        let map = SourceTextMap(source)
        return problems.map { problem in
            let problem = adjustProblem(problem, tree, source)
            var range = map.range(bytes: problem.bytes)
            if range.start.utf16Offset == range.end.utf16Offset {
                // A missing token is zero-width: widen one UTF-16 unit, backwards first so
                // the squiggle sits on the preceding character.
                if range.start.utf16Offset > 0 {
                    range = TextRange(start: map.position(utf16: range.start.utf16Offset - 1), end: range.end)
                } else if range.end.utf16Offset < map.utf16Length {
                    range = TextRange(start: range.start, end: map.position(utf16: range.end.utf16Offset + 1))
                }
            }
            return Diagnostic(
                severity: severity,
                message: problem.message(tokenName: tokenName),
                range: range,
                source: name,
                code: "syntax"
            )
        }
    }
}
