import Foundation

struct InsertLineBreakIndentStrategy {
    let indentLevel: Int
    let insertExtraLineBreak: Bool
}

protocol InternalLanguageMode: AnyObject {
    var isSyntaxTreeReady: Bool { get }
    /// Parses from `stringView` directly — no implementation reads a passed-in string, so there is
    /// nothing to pass; the buffer is always the source of truth.
    func parse()
    func parse(completion: @escaping @MainActor @Sendable (Bool) -> Void)
    /// Parse using the buffer reader (no full-document `NSString` materialization).
    func parseFromBuffer()
    func cancelParse()
    func textDidChange(_ change: TextChange) -> LineChangeSet
    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter
    func syntaxNode(at linePosition: LinePosition) -> SyntaxNode?
    func currentIndentLevel(of line: DocumentLineNode, using indentStrategy: IndentStrategy) -> Int
    func strategyForInsertingLineBreak(
        from startLinePosition: LinePosition,
        to endLinePosition: LinePosition,
        using indentStrategy: IndentStrategy) -> InsertLineBreakIndentStrategy
    func detectIndentStrategy() -> DetectedIndentStrategy
    func invalidateSyntaxTree()
    /// The active language's line-comment token (e.g. `"//"`), or `nil` if it has none. Drives
    /// ``TextView/toggleComment()``.
    var lineCommentPrefix: String? { get }
    /// Enter-key rules of the active language (see ``EnterBehavior``), or `nil` for none.
    var enterBehavior: EnterBehavior? { get }
    /// Whether the language defines indentation scopes, i.e. can compute indentation for a new line.
    var hasIndentationScopes: Bool { get }
    /// Syntax nodes containing `linePosition`, innermost first.
    func enclosingSyntaxNodes(at linePosition: LinePosition) -> [SyntaxNode]
}

extension InternalLanguageMode {
    var isSyntaxTreeReady: Bool { true }
    func cancelParse() {}
    func invalidateSyntaxTree() {}
    func parseFromBuffer() {
        parse()
    }
    var lineCommentPrefix: String? { nil }
    var enterBehavior: EnterBehavior? { nil }
    var hasIndentationScopes: Bool { false }
    func enclosingSyntaxNodes(at linePosition: LinePosition) -> [SyntaxNode] { [] }
}
