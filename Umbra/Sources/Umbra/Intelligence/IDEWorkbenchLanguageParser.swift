import EditorIntelligence
import Penumbra
import PenumbraLanguages
import PenumbraMarkdownLanguage

/// Per-document Tree-sitter parser for workspace symbol indexing.
final class IDEWorkbenchLanguageParser: LanguageParser, @unchecked Sendable {
    func parse(document: Document) async -> SyntaxTree {
        let text = document.contentSnapshot.text ?? ""
        let identifier = document.languageIdentifier ?? "plaintext"
        guard let language = language(for: identifier) else {
            return IDEEmptySyntaxTree(text: text)
        }
        let parser = TreeSitterLanguageParser(language: language)
        return await parser.parse(document: document)
    }

    private func language(for identifier: String) -> TreeSitterLanguage? {
        if identifier == "markdown" {
            return .markdown
        }
        return TreeSitterLanguage.bundled(forIdentifier: identifier)
    }
}

private struct IDEEmptySyntaxTree: SyntaxTree {
    let symbols: [Symbol]
    let words: [String]
    let imports: [String]

    init(text: String) {
        symbols = []
        words = text
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .filter { $0.count > 2 }
        imports = []
    }
}
