import EditorIntelligence
import Foundation
import JavaIntelligence

/// Syntax errors from the tree-sitter tree: the smallest `ERROR` or missing node, one diagnostic each.
struct TypeScriptDiagnosticProvider: DiagnosticProvider {
    let name = TypeScriptAnalysis.providerName
    private let cache: JavaDocumentParseCache

    init(cache: JavaDocumentParseCache) {
        self.cache = cache
    }

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == TypeScriptAnalysis.languageIdentifier else { return [] }
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
