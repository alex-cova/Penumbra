import AppKit
import XCTest
@testable import Penumbra

/// F20: ordinary commands read a file-backed (piece-tree) buffer through ranged snapshots; none
/// of them copies it into one string on the main thread. `pieceTreeMaterializeCount` is the probe.
@MainActor
final class DocumentMaterializationTests: XCTestCase {
    /// Past the 256K-unit piece-tree threshold, with `needle` scattered and one at the very end.
    private func makeLargeText() -> String {
        let filler = String(repeating: "value = compute(items) // padding padding padding\n", count: 6_000)
        var text = filler + "needle one\n"
        text += String(repeating: "x", count: 70_000) + " needle two\n"
        text += filler + "needle three é🙂 needle"
        return text
    }

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        textView.text = text
        return textView
    }

    private func probeSeesACopy(_ textView: TextView, _ before: Int) {
        _ = textView.text
        XCTAssertGreaterThan(textView.pieceTreeMaterializeCount, before, "the probe must see a main-thread copy")
    }

    // MARK: - Occurrence selection

    func testOccurrenceCommandsDoNotMaterializeAPieceTreeBuffer() {
        let text = makeLargeText()
        let textView = makeTextView(text)
        XCTAssertNotNil(textView.pieceTreeContentSnapshot(), "the test needs a piece-tree buffer")
        let ns = text as NSString
        let first = ns.range(of: "needle")
        textView.selectedRange = first
        let before = textView.pieceTreeMaterializeCount

        textView.selectNextOccurrence()
        textView.selectNextOccurrence()
        textView.skipCurrentOccurrence()
        let afterSkip = textView.selectedRanges
        textView.selectAllOccurrences()

        XCTAssertEqual(textView.pieceTreeMaterializeCount, before, "an occurrence command copied the buffer")
        let expectedAll = SelectNextOccurrence.allMatches(for: "needle", in: ns)
        XCTAssertEqual(textView.selectedRanges, expectedAll, "select all equals the NSString scan")
        XCTAssertEqual(expectedAll.count, 4)
        XCTAssertEqual(afterSkip.count, 3, "skip replaced the last occurrence instead of adding")
        XCTAssertEqual(afterSkip.first, first)
        probeSeesACopy(textView, before)
    }

    /// The windowed scan finds what the whole-string scan finds, including matches across a window
    /// cut and ones holding surrogate pairs and composed characters.
    func testSourceSearchEqualsTheStringSearchAcrossWindowCuts() {
        let unit = "ab é🙂 café needle🙂x 🙂needle needleneedle\n"
        let text = String(repeating: unit, count: 40)
        let ns = text as NSString
        for window in [7, 16, 33, 64, 101] {
            FindSearchEngine.debugLiteralWindowUTF16 = window
            defer { FindSearchEngine.debugLiteralWindowUTF16 = nil }
            for query in ["needle", "🙂", "é", "needleneedle", "café"] {
                let source = WindowedSource(text)
                XCTAssertEqual(
                    SelectNextOccurrence.allMatches(for: query, in: source),
                    SelectNextOccurrence.allMatches(for: query, in: ns),
                    "all matches of \(query) with window \(window)"
                )
                let length = (query as NSString).length
                for after in stride(from: 0, to: ns.length, by: 37) {
                    XCTAssertEqual(
                        SelectNextOccurrence.nextMatch(for: query, length: length, in: source, after: after),
                        SelectNextOccurrence.nextMatch(for: query, length: length, in: ns, after: after),
                        "next \(query) after \(after) with window \(window)"
                    )
                }
            }
        }
    }

    // MARK: - Palette in-buffer text

    func testBufferTextMatchesAreCappedOrderedAndDoNotMaterialize() async {
        let text = makeLargeText()
        let textView = makeTextView(text)
        XCTAssertNotNil(textView.pieceTreeContentSnapshot())
        let before = textView.pieceTreeMaterializeCount

        let matches = await textView.bufferTextMatches(for: "NEEDLE", limit: 3)

        XCTAssertEqual(textView.pieceTreeMaterializeCount, before, "the palette search copied the buffer")
        XCTAssertEqual(matches.count, 3, "stops at the limit")
        let legacy = textView.search(for: SearchQuery(text: "NEEDLE", matchMethod: .contains, isCaseSensitive: false))
        XCTAssertEqual(matches.map(\.range), legacy.prefix(3).map(\.range), "same hits, same order as the legacy search")
        XCTAssertEqual(matches.map(\.lineNumber), legacy.prefix(3).map(\.startLocation.lineNumber))
        XCTAssertEqual(matches[0].preview, "needle one")
        XCTAssertEqual(matches[1].preview.hasSuffix("needle two"), true)
        probeSeesACopy(textView, before)
    }

    func testBufferTextPreviewIsBoundedOnAHugeLine() async {
        let line = String(repeating: "a", count: 400_000) + "needle" + String(repeating: "b", count: 400_000)
        let textView = makeTextView(line)
        let matches = await textView.bufferTextMatches(for: "needle", limit: 5)
        XCTAssertEqual(matches.count, 1)
        XCTAssertLessThanOrEqual(matches[0].preview.utf16.count, 806)
        XCTAssertTrue(matches[0].preview.contains("needle"))
    }

    // MARK: - Folding

    func testAFoldUpdateDoesNotMaterializeThePieceTreeOnTheMainThread() async throws {
        let text = String(repeating: "func f() {\n    let x = 1\n}\n", count: 12_000)
        let textView = makeTextView(text)
        XCTAssertNotNil(textView.pieceTreeContentSnapshot())
        textView.isLineFoldingEnabled = true
        try await Task.sleep(nanoseconds: 800_000_000)
        let before = textView.pieceTreeMaterializeCount

        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("// edit\n")
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(textView.pieceTreeMaterializeCount, before, "a fold update copied the buffer on the main thread")
        probeSeesACopy(textView, before)
    }
}

/// A source with no contiguous string, so the engine walks it in windows.
private struct WindowedSource: FindTextSource {
    let text: String
    init(_ text: String) { self.text = text }
    var utf16Length: Int { text.utf16.count }
    func substring(utf16Offset: Int, length: Int) -> String {
        let string = text as NSString
        let location = max(0, min(utf16Offset, string.length))
        return string.substring(with: NSRange(location: location, length: max(0, min(length, string.length - location))))
    }
}
