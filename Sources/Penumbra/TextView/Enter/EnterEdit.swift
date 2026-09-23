import Foundation

/// A single replacement produced by an Enter handler.
public struct EnterEdit: Equatable {
    /// Range replaced by ``text``.
    public let replacementRange: NSRange
    /// Text that replaces ``replacementRange``, including the line break.
    public let text: String
    /// Caret position in UTF-16 units relative to the start of ``text``. `nil` places the caret at the end.
    public let caretOffset: Int?

    public init(replacementRange: NSRange, text: String, caretOffset: Int? = nil) {
        self.replacementRange = replacementRange
        self.text = text
        self.caretOffset = caretOffset
    }
}
