import AppKit
import XCTest
@testable import Umbra

/// A change scrolled partly out of view has a ribbon laid out above or below the divider; the
/// strip must cut it off instead of painting over the diff's title row and toolbar.
@MainActor
final class IDEDiffDividerViewTests: XCTestCase {
    func testDividerClipsItsDrawingToItsBounds() {
        XCTAssertTrue(IDEDiffDividerView().clipsToBounds)
        XCTAssertTrue(IDEDiffDividerView(frame: CGRect(x: 0, y: 0, width: 44, height: 200)).clipsToBounds)
    }

    func testDividerButtonLabelsMatchTheTooltipAndTheAccessibilityName() {
        XCTAssertEqual(IDEDiffDividerLabels.replaceWithLeftSide, "Replace with the left side")
        XCTAssertEqual(IDEDiffDividerLabels.hunk(.stage), "Stage Hunk")
        XCTAssertEqual(IDEDiffDividerLabels.hunk(.unstage), "Unstage Hunk")
        let divider = IDEDiffDividerView()
        XCTAssertEqual(divider.accessibilityRole(), .group)
        XCTAssertEqual(divider.accessibilityLabel(), "Diff changes")
        XCTAssertEqual(divider.accessibilityChildren()?.count, 0)
    }
}
