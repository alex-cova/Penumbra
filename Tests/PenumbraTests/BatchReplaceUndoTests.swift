import XCTest
@testable import Penumbra

/// Exercises `TextView.replaceText(in:)` (batch/"Replace All") undo/redo through the real
/// `NSUndoManager`, backed by the delta-based inverse computed in `TextEditHelper.apply(_:)`
/// instead of a full-document snapshot. See PERFORMANCE_AUDIT.md Phase 2 #7.
final class BatchReplaceUndoTests: XCTestCase {
    private func makeTextView(text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        return textView
    }

    func testUndoRestoresOriginalTextAfterBatchReplace() {
        let textView = makeTextView(text: "aaa bbb aaa")
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "X"),
            .init(range: NSRange(location: 8, length: 3), text: "YY")
        ])
        textView.replaceText(in: batch)
        XCTAssertEqual(textView.text, "X bbb YY")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "aaa bbb aaa")
    }

    func testRedoReappliesTheBatchReplaceAfterUndo() {
        let textView = makeTextView(text: "aaa bbb aaa")
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "X"),
            .init(range: NSRange(location: 8, length: 3), text: "YY")
        ])
        textView.replaceText(in: batch)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "aaa bbb aaa")

        textView.undoManager?.redo()
        XCTAssertEqual(textView.text, "X bbb YY")
    }

    func testRepeatedUndoRedoRoundTripsCleanly() {
        let textView = makeTextView(text: "one two three")
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "1"),
            .init(range: NSRange(location: 8, length: 5), text: "3333")
        ])
        textView.replaceText(in: batch)
        let replaced = textView.text
        for _ in 0 ..< 3 {
            textView.undoManager?.undo()
            XCTAssertEqual(textView.text, "one two three")
            textView.undoManager?.redo()
            XCTAssertEqual(textView.text, replaced)
        }
    }

    /// A stress-shaped case: many small replacements across a longer document, to catch any
    /// cumulative-offset bug in the inverse computation that a two-replacement test might miss.
    func testUndoRestoresOriginalTextWithManyReplacements() {
        let words = (0 ..< 50).map { "word\($0)" }
        let original = words.joined(separator: " ")
        let textView = makeTextView(text: original)

        var replacements: [BatchReplaceSet.Replacement] = []
        var searchStart = original.startIndex
        for i in stride(from: 0, to: 50, by: 5) {
            let target = "word\(i)"
            guard let range = original.range(of: target, range: searchStart..<original.endIndex) else { continue }
            let nsRange = NSRange(range, in: original)
            replacements.append(.init(range: nsRange, text: "REPLACED\(i)"))
            searchStart = range.upperBound
        }
        textView.replaceText(in: BatchReplaceSet(replacements: replacements))
        XCTAssertNotEqual(textView.text, original)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, original)
    }
}
