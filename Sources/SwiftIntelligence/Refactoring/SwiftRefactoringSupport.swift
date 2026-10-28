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

    /// The whole statements `bytes` covers exactly, when they form one run in a single block: the
    /// trimmed edges must line up with whole items of the innermost block holding the selection.
    func statementRun(exactly bytes: Range<Int>) -> [CodeBlockItemSyntax]? {
        let trimmed = trimmedBytes(bytes)
        guard !trimmed.isEmpty, trimmed.lowerBound < utf8.count,
              let token = tree.token(at: AbsolutePosition(utf8Offset: trimmed.lowerBound)) else { return nil }
        var list: CodeBlockItemListSyntax?
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let found = current.as(CodeBlockItemListSyntax.self) { list = found; break }
            node = current.parent
        }
        guard let items = list.map(Array.init) else { return nil }
        guard let first = items.firstIndex(where: { Self.trimmed($0).lowerBound == trimmed.lowerBound }),
              let last = items[first...].firstIndex(where: { Self.trimmed($0).upperBound == trimmed.upperBound }),
              (first ... last).allSatisfy({
                  Self.trimmed(items[$0]).lowerBound >= trimmed.lowerBound
                      && Self.trimmed(items[$0]).upperBound <= trimmed.upperBound
              })
        else { return nil }
        return Array(items[first ... last])
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

/// The suggested names for the refactorings that introduce one: every identifier in the file is
/// avoided, and the base comes from the shape of the code being named.
enum SwiftRefactoringNaming {
    static func usedNames(in file: SwiftRefactoringFile) -> Set<String> {
        var names = Set<String>()
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind { names.insert(text) }
        }
        return names
    }

    static func name(for expression: ExprSyntax, avoiding used: Set<String>) -> String {
        func lowered(_ word: String) -> String {
            guard let first = word.first else { return "value" }
            return first.lowercased() + word.dropFirst()
        }
        var base = "value"
        if let call = expression.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression
            if let member = callee.as(MemberAccessExprSyntax.self) { base = member.declName.baseName.text }
            else if let reference = callee.as(DeclReferenceExprSyntax.self) { base = reference.baseName.text }
        } else if let member = expression.as(MemberAccessExprSyntax.self) {
            base = member.declName.baseName.text
        } else if let reference = expression.as(DeclReferenceExprSyntax.self) {
            base = reference.baseName.text + "Value"
        } else if expression.is(StringLiteralExprSyntax.self) {
            base = "text"
        } else if expression.is(BooleanLiteralExprSyntax.self) {
            base = "flag"
        } else if expression.is(SubscriptCallExprSyntax.self) {
            base = "element"
        } else if expression.is(InfixOperatorExprSyntax.self) || expression.is(TernaryExprSyntax.self) {
            base = "result"
        }
        for prefix in ["get", "make", "create"] where base.hasPrefix(prefix) && base.dropFirst(prefix.count).first?.isUppercase == true {
            base = String(base.dropFirst(prefix.count))
        }
        var candidate = lowered(base)
        if !SwiftIdentifiers.isValid(candidate) { candidate = "value" }
        var suffix = 2
        let root = candidate
        while used.contains(candidate) {
            candidate = "\(root)\(suffix)"
            suffix += 1
        }
        return candidate
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
