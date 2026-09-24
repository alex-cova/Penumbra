import Foundation

/// A label shown inline in the text without being part of it: `count:` before an argument.
///
/// Hints are display-only. They are not selected, copied or undone, and the editor keeps them
/// where they are in the text as it is edited until the provider sends fresh ones.
public struct InlayHint: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The name of the parameter an argument is passed to.
        case parameter
        case other
    }

    /// The UTF-16 offset in the document the hint sits in front of.
    public let utf16Offset: Int
    /// The text shown, with any punctuation (`count:`).
    public let label: String
    public let kind: Kind

    public init(utf16Offset: Int, label: String, kind: Kind = .parameter) {
        self.utf16Offset = utf16Offset
        self.label = label
        self.kind = kind
    }
}

/// Supplies the inlay hints for a range of a document.
public protocol InlayHintProviding: Sendable {
    /// The hints whose offsets fall in `range` (a hint at either end is included). A provider
    /// should bound its work, since this runs whenever the visible text changes.
    func inlayHints(for document: Document, in range: TextRange) async -> [InlayHint]
}
