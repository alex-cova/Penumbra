import EditorIntelligence
import Foundation
import JavaIntelligence
import TreeSitterTypeScript

/// Parses one TypeScript buffer with the Java document parser pointed at `tree_sitter_typescript()`.
enum TypeScriptAnalysis {
    static let languageIdentifier = "typescript"
    static let providerName = "TypeScript"

    static func makeCache() -> JavaDocumentParseCache {
        JavaDocumentParseCache(languageIdentifier: languageIdentifier, language: language)
    }

    /// Umbra sees a completed `TSLanguage`, so the grammar pointer is not an `OpaquePointer` here.
    private static var language: OpaquePointer {
        guard let pointer = tree_sitter_typescript() else {
            fatalError("tree_sitter_typescript() returned nil")
        }
        return OpaquePointer(UnsafeRawPointer(pointer))
    }

    static func parse(_ source: String) -> TypeScriptParsed? {
        let parser = JavaSyntaxParser(language: language)
        guard let tree = parser.parse(source) else { return nil }
        let text = TypeScriptText(source)
        return TypeScriptParsed(tree: tree, text: text, model: TypeScriptFileModel.build(tree: tree, text: text))
    }

    /// The cache serves files that have a URL. An untitled buffer is parsed directly.
    static func parse(document: Document, cache: JavaDocumentParseCache) async -> TypeScriptParsed? {
        guard document.languageIdentifier == languageIdentifier else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        let source = document.text
        let tree: JavaSyntaxTree?
        if document.url != nil {
            tree = await cache.tree(for: document)
        } else {
            tree = JavaSyntaxParser(language: language).parse(source)
        }
        guard let tree else { return nil }
        let text = TypeScriptText(source)
        return TypeScriptParsed(tree: tree, text: text, model: TypeScriptFileModel.build(tree: tree, text: text))
    }
}
