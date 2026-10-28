import EditorIntelligence
import Foundation
import SwiftOperators
import SwiftSyntax

/// One change a refactoring makes, in UTF-8 byte offsets of the text it was computed from.
public struct SwiftTextEdit: Sendable, Hashable {
    public var bytes: Range<Int>
    public var replacement: String

    public init(bytes: Range<Int>, replacement: String) {
        self.bytes = bytes
        self.replacement = replacement
    }
}

/// Why a refactoring cannot be done here, in words the editor can show.
public struct SwiftRefactoringFailure: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

public typealias SwiftRefactoringResult = Result<[SwiftTextEdit], SwiftRefactoringFailure>

/// A parsed file as the refactorings read it: the operator-folded tree (a selection such as `b * c` in
/// `a + b * c` is a node only once precedence is applied), the unfolded document the scope lookup runs on,
/// and the byte view of the text.
struct SwiftRefactoringFile {
    let text: String
    let utf8: [UInt8]
    let document: SwiftSyntaxDocument
    let tree: SourceFileSyntax
    let map: SourceTextMap
    private let memo = Memo()

    /// Every bare identifier reference and where it resolves, computed once per file for all the refactorings
    /// that ask (the lookup walks the whole tree).
    var references: [SwiftSyntaxScopes.Reference] {
        memo.lock.withLock {
            if let known = memo.references { return known }
            let computed = SwiftSyntaxScopes.references(in: document)
            memo.references = computed
            return computed
        }
    }

    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var references: [SwiftSyntaxScopes.Reference]?
    }

    init?(text: String) {
        guard text.utf8.count <= SwiftInspectionService.maximumUTF8Length else { return nil }
        // The menu asks for every refactoring in turn; they share one parse of the same text.
        let document = SwiftSyntaxParseCache.shared.document(for: text)
        // A file the parser had to repair is not one to rewrite: the tree may not say what the text says.
        guard !document.hasSyntaxErrors else { return nil }
        self.text = text
        self.utf8 = Array(text.utf8)
        self.document = document
        self.tree = OperatorTable.standardOperators.foldAll(document.tree, errorHandler: { _ in })
            .as(SourceFileSyntax.self) ?? document.tree
        self.map = SourceTextMap(text)
    }

    /// The file for `text`, parsed and folded once for the refactorings that ask about the same text in turn
    /// (the ⌥↩ menu tries all of them).
    static func load(_ text: String) -> SwiftRefactoringFile? {
        if let hit = cache.get(text) { return hit.file }
        let file = SwiftRefactoringFile(text: text)
        cache.put(text, file)
        return file
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        struct Entry {
            let text: String
            let file: SwiftRefactoringFile?
        }

        private let lock = NSLock()
        private var entry: Entry?

        func get(_ text: String) -> Entry? {
            lock.withLock { entry.flatMap { $0.text == text ? $0 : nil } }
        }

        func put(_ text: String, _ file: SwiftRefactoringFile?) {
            lock.withLock { entry = Entry(text: text, file: file) }
        }
    }

    func string(_ bytes: Range<Int>) -> String { String(decoding: utf8[bytes], as: UTF8.self) }

    /// The node's range without its leading and trailing trivia.
    static func trimmed(_ node: some SyntaxProtocol) -> Range<Int> {
        node.positionAfterSkippingLeadingTrivia.utf8Offset ..< node.endPositionBeforeTrailingTrivia.utf8Offset
    }

    /// `bytes` shrunk past whitespace at both ends.
    func trimmedBytes(_ bytes: Range<Int>) -> Range<Int> {
        var lower = bytes.lowerBound
        var upper = bytes.upperBound
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while lower < upper, isSpace(utf8[lower]) { lower += 1 }
        while upper > lower, isSpace(utf8[upper - 1]) { upper -= 1 }
        return lower ..< upper
    }

    /// The outermost expression whose text is exactly `bytes`.
    func expression(exactly bytes: Range<Int>) -> ExprSyntax? {
        guard !bytes.isEmpty, bytes.lowerBound < utf8.count,
              let token = tree.token(at: AbsolutePosition(utf8Offset: bytes.lowerBound)) else { return nil }
        var found: ExprSyntax?
        var node: Syntax? = Syntax(token)
        while let current = node {
            let range = Self.trimmed(current)
            if range.lowerBound < bytes.lowerBound || range.upperBound > bytes.upperBound && range != bytes { break }
            if range == bytes, let expression = current.as(ExprSyntax.self) { found = expression }
            node = current.parent
        }
        return found
    }

    /// The whitespace between the start of the line and `byte`, or nil when something else precedes it.
    func indentation(before byte: Int) -> String? {
        var start = byte
        while start > 0, utf8[start - 1] != 0x0A { start -= 1 }
        let prefix = utf8[start ..< byte]
        return prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) ? String(decoding: prefix, as: UTF8.self) : nil
    }

    /// The nearest statement or declaration item around `node`.
    static func enclosingItem(of node: some SyntaxProtocol) -> CodeBlockItemSyntax? {
        var current: Syntax? = Syntax(node)
        while let candidate = current {
            if let item = candidate.as(CodeBlockItemSyntax.self) { return item }
            current = candidate.parent
        }
        return nil
    }

    func edits(from syntax: [SwiftTextEdit]) -> [TextEdit] {
        syntax.map { TextEdit(range: map.range(bytes: $0.bytes), replacement: $0.replacement) }
    }
}

enum SwiftIdentifiers {
    /// Whether `name` can be written as an identifier without backticks.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || first.properties.isAlphabetic else { return false }
        guard name.unicodeScalars.allSatisfy({ $0 == "_" || $0.properties.isAlphabetic || ("0" ... "9").contains($0) }) else { return false }
        return !reserved.contains(name)
    }

    static let reserved: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "Any", "as",
        "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try", "_",
    ]
}
