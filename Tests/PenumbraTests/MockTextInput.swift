import AppKit
@testable import Penumbra

final class MockTextInput: NSResponder, EditorTextInput {
    var selectedTextRange: EditorTextRange?
    var markedTextRange: EditorTextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    var beginningOfDocument: EditorTextPosition { IndexedPosition(index: 0) }
    var endOfDocument: EditorTextPosition { IndexedPosition(index: 0) }
    var hasText: Bool { false }
    var tokenizer: EditorTextInputTokenizer { EditorTextInputStringTokenizer(textInput: self) }

    func insertText(_ text: String) {}
    func deleteBackward() {}
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}
    func text(in range: EditorTextRange) -> String? { nil }
    func replace(_ range: EditorTextRange, withText text: String) {}
    func textRange(from: EditorTextPosition, to: EditorTextPosition) -> EditorTextRange? { nil }
    func position(from: EditorTextPosition, offset: Int) -> EditorTextPosition? { nil }
    func position(from: EditorTextPosition, in direction: EditorTextLayoutDirection, offset: Int) -> EditorTextPosition? { nil }
    func compare(_ position: EditorTextPosition, to other: EditorTextPosition) -> ComparisonResult { .orderedSame }
    func offset(from: EditorTextPosition, to toPosition: EditorTextPosition) -> Int { 0 }
    func position(within range: EditorTextRange, farthestIn direction: EditorTextLayoutDirection) -> EditorTextPosition? { nil }
    func characterRange(byExtending position: EditorTextPosition, in direction: EditorTextLayoutDirection) -> EditorTextRange? { nil }
    func firstRect(for range: EditorTextRange) -> CGRect { .zero }
    func caretRect(for position: EditorTextPosition) -> CGRect { .zero }
    func selectionRects(for range: EditorTextRange) -> [EditorTextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> EditorTextPosition? { nil }
    func closestPosition(to point: CGPoint, within range: EditorTextRange) -> EditorTextPosition? { nil }
    func characterRange(at point: CGPoint) -> EditorTextRange? { nil }
    func baseWritingDirection(for position: EditorTextPosition, in direction: EditorTextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: EditorTextRange) {}
    func beginFloatingCursor(at point: CGPoint) {}
    func updateFloatingCursor(at point: CGPoint) {}
    func endFloatingCursor() {}
}
