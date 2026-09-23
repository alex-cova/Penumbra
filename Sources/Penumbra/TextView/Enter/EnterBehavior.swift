import Foundation

/// Language-specific rules for the Enter key, consulted by the built-in enter handlers.
///
/// Set on a ``TreeSitterLanguage`` to opt a language into IntelliJ-style behavior: block-comment
/// continuation, splitting string literals, and structure-aware (continuation) indentation.
public struct EnterBehavior: Sendable, Equatable {
    /// Token that opens a block comment (e.g. `"/*"`), or `nil` if the language has none.
    public var blockCommentStart: String?
    /// Token that closes a block comment (e.g. `"*/"`).
    public var blockCommentEnd: String?
    /// Operator inserted when Enter splits a string literal (e.g. `"+"`), or `nil` to never split.
    public var stringConcatenationOperator: String?
    /// Computes indentation from bracket structure instead of the previous line.
    public var cStyleIndent: Bool
    /// Number of normal indents used for a continuation line (unclosed parentheses, unfinished expression).
    public var continuationIndentLevels: Int
    /// Keywords that introduce a statement whose body may omit braces (`if`, `for`, `else`, …).
    public var controlKeywords: Set<String>

    public init(blockCommentStart: String? = nil,
                blockCommentEnd: String? = nil,
                stringConcatenationOperator: String? = nil,
                cStyleIndent: Bool = false,
                continuationIndentLevels: Int = 2,
                controlKeywords: Set<String> = []) {
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.stringConcatenationOperator = stringConcatenationOperator
        self.cStyleIndent = cStyleIndent
        self.continuationIndentLevels = continuationIndentLevels
        self.controlKeywords = controlKeywords
    }

    /// IntelliJ's default Java behavior.
    public static let java = EnterBehavior(
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringConcatenationOperator: "+",
        cStyleIndent: true,
        continuationIndentLevels: 2,
        controlKeywords: ["if", "else", "for", "while", "do"])
}
