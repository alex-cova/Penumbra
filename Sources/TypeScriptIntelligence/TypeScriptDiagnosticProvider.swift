import EditorIntelligence
import Foundation
import LanguageSyntax

/// Syntax errors from the tree-sitter tree: the smallest `ERROR` or missing node, one diagnostic each.
public struct TypeScriptDiagnosticProvider: DiagnosticProvider {
    public let name = TypeScriptAnalysis.providerName
    private let cache: DocumentParseCache

    public init(cache: DocumentParseCache) {
        self.cache = cache
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard TypeScriptAnalysis.accepts(document.languageIdentifier) else { return [] }
        guard let parsed = await TypeScriptAnalysis.parse(document: document, cache: cache) else { return [] }
        return parsed.model.errors.prefix(100).map { error in
            let start = parsed.text.position(atByte: error.bytes.lowerBound)
            var end = parsed.text.position(atByte: error.bytes.upperBound)
            if start.utf16Offset == end.utf16Offset {
                let next = min(parsed.text.utf16Length, start.utf16Offset + 1)
                end = parsed.text.position(utf16: next)
            }
            return Diagnostic(
                severity: .error,
                message: "Syntax error",
                range: EditorIntelligence.TextRange(start: start, end: end),
                source: name,
                code: "syntax"
            )
        }
    }
}
