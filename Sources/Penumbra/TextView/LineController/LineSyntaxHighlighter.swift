import CoreGraphics
import Foundation

extension NSAttributedString.Key {
    static let isBold = NSAttributedString.Key("penumbra_isBold")
    static let isItalic = NSAttributedString.Key("penumbra_isItalic")
}

struct LineSyntaxHiglighterSetAttributesResult {
    let isSizingInvalid: Bool
}

final class LineSyntaxHighlighterInput: @unchecked Sendable {
    let attributedString: NSMutableAttributedString
    let byteRange: ByteRange

    init(attributedString: NSMutableAttributedString, byteRange: ByteRange) {
        self.attributedString = attributedString
        self.byteRange = byteRange
    }
}

protocol LineSyntaxHighlighter: AnyObject {
    typealias AsyncCallback = @Sendable (Result<Void, Error>) -> Void
    var theme: Theme { get set }
    var canHighlight: Bool { get }
    /// True while an async highlight submitted by ``syntaxHighlight(_:completion:)`` is still running.
    var isHighlighting: Bool { get }
    /// Whether this highlighter will ever produce non-default colors for a line (`false` for
    /// plain text). Used by `LineController.isSyntaxHighlightPending` so Metal can tell "still
    /// waiting on a highlight" apart from "there is nothing to highlight".
    var canEventuallyHighlight: Bool { get }
    /// `false` when the last synchronous ``syntaxHighlight(_:)`` found no syntax tree to query
    /// (a parse started after `canHighlight` was checked), so the line must stay pending.
    var lastSyncHighlightWasComplete: Bool { get }
    func syntaxHighlight(_ input: LineSyntaxHighlighterInput)
    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback)
    func cancel()
    /// Highlights `input` synchronously when that needs no parse or query (the captures are
    /// already cached). Returns `false`, touching nothing, otherwise.
    func syntaxHighlightFromCache(_ input: LineSyntaxHighlighterInput) -> Bool
}

extension LineSyntaxHighlighter {
    var isHighlighting: Bool { false }
    var canEventuallyHighlight: Bool { true }
    var lastSyncHighlightWasComplete: Bool { true }
    func syntaxHighlightFromCache(_ input: LineSyntaxHighlighterInput) -> Bool { false }
}
