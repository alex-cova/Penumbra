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

    func testTheViewportIsLaidOutAgainWhenAFoldScanLands() async throws {
        let textView = makeTextView()
        collapseUnchanged(textView)
        try await waitForCollapsedFold(textView)
        // No click, no scroll: only the layout passes a view gets on its own.
        textView.layoutIfNeeded()
        let rows = textView.visibleRowsForTesting
        XCTAssertTrue(rows.contains(32), "the lines after the fold are laid out: \(rows)")
        XCTAssertTrue(rows.allSatisfy { !(3 ... 31).contains($0) }, "folded lines are not: \(rows)")
    }

    /// Folds lines 3 ..< 1850 of a 2000-line document, like a diff whose first change is near the end.
    private struct FoldsTheMiddle: FoldingProviding {
        let name = "middle"
        func foldRegions(for document: Document) async -> [FoldingDescriptor] {
            let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 1850 else { return [] }
            let start = lines[..<3].reduce(0) { $0 + $1.utf16.count + 1 }
            let end = lines[..<1850].reduce(0) { $0 + $1.utf16.count + 1 } - 1
            return [FoldDescriptorHelper.make(start: start, end: end)]
        }
    }

    private enum FoldDescriptorHelper {
        static func make(start: Int, end: Int) -> FoldingDescriptor {
            FoldingDescriptor(
                range: TextRange(start: TextPosition(line: 3, column: 0, utf16Offset: start),
                                 end: TextPosition(line: 1849, column: 0, utf16Offset: end)),
                placeholder: "1846 unchanged lines",
                collapsedByDefault: true
            )
        }
    }

    func testCenteringOnALateChangeBeforeTheFoldsLandStillShowsIt() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.text = (0 ..< 2000).map { "line \($0)" }.joined(separator: "\n")
        textView.layoutIfNeeded()
        // What the diff viewer does when a file opens: fold, then center the first change at once.
        textView.foldingProviderOverride = FoldsTheMiddle()
        textView.isLineFoldingEnabled = true
        let target = (textView.text as NSString).range(of: "line 1853").location
        textView.scrollRangeToCenter(NSRange(location: target, length: 0))
        try await waitForCollapsedFold(textView)
        // A host that waits for the scan to land centers again then.
        textView.scrollRangeToCenter(NSRange(location: target, length: 0))
        for _ in 0 ..< 5 { textView.layoutIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }

        let rows = textView.visibleRowsForTesting
        XCTAssertTrue(rows.contains(1853), "the change is laid out, rows: \(rows.prefix(12))")
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        XCTAssertLessThanOrEqual(textView.contentOffset.y, maxOffset + 1, "scrolled past the end of the folded text")
        let top = textView.yPosition(ofLine: 1854)
        XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y)
        XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height)
    }

    func testALandingScanAsksForALayoutPass() async throws {
        let textView = makeTextView()
        textView.foldingProviderOverride = Fixed()
        textView.isLineFoldingEnabled = true
        textView.layoutIfNeeded()   // starts the scan
        let deadline = Date().addingTimeInterval(3)
        while textView.collapsedFoldLineRangesForTesting.isEmpty {
            if Date() > deadline { return XCTFail("The fold was never scanned") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(textView.isFoldScanPending)
        XCTAssertTrue(textView.needsLayout, "nothing laid the folded lines out until a click")
    }
}
