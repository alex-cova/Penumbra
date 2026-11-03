import XCTest
import AppKit
import EditorIntelligence
@testable import Penumbra

/// Turning folding off and on again on a live view (Umbra's diff viewer does it for "Collapse
/// Unchanged Fragments"): the content height follows the folds, and a fold provider set while
/// folding is off is scanned when it is turned on.
@MainActor
final class FoldingToggleTests: XCTestCase {
    /// Folds lines 2...31 of the document.
    private struct Fixed: FoldingProviding {
        let name = "fixed"
        func foldRegions(for document: Document) async -> [FoldingDescriptor] {
            let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 31 else { return [] }
            let start = lines[..<2].reduce(0) { $0 + $1.utf16.count + 1 }
            let end = lines[..<32].reduce(0) { $0 + $1.utf16.count + 1 } - 1
            return [FoldingDescriptor(
                range: TextRange(start: TextPosition(line: 2, column: 0, utf16Offset: start),
                                 end: TextPosition(line: 31, column: 0, utf16Offset: end)),
                placeholder: "30 unchanged lines",
                collapsedByDefault: true
            )]
        }
    }

    private func makeTextView() -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.text = (0 ..< 40).map { "line \($0)" }.joined(separator: "\n")
        textView.layoutIfNeeded()
        return textView
    }

    private func collapseUnchanged(_ textView: TextView) {
        textView.foldingProviderOverride = Fixed()
        textView.isLineFoldingEnabled = true
    }

    private func waitForCollapsedFold(_ textView: TextView) async throws {
        let deadline = Date().addingTimeInterval(3)
        while textView.collapsedFoldLineRangesForTesting.isEmpty {
            textView.layoutIfNeeded()
            if Date() > deadline { return XCTFail("The fold was never scanned") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testAProviderSetWhileFoldingIsOffIsScannedWhenFoldingIsTurnedOn() async throws {
        let textView = makeTextView()
        collapseUnchanged(textView)
        try await waitForCollapsedFold(textView)
        XCTAssertEqual(textView.collapsedFoldLineRangesForTesting, [2 ... 31])
    }

    func testTurningFoldingOffRestoresTheContentHeightAndOnFoldsAgain() async throws {
        let textView = makeTextView()
        let fullHeight = textView.textContentHeightForTesting
        collapseUnchanged(textView)
        try await waitForCollapsedFold(textView)
        let foldedHeight = textView.textContentHeightForTesting
        XCTAssertLessThan(foldedHeight, fullHeight)

        textView.foldingProviderOverride = nil
        textView.isLineFoldingEnabled = false
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.textContentHeightForTesting, fullHeight, accuracy: 0.5,
                       "the content is as tall as before folding, so it scrolls to the end")
        XCTAssertTrue(textView.collapsedFoldLineRangesForTesting.isEmpty)

        collapseUnchanged(textView)
        try await waitForCollapsedFold(textView)
        XCTAssertEqual(textView.textContentHeightForTesting, foldedHeight, accuracy: 0.5)
    }

    func testFoldObserversHearTheScanThatMovesTheLines() async throws {
        let textView = makeTextView()
        var heightsAtEvents: [CGFloat] = []
        textView.addFoldObserver { heightsAtEvents.append(textView.textContentHeightForTesting) }
        let fullHeight = textView.textContentHeightForTesting
        collapseUnchanged(textView)
        try await waitForCollapsedFold(textView)
        XCTAssertLessThan(try XCTUnwrap(heightsAtEvents.last), fullHeight,
                          "the last event came after the lines were folded, so an overlay can redraw")
    }
}
