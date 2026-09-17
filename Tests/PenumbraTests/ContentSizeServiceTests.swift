import XCTest
@testable import Penumbra

/// `removeLineWidths(exceptLinesWithID:)` (PERFORMANCE_AUDIT.md — the `ContentSizeService`
/// finding) evicts cached per-line widths for lines that aren't currently visible, so
/// `lineWidths` doesn't grow by one entry per line ever visited across a whole scroll session.
/// The one thing that fix must not break: `contentWidth` (driven by the widest line seen so far)
/// has to stay correct even when the widest line itself has scrolled out of view and gets evicted
/// from the visible set passed to this method.
final class ContentSizeServiceTests: XCTestCase {
    private func makeContentSizeService(text: String) -> (ContentSizeService, LineManager) {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.insert(text as NSString, at: 0)
        let gutterWidthService = GutterWidthService(lineManager: lineManager)
        let lineControllerFactory = LineControllerFactory(stringView: stringView,
                                                           highlightService: HighlightService(lineManager: lineManager),
                                                           invisibleCharacterConfiguration: InvisibleCharacterConfiguration())
        let lineControllerStorage = LineControllerStorage(stringView: stringView, lineControllerFactory: lineControllerFactory)
        let contentSizeService = ContentSizeService(lineManager: lineManager,
                                                     lineControllerStorage: lineControllerStorage,
                                                     gutterWidthService: gutterWidthService,
                                                     invisibleCharacterConfiguration: InvisibleCharacterConfiguration())
        contentSizeService.isLineWrappingEnabled = false
        contentSizeService.scrollViewWidth = 100
        return (contentSizeService, lineManager)
    }

    func testContentWidthReflectsWidestLineEvenAfterItScrollsOutOfViewAndIsEvicted() {
        let (service, lineManager) = makeContentSizeService(text: "a\nbb\nccc\ndddd\ne")
        // Line 3 ("dddd") is measured as the widest, then every line is measured so eviction has
        // something to actually release.
        for row in 0 ..< 5 {
            let line = lineManager.line(atRow: row)
            let width = CGFloat((row == 3) ? 400 : 40)
            service.setSize(of: line, to: CGSize(width: width, height: 20))
        }
        XCTAssertEqual(service.contentWidth, 400, accuracy: 0.01)

        // Simulate a memory-pressure eviction where only lines 0 and 1 are currently visible —
        // line 3 (the widest) is not, and must survive eviction anyway.
        let visibleIDs = Set([lineManager.line(atRow: 0).id, lineManager.line(atRow: 1).id])
        service.removeLineWidths(exceptLinesWithID: visibleIDs)

        XCTAssertEqual(service.contentWidth, 400, accuracy: 0.01, "the widest line's width must survive eviction")
    }

    func testRemoveLineWidthsIsSafeToCallWithNoMeasuredLines() {
        let (service, lineManager) = makeContentSizeService(text: "a\nb")
        let visibleIDs = Set([lineManager.line(atRow: 0).id])
        // Reaching the assertion below without crashing/hanging is the actual test — an empty
        // `lineWidths` dictionary shouldn't trip anything in the subtract-then-remove logic.
        service.removeLineWidths(exceptLinesWithID: visibleIDs)
        XCTAssertGreaterThanOrEqual(service.contentWidth, 0)
    }

    /// `removeLineWidths` always exempts the currently-tracked-longest line, regardless of what
    /// caller passes as the visible set — otherwise `setSize(of:to:)`'s "is this wider than the
    /// current max" comparison (which reads `lineWidths[lineIDTrackingWidth]`) would read a
    /// missing entry as 0 and incorrectly crown almost any subsequently-measured line as the new
    /// longest, even a narrower one.
    func testTrackedLongestLineSurvivesEvictionEvenWhenNotInTheExemptSet() {
        let (service, lineManager) = makeContentSizeService(text: "a\nbb\nccc")
        let line0 = lineManager.line(atRow: 0)
        let line1 = lineManager.line(atRow: 1)
        let line2 = lineManager.line(atRow: 2)
        service.setSize(of: line0, to: CGSize(width: 50, height: 20))
        service.setSize(of: line1, to: CGSize(width: 200, height: 20)) // becomes the tracked-longest
        XCTAssertEqual(service.contentWidth, 200, accuracy: 0.01)

        // line1 (the tracked-longest) is deliberately *not* in the exempt set.
        service.removeLineWidths(exceptLinesWithID: [line0.id])

        // A narrower line being (re-)measured must not be able to overtake line1's still-cached
        // width — if line1's entry had been evicted, this would incorrectly become the new max.
        service.setSize(of: line2, to: CGSize(width: 60, height: 20))
        XCTAssertEqual(service.contentWidth, 200, accuracy: 0.01)
    }

    /// `reset()` (called from `TextInputView.string`'s setter and `ContentSizeService`'s
    /// `lineManager` didSet) drops every cached per-line width, not just the derived totals
    /// `invalidateContentSize()` clears. After a wholesale line rebuild `DocumentLineNodeID`s
    /// are reissued, so a lingering `lineWidths` entry keyed by an old id would otherwise be
    /// read back as the width of an unrelated new line and inflate `contentWidth`.
    func testResetDropsCachedLineWidths() {
        let (service, lineManager) = makeContentSizeService(text: "aaaaaaaaaa\nb")
        service.setSize(of: lineManager.line(atRow: 0), to: CGSize(width: 500, height: 20))
        XCTAssertEqual(service.contentWidth, 500, accuracy: 0.01)

        service.reset()

        // With the cache cleared, width falls back to a real re-measurement of the longest line
        // (~10 glyphs), never the stale 500pt entry.
        XCTAssertLessThan(service.contentWidth, 500)
    }
}
