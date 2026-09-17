import AppKit
@testable import Penumbra

final class MockTextInput: NSResponder, UITextInput {
    var selectedTextRange: UITextRange?
    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    var beginningOfDocument: UITextPosition { IndexedPosition(index: 0) }
    var endOfDocument: UITextPosition { IndexedPosition(index: 0) }
    var inputDelegate: UITextInputDelegate?
    var hasText: Bool { false }
    var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

    func insertText(_ text: String) {}
    func deleteBackward() {}
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}
    func text(in range: UITextRange) -> String? { nil }
    func replace(_ range: UITextRange, withText text: String) {}
    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? { nil }
    func position(from: UITextPosition, offset: Int) -> UITextPosition? { nil }
    func position(from: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? { nil }
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult { .orderedSame }
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int { 0 }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { nil }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { nil }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func beginFloatingCursor(at point: CGPoint) {}
    func updateFloatingCursor(at point: CGPoint) {}
    func endFloatingCursor() {}
}
