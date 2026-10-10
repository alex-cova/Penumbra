import EditorIntelligence
import Foundation
import LanguageSyntax
import TreeSitterSwift

/// Parses one Swift buffer with the Java document parser pointed at `tree_sitter_swift()`.
public enum SwiftAnalysis {
    public static let languageIdentifier = "swift"
    public static let providerName = "Swift"

    /// Umbra sees a completed `TSLanguage`, so the grammar pointer is not an `OpaquePointer` here.
    public static var language: OpaquePointer {
        guard let pointer = tree_sitter_swift() else {
            fatalError("tree_sitter_swift() returned nil")
        }
        return OpaquePointer(UnsafeRawPointer(pointer))
    }

    public static func parse(_ source: String) -> SwiftParsed? {
        SwiftParseMemo.shared.parsed(for: source) { build(source) }
    }

    /// The model of `source` alone: no tree is kept and the parse memo is left as it is, because
    /// indexing a project parses thousands of files once each.
    public static func parseModel(_ source: String) -> SwiftFileModel? {
        build(source)?.model
    }

    /// Parses `source` and maps positions against that same text.
    private static func build(_ source: String) -> SwiftParsed? {
        let parser = SyntaxParser(language: language)
        guard let tree = parser.parse(source) else { return nil }
        let text = SourceTextMap(source)
        return SwiftParsed(tree: tree, text: text, model: SwiftFileModel.build(tree: tree, text: text))
    }

    /// Documents with a URL are parsed through ``DocumentParseCache``, which reapplies the last
    /// tree after a one-edit diff. A string with no URL (the outline, colours) still uses the memo.
    public static func parse(document: Document) async -> SwiftParsed? {
        guard document.languageIdentifier == languageIdentifier else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        let source = document.text
        let tree: LanguageSyntax.SyntaxTree?
        if document.url != nil {
            tree = await documentCache.tree(for: document)
        } else {
            tree = SyntaxParser(language: language).parse(source)
        }
        guard let tree else { return nil }
        let text = SourceTextMap(source)
        return SwiftParsed(tree: tree, text: text, model: SwiftFileModel.build(tree: tree, text: text))
    }

    private static let documentCache = DocumentParseCache(languageIdentifier: languageIdentifier, language: language)
}

/// The last two parsed buffers. Semantic colours, the outline and the breadcrumbs each receive
/// the same text after an edit, so without this each one parses it again.
public final class SwiftParseMemo: @unchecked Sendable {
    public static let shared = SwiftParseMemo()
    private let lock = NSLock()
    private var entries: [(source: String, parsed: SwiftParsed)] = []

    public func cached(for source: String) -> SwiftParsed? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.source == source }?.parsed
    }

    public func store(_ parsed: SwiftParsed, for source: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.source == source }
        entries.append((source, parsed))
        if entries.count > 2 { entries.removeFirst() }
    }

    public func parsed(for source: String, make: () -> SwiftParsed?) -> SwiftParsed? {
        if let hit = cached(for: source) { return hit }
        guard let parsed = make() else { return nil }
        store(parsed, for: source)
        return parsed
    }
}
