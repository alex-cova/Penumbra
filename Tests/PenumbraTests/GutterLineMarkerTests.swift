import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class GutterLineMarkerTests: XCTestCase {
    private func marker(_ id: Int, line: Int, _ icon: GutterLineMarkerIcon = .overriding) -> GutterLineMarker {
        GutterLineMarker(id: id, line: line, icon: icon, tooltip: "marker \(id)")
    }

    // MARK: - Model

    private func store(_ markers: [GutterLineMarker]) -> GutterLineMarkerStore {
        let store = GutterLineMarkerStore()
        store.replace(with: markers)
        return store
    }

    private func edit(startRow: Int, removedRows: Int = 0, lineDelta: Int, startsAtLineStart: Bool = false,
                      endsAtLineStart: Bool = false, isInsertion: Bool = false) -> GutterLineMarkerEdit {
        GutterLineMarkerEdit(startRow: startRow, removedRows: removedRows, lineDelta: lineDelta,
                             startsAtLineStart: startsAtLineStart, endsAtLineStart: endsAtLineStart,
                             isInsertion: isInsertion)
    }

    func testTypingAtALineStartKeepsItsMarkerWhileABreakMovesIt() {
        // "one\ntwo\n": typing "X" at the start of line 2 keeps its marker there.
        let typed = store([marker(0, line: 1), marker(1, line: 2)])
        typed.applyEdit(edit(startRow: 1, lineDelta: 0, startsAtLineStart: true, isInsertion: true))
        XCTAssertEqual(typed.markers.map(\.line), [1, 2])
        // A line break there pushes line 2 (and its marker) down.
        let broken = store([marker(0, line: 1), marker(1, line: 2)])
        XCTAssertTrue(broken.applyEdit(edit(startRow: 1, lineDelta: 1, startsAtLineStart: true, isInsertion: true)))
        XCTAssertEqual(broken.markers.map(\.line), [1, 3])
    }

    func testDeletingAWholeLineDropsItsMarkerAndIndentDeletionDoesNot() {
        // "one\n  two\nthree": delete "  two\n" (row 1 through the start of row 2).
        let wholeLine = store([marker(0, line: 2), marker(1, line: 3)])
        wholeLine.applyEdit(edit(startRow: 1, removedRows: 1, lineDelta: -1, startsAtLineStart: true, endsAtLineStart: true))
        XCTAssertEqual(wholeLine.markers.map(\.id), [1])
        XCTAssertEqual(wholeLine.markers.map(\.line), [2])
        // Deleting the indent "  " never reaches this model (no line break), and changes nothing.
        let indent = store([marker(0, line: 2), marker(1, line: 3)])
        XCTAssertFalse(indent.applyEdit(edit(startRow: 1, lineDelta: 0, startsAtLineStart: true)))
        XCTAssertEqual(indent.markers.map(\.line), [2, 3])
    }

    func testJoiningLinesMergesTheMarkersOntoOneLineAndWidensTheColumn() {
        // Backspace at the start of line 3 joins it onto line 2.
        let markers = store([marker(0, line: 2), marker(1, line: 3), marker(2, line: 9)])
        XCTAssertEqual(markers.slotCount, 1)
        markers.applyEdit(edit(startRow: 1, removedRows: 1, lineDelta: -1, endsAtLineStart: true))
        XCTAssertEqual(markers.markers.map(\.line), [2, 2, 8])
        XCTAssertEqual(markers.markers.map(\.id), [0, 1, 2])
        XCTAssertEqual(markers.slotCount, 2)
    }

    func testMultiLineDeletionDropsInnerLinesAndShiftsTheRest() {
        // Select from the middle of row 1 to the middle of row 4 and delete it.
        let markers = store([marker(0, line: 1), marker(1, line: 2), marker(2, line: 3), marker(3, line: 4),
                             marker(4, line: 5), marker(5, line: 7)])
        markers.applyEdit(edit(startRow: 1, removedRows: 3, lineDelta: -3))
        XCTAssertEqual(markers.markers.map(\.id), [0, 1, 4, 5])
        XCTAssertEqual(markers.markers.map(\.line), [1, 2, 2, 4])
    }

    func testReplacingABlockWithMoreLinesKeepsTheLastLineOnItsText() {
        // Replace "a\n" + "b\n" (rows 2-3, ending at row 4's start) with three lines.
        let markers = store([marker(0, line: 3), marker(1, line: 5), marker(2, line: 6)])
        markers.applyEdit(edit(startRow: 2, removedRows: 2, lineDelta: 1, startsAtLineStart: true, endsAtLineStart: true))
        XCTAssertEqual(markers.markers.map(\.id), [1, 2])
        XCTAssertEqual(markers.markers.map(\.line), [6, 7])
    }

    func testEditBelowEveryMarkerChangesNothing() {
        let markers = store([marker(0, line: 1), marker(1, line: 2)])
        XCTAssertFalse(markers.applyEdit(edit(startRow: 5, lineDelta: 1)))
    }

    func testReplaceSortsOnlyUnorderedMarkers() {
        let markers = store([marker(2, line: 5), marker(0, line: 1), marker(1, line: 5)])
        XCTAssertEqual(markers.markers.map(\.id), [0, 1, 2])
        XCTAssertEqual(markers.slotCount, 2)
    }

    func testSlotCountFollowsTheBusiestLineAndIsCapped() {
        XCTAssertEqual(GutterLineMarkerStore.slotCount(ofSorted: []), 0)
        XCTAssertEqual(GutterLineMarkerStore.slotCount(ofSorted: [marker(0, line: 1), marker(1, line: 2)]), 1)
        let crowded = [marker(0, line: 3), marker(1, line: 3), marker(2, line: 3)]
        XCTAssertEqual(GutterLineMarkerStore.slotCount(ofSorted: crowded), GutterLineMarkerView.maximumSlots)
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

    /// The column only covers the viewport, so a redraw never paints the whole document; hit
    /// testing still finds a marker far down after scrolling.
    func testMarkerViewCoversOnlyTheViewport() throws {
        let text = (1 ... 400).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeTextView(text)
        textView.setLineMarkers([marker(0, line: 300)])
        textView.layoutIfNeeded()
        let view = try XCTUnwrap(firstSubview(of: GutterLineMarkerView.self, in: textView))
        let lineManager = try XCTUnwrap(view.lineManager)
        let rowY = view.textContainerInsetTop + lineManager.yPosition(ofRow: 299)
        textView.contentOffset = CGPoint(x: 0, y: rowY - 100)
        textView.layoutIfNeeded()
        XCTAssertLessThanOrEqual(view.frame.height, textView.bounds.height + 1)
        XCTAssertEqual(view.frame.minY, textView.contentOffset.y, accuracy: 1)
        let local = CGPoint(x: GutterLineMarkerView.slotWidth / 2, y: rowY - view.frame.minY + view.rowHeight / 2)
        XCTAssertEqual(view.marker(at: local)?.marker.id, 0)
    }

    func testThousandsOfMarkersFollowAnEnterNearTheTop() {
        let text = (1 ... 5000).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeTextView(text)
        textView.setLineMarkers((1 ... 5000).map { marker($0, line: $0) })
        let second = (textView.text as NSString).range(of: "line 2\n")
        textView.replace(NSRange(location: second.location, length: 0), withText: "\n")
        XCTAssertEqual(textView.lineMarkers.count, 5000)
        XCTAssertEqual(textView.lineMarkers[0].line, 1)
        XCTAssertEqual(textView.lineMarkers[1].line, 3)
        XCTAssertEqual(textView.lineMarkers.last?.line, 5001)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// `setState` swaps the line manager; the marker view holds it weakly, so it must follow or
    /// it has no rows to draw (the markers were set but no icon ever appeared).
    func testMarkerViewFollowsTheLineManagerAcrossSetState() throws {
        let textView = makeTextView("")
        textView.setState(TextViewState(text: "one\ntwo\nthree", theme: DefaultTheme()))
        textView.setLineMarkers([marker(0, line: 2)])
        textView.layoutIfNeeded()
        let view = try XCTUnwrap(firstSubview(of: GutterLineMarkerView.self, in: textView))
        XCTAssertFalse(view.isHidden)
        let y = view.textContainerInsetTop + (view.lineManager?.yPosition(ofRow: 1) ?? -100) + view.rowHeight / 2
        XCTAssertEqual(view.marker(at: CGPoint(x: GutterLineMarkerView.slotWidth / 2, y: y))?.marker.id, 0)
    }

    /// The gutter container ignores the mouse except inside its interactive columns; a click on
    /// an icon there must reach the marker view rather than fall through to the text.
    func testClickOnAnIconReachesTheHandler() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = makeTextView("one\ntwo\nthree")
        window.contentView = textView
        var clicked: [Int] = []
        textView.lineMarkerHandler = { marker, _ in clicked.append(marker.id) }
        textView.setLineMarkers([marker(4, line: 2)])
        textView.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(firstSubview(of: GutterLineMarkerView.self, in: textView))
        let lineManager = try XCTUnwrap(view.lineManager)
        let local = CGPoint(x: GutterLineMarkerView.slotWidth / 2,
                            y: view.textContainerInsetTop + lineManager.yPosition(ofRow: 1) + view.rowHeight / 2)
        let inWindow = view.convert(local, to: nil)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = frameView.hitTest(frameView.convert(inWindow, from: nil))
        XCTAssertTrue(hit === view, "hit \(String(describing: hit))")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        hit?.mouseDown(with: event)
        XCTAssertEqual(clicked, [4])
    }
}
