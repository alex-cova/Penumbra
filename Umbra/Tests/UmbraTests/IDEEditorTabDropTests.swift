import CoreGraphics
import Penumbra
import XCTest
@testable import Umbra

/// Where a tab dropped on an editor pane goes: its tab bar, the middle, or a split off an edge.
final class IDEEditorTabDropTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 0, width: 400, height: 432)   // a 32 pt bar, a 400 × 400 editor
    private let bar: CGFloat = 32

    private func zone(_ x: CGFloat, _ y: CGFloat) -> IDEEditorTabDrop.Zone {
        IDEEditorTabDrop.zone(at: CGPoint(x: x, y: y), in: frame, tabBarHeight: bar)
    }

    func testTheTabBarIsNotTheTopEdge() {
        XCTAssertEqual(zone(300, 10), .tabBar)
        XCTAssertEqual(zone(101, 1), .tabBar, "not even in the corner")
    }

    func testTheOuterQuarterOfASideIsThatEdge() {
        XCTAssertEqual(zone(110, 232), .edge(.leading))
        XCTAssertEqual(zone(490, 232), .edge(.trailing))
        XCTAssertEqual(zone(300, 40), .edge(.top))
        XCTAssertEqual(zone(300, 425), .edge(.bottom))
    }

    func testTheMiddleIsTheMiddle() {
        XCTAssertEqual(zone(300, 232), .center)
        XCTAssertEqual(zone(210, 332), .center, "just inside the quarter on both axes")
    }

    func testACornerGoesToTheNearerEdge() {
        XCTAssertEqual(zone(105, 80), .edge(.leading), "far from the top, close to the left")
        XCTAssertEqual(zone(190, 36), .edge(.top))
    }

    func testTheHighlightIsHalfTheEditorOnTheEdge() {
        func highlight(_ edge: EditorSplitEdge?) -> CGRect {
            IDEEditorTabDrop.highlight(for: edge, in: frame, tabBarHeight: bar)
        }
        XCTAssertEqual(highlight(nil), frame)
        XCTAssertEqual(highlight(.leading), CGRect(x: 100, y: 32, width: 200, height: 400))
        XCTAssertEqual(highlight(.trailing), CGRect(x: 300, y: 32, width: 200, height: 400))
        XCTAssertEqual(highlight(.top), CGRect(x: 100, y: 32, width: 400, height: 200))
        XCTAssertEqual(highlight(.bottom), CGRect(x: 100, y: 232, width: 400, height: 200))
    }

    // MARK: Target

    private let source = UUID(), other = UUID()

    private func target(_ point: CGPoint, tabs: Int = 2, canSplit: Bool = true) -> IDETabDropTarget? {
        IDEEditorTabDrop.target(
            at: point,
            panes: [(source, CGRect(x: 0, y: 0, width: 400, height: 432)), (other, CGRect(x: 400, y: 0, width: 400, height: 432))],
            from: source, sourceTabCount: tabs, tabBarHeight: bar, canSplit: { _ in canSplit }
        )
    }

    func testAnotherPanesBarAndMiddleTakeTheTab() {
        XCTAssertEqual(target(CGPoint(x: 600, y: 10)), IDETabDropTarget(paneID: other, edge: nil))
        XCTAssertEqual(target(CGPoint(x: 600, y: 232)), IDETabDropTarget(paneID: other, edge: nil))
    }

    func testAnotherPanesEdgeSplitsIt() {
        XCTAssertEqual(target(CGPoint(x: 790, y: 232)), IDETabDropTarget(paneID: other, edge: .trailing))
        XCTAssertEqual(target(CGPoint(x: 600, y: 425)), IDETabDropTarget(paneID: other, edge: .bottom))
    }

    func testTheSourcePaneOnlyTakesAnEdgeSplit() {
        XCTAssertNil(target(CGPoint(x: 200, y: 10)), "its own bar has no layout to take a place in")
        XCTAssertNil(target(CGPoint(x: 200, y: 232)), "its own middle is nothing")
        XCTAssertEqual(target(CGPoint(x: 390, y: 232)), IDETabDropTarget(paneID: source, edge: .trailing))
    }

    func testOverAnyBarTheTabGoesWhereTheBarSays() {
        func indexed(_ point: CGPoint) -> IDETabDropTarget? {
            IDEEditorTabDrop.target(
                at: point,
                panes: [(source, CGRect(x: 0, y: 0, width: 400, height: 432)), (other, CGRect(x: 400, y: 0, width: 400, height: 432))],
                from: source, sourceTabCount: 3, tabBarHeight: bar, canSplit: { _ in true },
                insertionIndex: { $0 == source ? 1 : 2 }
            )
        }
        XCTAssertEqual(indexed(CGPoint(x: 200, y: 10)), IDETabDropTarget(paneID: source, edge: nil, index: 1), "its own bar reorders")
        XCTAssertEqual(indexed(CGPoint(x: 600, y: 10)), IDETabDropTarget(paneID: other, edge: nil, index: 2))
        XCTAssertEqual(indexed(CGPoint(x: 600, y: 232)), IDETabDropTarget(paneID: other, edge: nil, index: nil), "the middle goes to the end")
        XCTAssertNil(indexed(CGPoint(x: 200, y: 232)), "its own middle is nothing")
    }

    func testALonelyTabCannotSplitItsOwnPane() {
        XCTAssertNil(target(CGPoint(x: 390, y: 232), tabs: 1))
    }

    func testNoRoomToSplitFallsBackToTheMiddle() {
        XCTAssertEqual(target(CGPoint(x: 790, y: 232), canSplit: false), IDETabDropTarget(paneID: other, edge: nil))
        XCTAssertNil(target(CGPoint(x: 390, y: 232), canSplit: false), "and nothing for its own pane")
    }

    func testOutsideEveryPaneIsNothing() {
        XCTAssertNil(target(CGPoint(x: 900, y: 232)))
    }
}
