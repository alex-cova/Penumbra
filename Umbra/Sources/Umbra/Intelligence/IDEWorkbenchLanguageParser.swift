import EditorIntelligence
import Foundation
import Penumbra
import PenumbraLanguages
import PenumbraMarkdownLanguage

/// Per-document Tree-sitter parser for workspace symbol indexing.
final class IDEWorkbenchLanguageParser: LanguageParser, @unchecked Sendable {
    /// One parser per language, kept: each remembers the last tree of the documents it parsed, so
    /// the next index pass of an edited document reparses incrementally (F19). A parser made per
    /// call, as this used to, could never reuse anything.
    private let lock = NSLock()
    private var parsers: [String: TreeSitterLanguageParser] = [:]

    func parse(document: Document) async -> SyntaxTree {
        let text = document.contentSnapshot.text ?? ""
        let identifier = document.languageIdentifier ?? "plaintext"
        guard let parser = parser(for: identifier) else {
            return IDEEmptySyntaxTree(text: text)
        }
        return await parser.parse(document: document)
    }

    private func parser(for identifier: String) -> TreeSitterLanguageParser? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = parsers[identifier] { return existing }
        guard let language = language(for: identifier) else { return nil }
        let parser = TreeSitterLanguageParser(language: language)
        parsers[identifier] = parser
        return parser
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
