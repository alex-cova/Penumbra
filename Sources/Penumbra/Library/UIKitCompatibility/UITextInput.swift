@preconcurrency import AppKit
import Foundation

public class UITextPosition: NSObject, @unchecked Sendable {}
open class UITextRange: NSObject {
    @objc open var start: UITextPosition { fatalError("override") }
    @objc open var end: UITextPosition { fatalError("override") }
    @objc open var isEmpty: Bool { fatalError("override") }
}
open class UITextSelectionRect: NSObject {
    @objc open var rect: CGRect { .zero }
    @objc open var writingDirection: NSWritingDirection { .leftToRight }
    @objc open var containsStart: Bool { false }
    @objc open var containsEnd: Bool { false }
    @objc open var isVertical: Bool { false }
}

public protocol UITextInputTokenizer: NSObjectProtocol {
    func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool
    func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition?
}

open class UITextInputStringTokenizer: NSObject, UITextInputTokenizer {
    public weak var textInput: (UIResponder & UITextInput)?
    public init(textInput: UIResponder & UITextInput) { self.textInput = textInput; super.init() }
    open func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool { false }
    open func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition? { nil }
}

@MainActor
public protocol UITextInputDelegate: NSObjectProtocol {
    func selectionWillChange(_ textInput: UITextInput?)
    func selectionDidChange(_ textInput: UITextInput?)
    func textWillChange(_ textInput: UITextInput?)
    func textDidChange(_ textInput: UITextInput?)
}

@MainActor
public protocol UITextInput: AnyObject {
    var selectedTextRange: UITextRange? { get set }
    var markedTextRange: UITextRange? { get }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get set }
    var beginningOfDocument: UITextPosition { get }
    var endOfDocument: UITextPosition { get }
    var inputDelegate: UITextInputDelegate? { get set }
    var hasText: Bool { get }
    var tokenizer: UITextInputTokenizer { get }
    func insertText(_ text: String)
    func deleteBackward()
    func setMarkedText(_ markedText: String?, selectedRange: NSRange)
    func unmarkText()
    func text(in range: UITextRange) -> String?
    func replace(_ range: UITextRange, withText text: String)
    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange?
    func position(from: UITextPosition, offset: Int) -> UITextPosition?
    func position(from: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition?
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition?
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange?
    func firstRect(for range: UITextRange) -> CGRect
    func caretRect(for position: UITextPosition) -> CGRect
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect]
    func closestPosition(to point: CGPoint) -> UITextPosition?
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition?
    func characterRange(at point: CGPoint) -> UITextRange?
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange)
    func beginFloatingCursor(at point: CGPoint)
    func updateFloatingCursor(at point: CGPoint)
    func endFloatingCursor()
}
