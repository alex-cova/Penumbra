import Foundation
import SwiftParser
import SwiftSyntax

/// A Swift buffer parsed by swift-syntax: the exact tree, for the work that must be right about
/// the grammar (scopes, inspections, refactoring edits).
///
/// The editor itself keeps using tree-sitter, which is incremental and is what highlighting, folding and
/// the keystroke paths read. This parse is not incremental and is never made on a keystroke: callers
/// schedule it from a pause in typing or a save and drop the answer if the text moved on
/// (`docs/PERFORMANCE_RULES.md`). Offsets in the tree are UTF-8 byte offsets, the same unit as
/// `SwiftFileModel`'s, so the two can be compared position by position.
public struct SwiftSyntaxDocument: Sendable {
    public let tree: SourceFileSyntax
    public let utf8Length: Int

    /// Whether the parser had to recover from a syntax error anywhere in the file.
    public var hasSyntaxErrors: Bool { tree.hasError }

    public static func parse(_ text: String) -> SwiftSyntaxDocument {
        SwiftSyntaxDocument(tree: Parser.parse(source: text), utf8Length: text.utf8.count)
    }
}

/// The last few parses, so the queries that follow one another on unchanged text (an inspection run, a
/// quick fix, a refactoring preview) parse once.
///
/// Keyed by the text's length and hash, the way `JavaNavigationParseMemo` is: a document version would
/// miss when two views of a buffer lag each other. Bounded by count and by size, because a tree is much
/// larger than its source: a text over `maximumUTF8Length` is parsed and returned but not kept.
public final class SwiftSyntaxParseCache: @unchecked Sendable {
    public static let shared = SwiftSyntaxParseCache()

    private struct Key: Hashable {
        let length: Int
        let hash: Int
    }

    private let capacity: Int
    private let maximumUTF8Length: Int
    private let lock = NSLock()
    /// Most recently used last.
    private var entries: [(key: Key, document: SwiftSyntaxDocument)] = []

    public init(capacity: Int = 6, maximumUTF8Length: Int = 512 * 1024) {
        self.capacity = max(capacity, 1)
        self.maximumUTF8Length = maximumUTF8Length
    }

    public func document(for text: String) -> SwiftSyntaxDocument {
        let key = Key(length: text.utf8.count, hash: text.hashValue)
        if let cached = lookup(key) { return cached }
        // Parsed outside the lock: it takes milliseconds, and two callers asking for the same text at
        // once would rather both parse than one wait.
        let document = SwiftSyntaxDocument.parse(text)
        if key.length <= maximumUTF8Length { store(document, for: key) }
        return document
    }

    public var count: Int { lock.withLock { entries.count } }

    private func lookup(_ key: Key) -> SwiftSyntaxDocument? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.document
        }
    }

    private func store(_ document: SwiftSyntaxDocument, for key: Key) {
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.append((key, document))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }
}
