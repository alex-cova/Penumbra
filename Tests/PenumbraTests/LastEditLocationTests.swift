import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class LastEditLocationTests: XCTestCase {
    private func entry(line: Int, url: String = "a") -> NavigationEntry {
        NavigationEntry(url: URL(fileURLWithPath: "/tmp/\(url).java"), location: TextLocation(lineNumber: line, column: 0))
    }

    // MARK: - History

    func testNearbyEditsShareOneEntryWithTheNewestPosition() {
        let history = NavigationHistory()
        history.noteEdit(entry(line: 10))
        history.noteEdit(entry(line: 12))
        history.noteEdit(entry(line: 13))
        XCTAssertEqual(history.editEntries.map(\.location.lineNumber), [13])
    }

    func testDistantOrOtherDocumentEditsAddEntries() {
        let history = NavigationHistory()
        history.noteEdit(entry(line: 10))
        history.noteEdit(entry(line: 40))
        history.noteEdit(entry(line: 40, url: "b"))
        XCTAssertEqual(history.editEntries.count, 3)
    }

    func testEditEntriesAreBounded() {
        let history = NavigationHistory()
        history.editCapacity = 3
        for line in stride(from: 0, to: 100, by: 10) { history.noteEdit(entry(line: line)) }
        XCTAssertEqual(history.editEntries.map(\.location.lineNumber), [70, 80, 90])
    }

    func testLastEditLocationReturnsTheNewestThenStepsBack() {
        let history = NavigationHistory()
        history.noteEdit(entry(line: 10))
        history.noteEdit(entry(line: 50))
        history.noteEdit(entry(line: 90))

        // From somewhere else: the newest edit.
        XCTAssertEqual(history.lastEditLocation(from: entry(line: 0))?.location.lineNumber, 90)
        // Standing on it: the one before.
        XCTAssertEqual(history.lastEditLocation(from: entry(line: 90))?.location.lineNumber, 50)
        XCTAssertEqual(history.lastEditLocation(from: entry(line: 50))?.location.lineNumber, 10)
        // Nothing older: stays on the oldest.
        XCTAssertEqual(history.lastEditLocation(from: entry(line: 10))?.location.lineNumber, 10)
    }

    func testANewEditRestartsTheWalk() {
        let history = NavigationHistory()
        history.noteEdit(entry(line: 10))
        history.noteEdit(entry(line: 50))
        _ = history.lastEditLocation(from: entry(line: 50))
        history.noteEdit(entry(line: 90))
        XCTAssertEqual(history.lastEditLocation(from: entry(line: 0))?.location.lineNumber, 90)
    }

    func testEmptyHistoryHasNoLastEdit() {
        XCTAssertNil(NavigationHistory().lastEditLocation(from: entry(line: 0)))
    }

    func testForgetDropsAPlaceFromEveryStack() {
        let history = NavigationHistory()
        history.recordCheckpoint(entry(line: 10))
        history.recordCheckpoint(entry(line: 30))
        history.noteEdit(entry(line: 10))
        history.noteEdit(entry(line: 70))

        history.forget(url: URL(fileURLWithPath: "/tmp/a.java"), line: 10)

        XCTAssertEqual(history.backEntries.map(\.location.lineNumber), [30])
        XCTAssertEqual(history.editEntries.map(\.location.lineNumber), [70])
    }

    // MARK: - TextView

    func testTypingRecordsEditsAndTheActionJumpsBack() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        textView.text = (0..<60).map { "line \($0)" }.joined(separator: "\n")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("A")
        let farLocation = (textView.text as NSString).range(of: "line 40").location
        textView.selectedRange = NSRange(location: farLocation, length: 0)
        textView.insertText("B")
        textView.selectedRange = NSRange(location: 0, length: 0)

        XCTAssertTrue(textView.perform(.lastEditLocation))
        let first = textView.selectedRange.location
        XCTAssertEqual((textView.text as NSString).substring(with: NSRange(location: first - 1, length: 1)), "B")

        XCTAssertTrue(textView.perform(.lastEditLocation))
        XCTAssertEqual(textView.selectedRange.location, 1, "the second jump goes to the earlier edit")
    }

    func testJumpingLeavesABackStop() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        textView.text = (0..<60).map { "line \($0)" }.joined(separator: "\n")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("A")
        let farLocation = (textView.text as NSString).range(of: "line 50").location
        textView.selectedRange = NSRange(location: farLocation, length: 0)
        XCTAssertTrue(textView.perform(.lastEditLocation))
        XCTAssertEqual(textView.selectedRange.location, 1)
        XCTAssertTrue(textView.navigateBack())
        XCTAssertEqual(textView.selectedRange.location, farLocation)
    }
}

@MainActor
final class ChangeNavigationTests: XCTestCase {
    private func makeView() -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        textView.text = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        textView.setGutterChanges([
            GutterChange(line: 5, lineCount: 2, kind: .modified),
            GutterChange(line: 21, lineCount: 1, kind: .added)
        ])
        return textView
    }

    private func line(of textView: TextView) -> Int {
        textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? -1
    }

    func testNextChangeWalksTheChangesAndWraps() {
        let textView = makeView()
        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(textView.perform(.nextChange))
        XCTAssertEqual(line(of: textView), 4)
        XCTAssertTrue(textView.perform(.nextChange))
        XCTAssertEqual(line(of: textView), 20)
        XCTAssertTrue(textView.perform(.nextChange))
        XCTAssertEqual(line(of: textView), 4, "after the last change it wraps to the first")
    }

    func testPreviousChangeWalksBackAndWraps() {
        let textView = makeView()
        let middle = (textView.text as NSString).range(of: "line 12").location
        textView.selectedRange = NSRange(location: middle, length: 0)
        XCTAssertTrue(textView.perform(.previousChange))
        XCTAssertEqual(line(of: textView), 4)
        XCTAssertTrue(textView.perform(.previousChange))
        XCTAssertEqual(line(of: textView), 20, "before the first change it wraps to the last")
    }

    func testNoChangesMeansNoMove() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        textView.text = "a\nb"
        XCTAssertFalse(textView.perform(.nextChange))
        XCTAssertFalse(textView.perform(.previousChange))
    }
}
