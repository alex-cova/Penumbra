import Foundation

/// An inline completion suggestion as the editor presents it: ghost text at `utf16Offset`,
/// the first line drawn inline at the caret and any extra lines below (multi-line mode).
public struct InlineCompletionPresentation: Equatable, Sendable {
    public var utf16Offset: Int
    public var firstLine: String
    public var extraLines: [String]

    public init(utf16Offset: Int, firstLine: String, extraLines: [String] = []) {
        self.utf16Offset = utf16Offset
        self.firstLine = firstLine
        self.extraLines = extraLines
    }

    public init(utf16Offset: Int, text: String) {
        let lines = text.components(separatedBy: "\n")
        self.init(
            utf16Offset: utf16Offset,
            firstLine: lines.first ?? "",
            extraLines: Array(lines.dropFirst())
        )
    }

    /// The full text, as accepting the whole suggestion inserts it.
    public var text: String {
        ([firstLine] + extraLines).joined(separator: "\n")
    }
}
