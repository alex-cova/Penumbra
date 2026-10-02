import XCTest
import AppKit
import EditorIntelligence
@testable import Penumbra

@MainActor
final class LineBackgroundTests: XCTestCase {
    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 0.2)

    private func band(_ line: Int, _ count: Int) -> LineBackground {
        LineBackground(line: line, lineCount: count, color: green)
    }

    private func store(_ bands: [LineBackground]) -> LineBackgroundStore {
        let store = LineBackgroundStore()
        store.replace(with: bands)
        return store
    }

    // MARK: - Model

    func testReplaceSortsAndQueriesOnlyTheBandsInTheRows() {
        let bands = store([band(20, 2), band(2, 3), band(10, 0)])
        XCTAssertEqual(bands.bands.map(\.line), [2, 10, 20])
        // Rows 4...9 (lines 5...10): the band on lines 2-4 ends before, the rule at line 10 is in.
        XCTAssertEqual(bands.bands(intersectingRows: 4, 9).map(\.line), [10])
        XCTAssertEqual(bands.bands(intersectingRows: 0, 30).map(\.line), [2, 10, 20])
        XCTAssertEqual(bands.bands(intersectingRows: 3, 3).map(\.line), [2])
        XCTAssertTrue(bands.bands(intersectingRows: 22, 40).isEmpty)
    }

    func testABreakAboveShiftsBandsAndABreakInsideGrowsOne() {
        // Line break at the start of row 0: everything moves down a line.
        let above = store([band(2, 2), band(6, 0)])
        XCTAssertTrue(above.applyEdit(GutterLineMarkerEdit(startRow: 0, removedRows: 0, lineDelta: 1,
                                                           startsAtLineStart: true, endsAtLineStart: false,
                                                           isInsertion: true)))
        XCTAssertEqual(above.bands.map(\.line), [3, 7])
        XCTAssertEqual(above.bands.map(\.lineCount), [2, 0])
        // A break typed in the middle of row 2 (inside the band on rows 1-2) grows the band.
        let inside = store([band(2, 2), band(6, 0)])
        inside.applyEdit(GutterLineMarkerEdit(startRow: 2, removedRows: 0, lineDelta: 1,
                                              startsAtLineStart: false, endsAtLineStart: false, isInsertion: true))
        XCTAssertEqual(inside.bands.map(\.line), [2, 7])
        XCTAssertEqual(inside.bands.map(\.lineCount), [3, 0])
    }

    func testDeletingTheBandsLinesShrinksItToARule() {
        // Rows 1-2 deleted whole ("b\nc\n" in "a\nb\nc\nd").
        let bands = store([band(2, 2), band(5, 1)])
        bands.applyEdit(GutterLineMarkerEdit(startRow: 1, removedRows: 2, lineDelta: -2,
                                             startsAtLineStart: true, endsAtLineStart: true, isInsertion: false))
        XCTAssertEqual(bands.bands.map(\.line), [2, 3])
        XCTAssertEqual(bands.bands.map(\.lineCount), [1, 1])
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

    func testBandsFollowEditsAndAreClearedBySetState() {
        let textView = makeTextView("one\ntwo\nthree\nfour")
        textView.lineBackgrounds = [band(2, 1), band(4, 1)]
        textView.replace(NSRange(location: 0, length: 0), withText: "zero\n")
        XCTAssertEqual(textView.lineBackgrounds.map(\.line), [3, 5])
        // Typing without a line break moves nothing.
        textView.replace(NSRange(location: 0, length: 0), withText: "x")
        XCTAssertEqual(textView.lineBackgrounds.map(\.line), [3, 5])
        textView.setState(TextViewState(text: "fresh"))
        XCTAssertTrue(textView.lineBackgrounds.isEmpty)
    }

    func testLineGeometryRoundTrips() {
        let textView = makeTextView((1...50).map { "line \($0)" }.joined(separator: "\n"))
        let y10 = textView.yPosition(ofLine: 10)
        let y11 = textView.yPosition(ofLine: 11)
        XCTAssertGreaterThan(y11, y10)
        XCTAssertEqual(textView.line(atYPosition: y10 + 1), 10)
        XCTAssertEqual(textView.line(atYPosition: -100), 1)
        XCTAssertEqual(textView.line(atYPosition: 1_000_000), 50)
        XCTAssertGreaterThan(textView.yPosition(ofLine: 51), textView.yPosition(ofLine: 50))
    }

    func testFillsCoverTheBandsRows() {
        let textView = makeTextView("a\nb\nc\nd\ne")
        textView.lineBackgrounds = [band(2, 2), band(5, 0)]
        textView.layoutIfNeeded()
        let fills = textView.lineBackgroundFillsForTesting
        XCTAssertEqual(fills.count, 2)
        let top = textView.yPosition(ofLine: 2)
        let bottom = textView.yPosition(ofLine: 4)
        XCTAssertEqual(fills[0].frame.minY, top, accuracy: 0.5)
        XCTAssertEqual(fills[0].frame.height, bottom - top, accuracy: 0.5)
        XCTAssertEqual(fills[1].frame.height, LineBackgroundView.ruleThickness)
    }

    func testFoldingProviderOverrideReplacesTheLanguageFolds() async {
        struct Fixed: FoldingProviding {
            let name = "fixed"
            func foldRegions(for document: Document) async -> [FoldingDescriptor] {
                let text = document.text as NSString
                let start = text.range(of: "b").location
                let end = text.range(of: "d").location + 1
                return [FoldingDescriptor(
                    range: TextRange(start: TextPosition(line: 1, column: 0, utf16Offset: start),
                                     end: TextPosition(line: 3, column: 0, utf16Offset: end)),
                    placeholder: "3 unchanged lines",
                    collapsedByDefault: true
                )]
            }
        }
        let textView = makeTextView("a\nb\nc\nd\ne")
        textView.foldingProviderOverride = Fixed()
        textView.isLineFoldingEnabled = true
        await textView.updateFoldsForTesting()
        XCTAssertEqual(textView.foldLineRangesForTesting, [1 ... 3])
        XCTAssertEqual(textView.collapsedFoldLineRangesForTesting, [1 ... 3])
    }
}
