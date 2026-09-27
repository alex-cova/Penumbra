@preconcurrency import AppKit
import Foundation

class EditorTextPosition: NSObject, @unchecked Sendable {}
class EditorTextRange: NSObject {
    @objc var start: EditorTextPosition { fatalError("override") }
    @objc var end: EditorTextPosition { fatalError("override") }
    @objc var isEmpty: Bool { fatalError("override") }
}
class EditorTextSelectionRect: NSObject {
    @objc var rect: CGRect { .zero }
    @objc var writingDirection: NSWritingDirection { .leftToRight }
    @objc var containsStart: Bool { false }
    @objc var containsEnd: Bool { false }
    @objc var isVertical: Bool { false }
}

protocol EditorTextInputTokenizer: NSObjectProtocol {
    func isPosition(_ position: EditorTextPosition, atBoundary granularity: EditorTextGranularity, inDirection direction: EditorTextDirection) -> Bool
    func position(from position: EditorTextPosition, toBoundary granularity: EditorTextGranularity, inDirection direction: EditorTextDirection) -> EditorTextPosition?
}

class EditorTextInputStringTokenizer: NSObject, EditorTextInputTokenizer {
    weak var textInput: (NSResponder & EditorTextInput)?
    init(textInput: (NSResponder & EditorTextInput)? = nil) { self.textInput = textInput; super.init() }
    func isPosition(_ position: EditorTextPosition, atBoundary granularity: EditorTextGranularity, inDirection direction: EditorTextDirection) -> Bool { false }
    func position(from position: EditorTextPosition, toBoundary granularity: EditorTextGranularity, inDirection direction: EditorTextDirection) -> EditorTextPosition? { nil }
}

@MainActor
protocol EditorTextInput: AnyObject {
    var selectedTextRange: EditorTextRange? { get set }
    var markedTextRange: EditorTextRange? { get }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get set }
    var beginningOfDocument: EditorTextPosition { get }
    var endOfDocument: EditorTextPosition { get }
    var hasText: Bool { get }
    var tokenizer: EditorTextInputTokenizer { get }
    func insertText(_ text: String)
    func deleteBackward()
    func setMarkedText(_ markedText: String?, selectedRange: NSRange)
    func unmarkText()
    func text(in range: EditorTextRange) -> String?
    func replace(_ range: EditorTextRange, withText text: String)
    func textRange(from: EditorTextPosition, to: EditorTextPosition) -> EditorTextRange?
    func position(from: EditorTextPosition, offset: Int) -> EditorTextPosition?
    func position(from: EditorTextPosition, in direction: EditorTextLayoutDirection, offset: Int) -> EditorTextPosition?
    func compare(_ position: EditorTextPosition, to other: EditorTextPosition) -> ComparisonResult
    func offset(from: EditorTextPosition, to toPosition: EditorTextPosition) -> Int
    func position(within range: EditorTextRange, farthestIn direction: EditorTextLayoutDirection) -> EditorTextPosition?
    func characterRange(byExtending position: EditorTextPosition, in direction: EditorTextLayoutDirection) -> EditorTextRange?
    func firstRect(for range: EditorTextRange) -> CGRect
    func caretRect(for position: EditorTextPosition) -> CGRect
    func selectionRects(for range: EditorTextRange) -> [EditorTextSelectionRect]
    func closestPosition(to point: CGPoint) -> EditorTextPosition?
    func closestPosition(to point: CGPoint, within range: EditorTextRange) -> EditorTextPosition?
    func characterRange(at point: CGPoint) -> EditorTextRange?
    func baseWritingDirection(for position: EditorTextPosition, in direction: EditorTextStorageDirection) -> NSWritingDirection
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: EditorTextRange)
    func beginFloatingCursor(at point: CGPoint)
    func updateFloatingCursor(at point: CGPoint)
    func endFloatingCursor()
}
