import Foundation

/// Whether syntax colors can be produced for a given range right now.
enum MinimapSyntaxAvailability {
    /// No syntax tree at all (plain-text language mode). Flat bars are the final answer and may
    /// be cached permanently.
    case unavailable
    /// A tree-sitter language mode exists but the tree isn't ready or doesn't cover the range
    /// yet. Draw flat bars for now, don't cache, and try again once parsing advances.
    case pending
    /// Captures are available for the range.
    case ready
}

/// Everything the minimap reads from the editor, behind a protocol so tests can drive it with a
/// windowless fake instead of a live `TextView`. `TextInputView` conforms in
/// `TextInputView+Minimap.swift`; keeping the three syntax/folding accessors here (rather than
/// widening `TextInputView`'s API) leaves `languageMode` and `foldingController` `private`.
@MainActor
protocol MinimapContentSource: AnyObject {
    var lineManager: LineManager { get }
    var stringView: StringView { get }
    var theme: Theme { get }
    var indentStrategy: IndentStrategy { get }
    var textContainerInset: UIEdgeInsets { get }
    /// Bumped every time the syntax tree is rebuilt/reparsed — lets the minimap negative-cache
    /// a `.pending`/`.unavailable` answer without re-querying every frame.
    var syntaxParseGeneration: Int { get }

    func minimapSyntaxAvailability(forUTF16Range range: NSRange) -> MinimapSyntaxAvailability
    func minimapCaptures(inByteRange range: ByteRange) -> [TreeSitterCapture]
    func isLineHidden(_ lineID: DocumentLineNodeID) -> Bool
}
