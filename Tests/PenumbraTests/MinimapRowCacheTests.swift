@testable import Penumbra
import XCTest

/// `MinimapRowCache` keeps built rows per line, drops everything when an invalidation input
/// changes, drops single lines on request, evicts anything not visited in a frame, and can
/// selectively drop the provisional (uncolored) rows drawn while syntax was still parsing.
final class MinimapRowCacheTests: XCTestCase {
    private func id(_ value: UInt32) -> DocumentLineNodeID {
        DocumentLineNodeID(value: value)
    }

    private func row(_ x: CGFloat) -> MinimapRow {
        MinimapRow(segments: [MinimapSegment(x: x, width: 1, colorIndex: 0, fadeStep: 0)])
    }

    private func begin(_ cache: MinimapRowCache,
                       documentEpoch: UInt64 = 1,
                       themeGeneration: UInt64 = 1,
                       maxColumns: Int = 80,
                       tabLength: Int = 4) {
        cache.beginFrame(documentEpoch: documentEpoch,
                         themeGeneration: themeGeneration,
                         maxColumns: maxColumns,
                         tabLength: tabLength)
    }

    func testStoresAndReturnsRows() {
        let cache = MinimapRowCache()
        begin(cache)
        cache.store(row(1), for: id(1), provisional: false)
        XCTAssertEqual(cache.cachedRow(for: id(1)), row(1))
        XCTAssertNil(cache.cachedRow(for: id(2)))
    }

    func testDocumentEpochBumpClearsEverything() {
        let cache = MinimapRowCache()
        begin(cache, documentEpoch: 1)
        cache.store(row(1), for: id(1), provisional: false)
        cache.endFrame()

        begin(cache, documentEpoch: 2)
        XCTAssertNil(cache.cachedRow(for: id(1)))
    }

    func testRemoveDropsOnlyTheGivenLines() {
        let cache = MinimapRowCache()
        begin(cache)
        cache.store(row(1), for: id(1), provisional: false)
        cache.store(row(2), for: id(2), provisional: true)
        cache.endFrame()

        begin(cache)
        cache.remove([id(2)])
        XCTAssertEqual(cache.cachedRow(for: id(1)), row(1))
        XCTAssertNil(cache.cachedRow(for: id(2)))
        XCTAssertFalse(cache.isProvisional(id(2)))
    }

    func testThemeGenerationBumpClearsEverything() {
        let cache = MinimapRowCache()
        begin(cache, themeGeneration: 1)
        cache.store(row(1), for: id(1), provisional: false)
        cache.endFrame()

        begin(cache, themeGeneration: 2)
        XCTAssertNil(cache.cachedRow(for: id(1)))
    }

    func testColumnBudgetChangeClearsEverything() {
        let cache = MinimapRowCache()
        begin(cache, maxColumns: 80)
        cache.store(row(1), for: id(1), provisional: false)
        cache.endFrame()

        begin(cache, maxColumns: 60)
        XCTAssertNil(cache.cachedRow(for: id(1)))
    }

    func testEndFrameEvictsRowsNotVisitedThisFrame() {
        let cache = MinimapRowCache()
        begin(cache)
        cache.store(row(1), for: id(1), provisional: false)
        cache.store(row(2), for: id(2), provisional: false)
        cache.endFrame()

        begin(cache)
        _ = cache.cachedRow(for: id(1)) // visit only line 1
        cache.endFrame()

        begin(cache)
        XCTAssertEqual(cache.cachedRow(for: id(1)), row(1))
        XCTAssertNil(cache.cachedRow(for: id(2)), "line 2 was not visited last frame")
    }

    func testInvalidateProvisionalRowsDropsOnlyProvisionalOnes() {
        let cache = MinimapRowCache()
        begin(cache)
        cache.store(row(1), for: id(1), provisional: false)
        cache.store(row(2), for: id(2), provisional: true)
        XCTAssertTrue(cache.isProvisional(id(2)))
        XCTAssertFalse(cache.isProvisional(id(1)))
        cache.endFrame()

        cache.invalidateProvisionalRows()

        begin(cache)
        XCTAssertEqual(cache.cachedRow(for: id(1)), row(1), "the colored row survives")
        XCTAssertNil(cache.cachedRow(for: id(2)), "the provisional row is dropped so it recolors")
    }
}
