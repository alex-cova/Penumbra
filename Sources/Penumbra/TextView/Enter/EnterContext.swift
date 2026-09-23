import Foundation

/// Snapshot of the editor state handed to an ``EnterHandlerDelegate``.
@MainActor
public struct EnterContext {
    /// The selection being replaced by the line break (empty for a plain caret).
    public let selectedRange: NSRange
    /// Text of the caret's line up to the start of the selection.
    public let textBeforeCaret: String
    /// Text from the end of the selection to the end of that line, excluding the line break.
    public let textAfterCaret: String
    /// Literal leading whitespace of the caret's line.
    public let leadingWhitespace: String
    public let indentStrategy: IndentStrategy
    /// The line-ending symbol to insert.
    public let lineBreak: String
    public let behavior: EnterBehavior?
    /// `true` when ``indentString(textAfterCaret:)`` is computed from bracket structure.
    public let usesSmartIndent: Bool
    /// Syntax nodes containing the caret, innermost first. Empty without a syntax tree.
    public var enclosingSyntaxNodes: [SyntaxNode] { nodeProvider() }

    let indentProvider: (String) -> String?
    let lineTextProvider: (Int) -> String?
    let nodeProvider: () -> [SyntaxNode]

    init(selectedRange: NSRange,
         textBeforeCaret: String,
         textAfterCaret: String,
         leadingWhitespace: String,
         indentStrategy: IndentStrategy,
         lineBreak: String,
         behavior: EnterBehavior?,
         usesSmartIndent: Bool,
         indentProvider: @escaping (String) -> String?,
         lineTextProvider: @escaping (Int) -> String?,
         nodeProvider: @escaping () -> [SyntaxNode]) {
        self.selectedRange = selectedRange
        self.textBeforeCaret = textBeforeCaret
        self.textAfterCaret = textAfterCaret
        self.leadingWhitespace = leadingWhitespace
        self.indentStrategy = indentStrategy
        self.lineBreak = lineBreak
        self.behavior = behavior
        self.usesSmartIndent = usesSmartIndent
        self.indentProvider = indentProvider
        self.lineTextProvider = lineTextProvider
        self.nodeProvider = nodeProvider
    }

    /// One normal indent level.
    public var normalIndent: String {
        indentStrategy.string(indentLevel: 1)
    }

    /// Text of the line `offset` rows from the caret's line (`1` is the next line), or `nil` past the document.
    public func textOfLine(atRowOffset offset: Int) -> String? {
        lineTextProvider(offset)
    }

    /// The indentation for the new line, given the text that will follow the caret on it.
    /// Falls back to the current line's leading whitespace when the language has no smart indent.
    public func indentString(textAfterCaret: String) -> String {
        indentProvider(textAfterCaret) ?? leadingWhitespace
    }

    /// Number of leading spaces/tabs of ``textAfterCaret``; a handler extends its range over them so the
    /// text moved to the new line is not indented twice.
    var leadingWhitespaceLengthAfterCaret: Int {
        textAfterCaret.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
    }
}
