import XCTest
@testable import Penumbra

/// The ⌥↑ / ⌥↓ range ladder: expand walks outward through supplied candidates, shrink walks
/// back, and any external selection change rebuilds it.
final class SemanticSelectionControllerTests: XCTestCase {
    func testExpandWalksOutwardThroughCandidates() {
        let controller = SemanticSelectionController()
        let current = NSRange(location: 5, length: 2)
        let candidates = [
            NSRange(location: 4, length: 5),
            NSRange(location: 0, length: 20),
            NSRange(location: 0, length: 40)
        ]
        XCTAssertEqual(controller.expand(from: current) { candidates }, NSRange(location: 4, length: 5))
        XCTAssertEqual(controller.expand(from: NSRange(location: 4, length: 5)) { candidates }, NSRange(location: 0, length: 20))
        XCTAssertEqual(controller.expand(from: NSRange(location: 0, length: 20)) { candidates }, NSRange(location: 0, length: 40))
        XCTAssertNil(controller.expand(from: NSRange(location: 0, length: 40)) { candidates }, "Nothing larger")
    }

    func testShrinkReversesExpansion() {
        let controller = SemanticSelectionController()
        let candidates = [NSRange(location: 0, length: 10), NSRange(location: 0, length: 30)]
        _ = controller.expand(from: NSRange(location: 2, length: 1)) { candidates }
        let expanded = controller.expand(from: NSRange(location: 0, length: 10)) { candidates }
        XCTAssertEqual(expanded, NSRange(location: 0, length: 30))
        XCTAssertEqual(controller.shrink(from: NSRange(location: 0, length: 30)), NSRange(location: 0, length: 10))
        XCTAssertEqual(controller.shrink(from: NSRange(location: 0, length: 10)), NSRange(location: 2, length: 1))
        XCTAssertNil(controller.shrink(from: NSRange(location: 2, length: 1)))
    }

    func testExternalSelectionChangeRebuildsLadder() {
        let controller = SemanticSelectionController()
        _ = controller.expand(from: NSRange(location: 0, length: 1)) { [NSRange(location: 0, length: 8)] }
        // Selection is now something the controller didn't set -> shrink is a no-op, and a new
        // expand rebuilds from the new base.
        XCTAssertNil(controller.shrink(from: NSRange(location: 3, length: 0)))
        let rebuilt = controller.expand(from: NSRange(location: 3, length: 0)) { [NSRange(location: 2, length: 4)] }
        XCTAssertEqual(rebuilt, NSRange(location: 2, length: 4))
    }

    func testCandidatesNotStrictlyEnclosingAreIgnored() {
        let controller = SemanticSelectionController()
        let current = NSRange(location: 5, length: 5) // 5..<10
        let candidates = [
            NSRange(location: 6, length: 5),  // starts after current.start -> rejected
            NSRange(location: 5, length: 5),  // equal -> rejected (not larger)
            NSRange(location: 3, length: 12)  // 3..<15 -> accepted
        ]
        XCTAssertEqual(controller.expand(from: current) { candidates }, NSRange(location: 3, length: 12))
    }
}
