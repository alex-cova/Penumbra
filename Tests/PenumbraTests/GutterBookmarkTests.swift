import XCTest
import AppKit
@testable import Penumbra

/// Bookmarks are a gutter layer of their own: drawn beside the host's decorations, moved by edits,
/// and clicked without disturbing the host's handlers.
@MainActor
final class GutterBookmarkTests: XCTestCase {
    private var window: NSWindow!

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeTextView(lineCount: Int = 8) -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = (1...lineCount).map { "line \($0)" }.joined(separator: "\n")
        window.contentView = textView
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    private func columnView(in textView: TextView) -> GutterDecorationView? {
        func find(_ view: NSView) -> GutterDecorationView? {
            for subview in view.subviews {
                if let match = subview as? GutterDecorationView ?? find(subview) { return match }
            }
            return nil
        }
        return find(textView)
    }

    func testBookmarksAreDrawnInTheDecorationColumnWithTheirMnemonic() throws {
        let textView = makeTextView()
        textView.setGutterBookmarks([
            GutterBookmark(id: "a", line: 2),
            GutterBookmark(id: "b", line: 5, mnemonic: "7", note: "retry loop")
        ])
        textView.layoutSubtreeIfNeeded()

        let decorations = try XCTUnwrap(columnView(in: textView)).decorations
        XCTAssertEqual(decorations.map(\.line), [2, 5])
        XCTAssertEqual(decorations.map(\.symbolName), ["bookmark.fill", "bookmark.fill"])
        XCTAssertNil(decorations[0].badgeSymbolName)
        XCTAssertEqual(decorations[1].badgeSymbolName, "7.circle.fill")
        XCTAssertEqual(decorations[1].accessibilityLabel, "Bookmark 7, retry loop")
    }

    func testBookmarksSurviveTheHostReplacingItsDecorations() throws {
        let textView = makeTextView()
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 3)])
        textView.setGutterDecorations([GutterDecoration(line: 4, symbolName: "play.fill", accessibilityLabel: "Run", placement: .lineMarkerColumn)])
        textView.setGutterDecorations([])
        textView.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.gutterBookmarks.map(\.line), [3])
        XCTAssertEqual(try XCTUnwrap(columnView(in: textView)).decorations.map(\.line), [3])
    }

    func testBookmarksFollowAnInsertedLineAndTheHostIsTold() {
        let textView = makeTextView()
        var told: [[Int]] = []
        textView.gutterBookmarksDidMove = { told.append($0.map(\.line)) }
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 3), GutterBookmark(id: "b", line: 6)])

        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("new\n")

        XCTAssertEqual(textView.gutterBookmarks.map(\.line), [4, 7])
        XCTAssertEqual(told, [[4, 7]])
    }

    func testABookmarkOnADeletedLineIsDropped() {
        let textView = makeTextView()
        var told: [[String]] = []
        textView.gutterBookmarksDidMove = { told.append($0.map(\.id)) }
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 2), GutterBookmark(id: "b", line: 4)])

        // Delete "line 2\n" (the second line, whole).
        let range = (textView.text as NSString).range(of: "line 2\n")
        textView.selectedRange = range
        textView.deleteBackward()

        XCTAssertEqual(textView.gutterBookmarks.map(\.id), ["b"])
        XCTAssertEqual(textView.gutterBookmarks.first?.line, 3)
        XCTAssertEqual(told.last, ["b"])
    }

    func testClickingABookmarkReachesItsHandlerNotTheHosts() throws {
        let textView = makeTextView()
        var bookmarkClicks: [String] = []
        var hostClicks: [Int] = []
        textView.gutterBookmarkHandler = { bookmarkClicks.append($0.id) }
        textView.gutterDecorationHandler = { hostClicks.append($0) }
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 3)])
        textView.setGutterDecorations([GutterDecoration(line: 5, symbolName: "circle", accessibilityLabel: "Host icon")])
        textView.layoutSubtreeIfNeeded()

        let column = try XCTUnwrap(columnView(in: textView))
        column.onLineClicked?(3)
        column.onLineClicked?(5)

        XCTAssertEqual(bookmarkClicks, ["a"])
        XCTAssertEqual(hostClicks, [5])
    }

    func testAHostIconOnTheSameLineKeepsTheClick() throws {
        let textView = makeTextView()
        var bookmarkClicks = 0
        var hostClicks: [Int] = []
        textView.gutterBookmarkHandler = { _ in bookmarkClicks += 1 }
        textView.gutterDecorationHandler = { hostClicks.append($0) }
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 3)])
        textView.setGutterDecorations([GutterDecoration(line: 3, symbolName: "circle", accessibilityLabel: "Host icon")])
        textView.layoutSubtreeIfNeeded()

        try XCTUnwrap(columnView(in: textView)).onLineClicked?(3)

        XCTAssertEqual(bookmarkClicks, 0)
        XCTAssertEqual(hostClicks, [3])
    }

    func testRunButtonClicksStayWithTheHost() throws {
        let textView = makeTextView()
        var hostClicks: [Int] = []
        textView.gutterBookmarkHandler = { _ in XCTFail("a run button is not a bookmark") }
        textView.gutterDecorationHandler = { hostClicks.append($0) }
        textView.setGutterBookmarks([GutterBookmark(id: "a", line: 3)])
        textView.layoutSubtreeIfNeeded()

        func find(_ view: NSView) -> GutterLineMarkerView? {
            for subview in view.subviews {
                if let match = subview as? GutterLineMarkerView ?? find(subview) { return match }
            }
            return nil
        }
        let markers = try XCTUnwrap(find(textView))
        markers.onDecorationClicked?(3)
        XCTAssertEqual(hostClicks, [3])
    }
}
