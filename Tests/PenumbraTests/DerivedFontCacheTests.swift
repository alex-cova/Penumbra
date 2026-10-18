@preconcurrency import AppKit
@testable import Penumbra
import XCTest

/// `DerivedFontCache` retains its base font per key, so it must stay bounded no matter how many
/// distinct theme fonts flow through highlighting.
final class DerivedFontCacheTests: XCTestCase {
    func testCacheStaysBoundedAcrossManyDistinctFonts() {
        for size in 1 ... (DerivedFontCache.maxEntries * 2) {
            let base = NSFont.systemFont(ofSize: CGFloat(size))
            _ = DerivedFontCache.font(base, traits: .bold)
        }
        XCTAssertLessThanOrEqual(DerivedFontCache.countForTesting, DerivedFontCache.maxEntries)
    }

    func testRepeatedLookupReturnsSameInstance() {
        let base = NSFont.systemFont(ofSize: 13)
        let first = DerivedFontCache.font(base, traits: .italic)
        let second = DerivedFontCache.font(base, traits: .italic)
        XCTAssertTrue(first === second)
    }
}
