import EditorIntelligence
import Foundation
import JavaIntelligence
import TreeSitterSwift

/// Parses one Swift buffer with the Java document parser pointed at `tree_sitter_swift()`.
enum SwiftAnalysis {
    static let languageIdentifier = "swift"
    static let providerName = "Swift"

    /// Umbra sees a completed `TSLanguage`, so the grammar pointer is not an `OpaquePointer` here.
    static var language: OpaquePointer {
        guard let pointer = tree_sitter_swift() else {
            fatalError("tree_sitter_swift() returned nil")
        }
        return OpaquePointer(UnsafeRawPointer(pointer))
    }

    static func parse(_ source: String) -> SwiftParsed? {
        SwiftParseMemo.shared.parsed(for: source) { build(source) }
    }

    /// The model of `source` alone: no tree is kept and the parse memo is left as it is, because
    /// indexing a project parses thousands of files once each.
    static func parseModel(_ source: String) -> SwiftFileModel? {
        build(source)?.model
    }

    /// Parses `source` and maps positions against that same text.
    private static func build(_ source: String) -> SwiftParsed? {
        let parser = JavaSyntaxParser(language: language)
        guard let tree = parser.parse(source) else { return nil }
        let text = SourceTextMap(source)
        return SwiftParsed(tree: tree, text: text, model: SwiftFileModel.build(tree: tree, text: text))
    }

    /// A document's parse. The same text is served from the memo: completion, hover and
    /// navigation arrive together after an edit.
    static func parse(document: Document) -> SwiftParsed? {
        guard document.languageIdentifier == languageIdentifier else { return nil }
        guard !document.contentSnapshot.isElided else { return nil }
        return parse(document.text)
    }
}

/// The last two parsed buffers. Semantic colours, the outline and the breadcrumbs each receive
/// the same text after an edit, so without this each one parses it again.
final class SwiftParseMemo: @unchecked Sendable {
    static let shared = SwiftParseMemo()
    private let lock = NSLock()
    private var entries: [(source: String, parsed: SwiftParsed)] = []

    func cached(for source: String) -> SwiftParsed? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.source == source }?.parsed
    }

    func store(_ parsed: SwiftParsed, for source: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.source == source }
        entries.append((source, parsed))
        if entries.count > 2 { entries.removeFirst() }
    }

    func parsed(for source: String, make: () -> SwiftParsed?) -> SwiftParsed? {
        if let hit = cached(for: source) { return hit }
        guard let parsed = make() else { return nil }
        store(parsed, for: source)
        return parsed
    }
}
