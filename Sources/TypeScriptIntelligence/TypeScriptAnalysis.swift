import EditorIntelligence
import Foundation
import LanguageSyntax
import TreeSitterTypeScript

/// Parses one TypeScript or JavaScript buffer. `.tsx` and `.jsx` use `tree_sitter_tsx()`; everything
/// else uses `tree_sitter_typescript()`.
public enum TypeScriptAnalysis {
    public static let languageIdentifier = "typescript"
    public static let javaScriptIdentifier = "javascript"
    public static let providerName = "TypeScript"

    public static func accepts(_ languageIdentifier: String?) -> Bool {
        languageIdentifier == Self.languageIdentifier || languageIdentifier == javaScriptIdentifier
    }

    public static func usesTSX(_ url: URL?) -> Bool {
        switch url?.pathExtension.lowercased() {
        case "tsx", "jsx": return true
        default: return false
        }
    }

    public static func makeCache() -> DocumentParseCache {
        DocumentParseCache(languageIdentifier: languageIdentifier, language: language)
    }

    /// Umbra sees a completed `TSLanguage`, so the grammar pointer is not an `OpaquePointer` here.
    public static var language: OpaquePointer {
        guard let pointer = tree_sitter_typescript() else {
            fatalError("tree_sitter_typescript() returned nil")
        }
        return OpaquePointer(UnsafeRawPointer(pointer))
    }

    public static var tsxLanguage: OpaquePointer {
        guard let pointer = tree_sitter_tsx() else {
            fatalError("tree_sitter_tsx() returned nil")
        }
        return OpaquePointer(UnsafeRawPointer(pointer))
    }

    public static func grammar(for url: URL?) -> OpaquePointer {
        usesTSX(url) ? tsxLanguage : language
    }

    public static func parse(_ source: String, fileURL: URL? = nil) -> TypeScriptParsed? {
        let parser = SyntaxParser(language: grammar(for: fileURL))
        guard let tree = parser.parse(source) else { return nil }
        let text = SourceTextMap(source)
        return TypeScriptParsed(tree: tree, text: text, model: TypeScriptFileModel.build(tree: tree, text: text))
    }

    /// The cache serves TypeScript files that have a URL. JSX and TSX are parsed with the TSX grammar.
    /// An untitled buffer is parsed directly.
    public static func parse(document: Document, cache: DocumentParseCache) async -> TypeScriptParsed? {
        guard accepts(document.languageIdentifier) else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        let source = document.text
        let tree: LanguageSyntax.SyntaxTree?
        if usesTSX(document.url) {
            tree = SyntaxParser(language: tsxLanguage).parse(source)
        } else if document.url != nil, document.languageIdentifier == languageIdentifier {
            tree = await cache.tree(for: document)
        } else {
            tree = SyntaxParser(language: language).parse(source)
        }
        guard let tree else { return nil }
        let text = SourceTextMap(source)
        return TypeScriptParsed(tree: tree, text: text, model: TypeScriptFileModel.build(tree: tree, text: text))
    }
}
