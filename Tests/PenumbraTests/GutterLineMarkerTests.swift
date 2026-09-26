import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class GutterLineMarkerTests: XCTestCase {
    private func marker(_ id: Int, line: Int, _ icon: GutterLineMarkerIcon = .overriding) -> GutterLineMarker {
        GutterLineMarker(id: id, line: line, icon: icon, tooltip: "marker \(id)")
    }

    // MARK: - Model

    /// The row of an offset in `text`: a stand-in for the line manager in the model tests.
    private func rows(_ text: String) -> (Int) -> Int {
        let ns = text as NSString
        return { offset in
            var row = 0
            for index in 0..<min(offset, ns.length) where ns.character(at: index) == 10 { row += 1 }
            return row
        }
    }

    func testTypingAtALineStartKeepsItsMarkerWhileABreakMovesIt() {
        // "one\ntwo\n": line 2 starts at 4.
        let markers = [marker(0, line: 1), marker(1, line: 2)]
        let typed = GutterLineMarkerIndex.applyingEdit(
            to: markers, lineStarts: [0, 4], range: NSRange(location: 4, length: 0), deletedText: "",
            replacementLength: 1, row: rows("one\nXtwo\n")
        )
        XCTAssertEqual(typed.map(\.line), [1, 2])
        let broken = GutterLineMarkerIndex.applyingEdit(
            to: markers, lineStarts: [0, 4], range: NSRange(location: 4, length: 0), deletedText: "",
            replacementLength: 1, row: rows("one\n\ntwo\n")
        )
        XCTAssertEqual(broken.map(\.line), [1, 3])
    }

    func testDeletingAWholeLineDropsItsMarkerAndIndentDeletionDoesNot() {
        // "one\n  two\nthree": lines start at 0, 4, 10.
        let markers = [marker(0, line: 2), marker(1, line: 3)]
        let wholeLine = GutterLineMarkerIndex.applyingEdit(
            to: markers, lineStarts: [4, 10], range: NSRange(location: 4, length: 6), deletedText: "  two\n",
            replacementLength: 0, row: rows("one\nthree")
        )
        XCTAssertEqual(wholeLine.map(\.id), [1])
        XCTAssertEqual(wholeLine.map(\.line), [2])
        let indent = GutterLineMarkerIndex.applyingEdit(
            to: markers, lineStarts: [4, 10], range: NSRange(location: 4, length: 2), deletedText: "  ",
            replacementLength: 0, row: rows("one\ntwo\nthree")
        )
        XCTAssertEqual(indent.map(\.line), [2, 3])
    }

    func testSlotCountFollowsTheBusiestLineAndIsCapped() {
        XCTAssertEqual(GutterLineMarkerIndex.slotCount(of: []), 0)
        XCTAssertEqual(GutterLineMarkerIndex.slotCount(of: [marker(0, line: 1), marker(1, line: 2)]), 1)
        let crowded = [marker(0, line: 3), marker(1, line: 3), marker(2, line: 3)]
        XCTAssertEqual(GutterLineMarkerIndex.slotCount(of: crowded), GutterLineMarkerView.maximumSlots)
    }

    // MARK: - View

    func testHitTestingFindsEachIconOnALine() throws {
        let text = "a\nb\nc\n"
        let lineManager = LineManager(stringView: StringView(string: text))
        lineManager.insert(text as NSString, at: 0)
        let view = GutterLineMarkerView(frame: CGRect(x: 0, y: 0, width: 28, height: 200))
        view.lineManager = lineManager
        view.rowHeight = lineManager.lineInfo(atRow: 0).lineHeight
        view.markers = [marker(7, line: 2, .overridden), marker(8, line: 2, .overriding), marker(9, line: 3, .recursiveCall)]

        let lineTwoY = lineManager.yPosition(ofRow: 1) + view.rowHeight / 2
        let first = try XCTUnwrap(view.marker(at: CGPoint(x: GutterLineMarkerView.slotWidth / 2, y: lineTwoY)))
        XCTAssertEqual(first.marker.id, 7)
        let second = try XCTUnwrap(view.marker(at: CGPoint(x: GutterLineMarkerView.slotWidth * 1.5, y: lineTwoY)))
        XCTAssertEqual(second.marker.id, 8)
        XCTAssertGreaterThan(second.rect.minX, first.rect.minX)
        let lineOneY = lineManager.yPosition(ofRow: 0) + view.rowHeight / 2
        XCTAssertNil(view.marker(at: CGPoint(x: GutterLineMarkerView.slotWidth / 2, y: lineOneY)))
    }

    // MARK: - Text view

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        textView.layoutIfNeeded()
        return textView
    }

    func testMarkersWidenTheGutterOnlyWhilePresent() {
        let textView = makeTextView("one\ntwo\nthree")
        let plain = textView.gutterWidth
        textView.setLineMarkers([marker(0, line: 1)])
        XCTAssertEqual(textView.gutterWidth, plain + GutterLineMarkerView.slotWidth, accuracy: 0.5)
        textView.setLineMarkers([marker(0, line: 1), marker(1, line: 1)])
        XCTAssertEqual(textView.gutterWidth, plain + GutterLineMarkerView.slotWidth * 2, accuracy: 0.5)
        textView.setLineMarkers([])
        XCTAssertEqual(textView.gutterWidth, plain, accuracy: 0.5)
    }

    func testMarkersFollowLinesThroughEdits() {
        let textView = makeTextView("one\ntwo\nthree")
        textView.setLineMarkers([marker(0, line: 1), marker(1, line: 3)])
        textView.replace(NSRange(location: 0, length: 0), withText: "zero\n")
        XCTAssertEqual(textView.lineMarkers.map(\.line), [2, 4])
        // Delete "two\n" (now line 3): "three" and its marker move up.
        let two = (textView.text as NSString).range(of: "two\n")
        textView.replace(two, withText: "")
        XCTAssertEqual(textView.lineMarkers.map(\.line), [2, 3])
        // Delete the line holding the first marker.
        let one = (textView.text as NSString).range(of: "one\n")
        textView.replace(one, withText: "")
        XCTAssertEqual(textView.lineMarkers.map(\.id), [1])
        XCTAssertEqual(textView.lineMarkers.map(\.line), [2])
    }
}
