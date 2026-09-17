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
    func syntaxHighlight(_ input: LineSyntaxHighlighterInput)
    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback)
    func cancel()
}

extension LineSyntaxHighlighter {
    var isHighlighting: Bool { false }
    var canEventuallyHighlight: Bool { true }
}
