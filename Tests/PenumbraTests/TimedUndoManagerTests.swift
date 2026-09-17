import XCTest
@testable import Penumbra

final class TimedUndoManagerTests: XCTestCase {
    private func makeTextView(text: String = "") -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        return textView
    }

    private func insertIsolated(_ textView: TextView, _ text: String) {
        let end = (textView.text as NSString).length
        textView.replace(NSRange(location: end, length: 0), withText: text)
        textView.undoManager?.endUndoGrouping()
    }

    func testFourthIsolatedEditDropsTheOldestGroupWhenCappedAtThree() {
        let textView = makeTextView()
        let undo = textView.undoManager as! TimedUndoManager
        undo.maxUndoGroups = 3

        insertIsolated(textView, "a")
        insertIsolated(textView, "b")
        insertIsolated(textView, "c")
        insertIsolated(textView, "d")
        XCTAssertEqual(textView.text, "abcd")

        undo.undo()
        undo.undo()
        undo.undo()
        XCTAssertEqual(textView.text, "a")
        XCTAssertFalse(undo.canUndo, "the first edit should have been discarded")
    }

    func testByteCapDropsOldestGroup() {
        let textView = makeTextView()
        let undo = textView.undoManager as! TimedUndoManager
        undo.maxUndoGroups = 100
        undo.maxUndoBytes = 2_500

        insertIsolated(textView, String(repeating: "x", count: 1_000))
        insertIsolated(textView, String(repeating: "y", count: 1_000))
        insertIsolated(textView, String(repeating: "z", count: 1_000))

        undo.undo()
        undo.undo()
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(textView.text.contains("x"))
    }

    func testRemoveAllActionsClearsTheUndoStack() {
        let textView = makeTextView()
        insertIsolated(textView, "hello")
        XCTAssertTrue(textView.undoManager?.canUndo ?? false)
        textView.undoManager?.removeAllActions()
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
    }
}
