import XCTest
@testable import Umbra

final class IDETerminalTilingTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)

    func testPresetsAreHalvesThirdsAndQuarters() {
        let columns = IDETerminalTiling.preset(.threeColumns, ids: ids).rects(in: bounds)
        XCTAssertEqual(columns[ids[0]], CGRect(x: 0, y: 0, width: 400, height: 600))
        XCTAssertEqual(columns[ids[2]], CGRect(x: 800, y: 0, width: 400, height: 600))
        let rows = IDETerminalTiling.preset(.twoRows, ids: ids).rects(in: bounds)
        XCTAssertEqual(rows[ids[1]], CGRect(x: 0, y: 300, width: 1200, height: 300))
        let quarters = IDETerminalTiling.preset(.quarters, ids: ids).rects(in: bounds)
        XCTAssertEqual(quarters[ids[3]], CGRect(x: 600, y: 300, width: 600, height: 300))
        XCTAssertEqual(IDETerminalTiling.preset(.quarters, ids: ids).paneIDs, Array(ids.prefix(4)))
    }

    func testPanesTileTheRectangleExactly() {
        var tiling = IDETerminalTiling.single(ids[0])
        tiling.insert(ids[1], beside: ids[0], edge: .trailing)
        tiling.insert(ids[2], beside: ids[1], edge: .trailing)
        let width = tiling.rects(in: CGRect(x: 0, y: 0, width: 1000, height: 100)).values.map(\.width).reduce(0, +)
        XCTAssertEqual(width, 1000)
    }

    func testSplittingInTheDirectionOfTheParentJoinsItAndSharesEvenly() {
        var tiling = IDETerminalTiling.single(ids[0])
        tiling.insert(ids[1], beside: ids[0], edge: .trailing)
        tiling.insert(ids[2], beside: ids[1], edge: .trailing)
        XCTAssertEqual(tiling, .preset(.threeColumns, ids: [ids[0], ids[1], ids[2]]))
    }

    func testSplittingAcrossTheParentNestsAndPlacesBeforeOnLeadingAndTop() {
        var tiling = IDETerminalTiling.preset(.twoColumns, ids: ids)
        tiling.insert(ids[2], beside: ids[1], edge: .top)
        XCTAssertEqual(tiling.paneIDs, [ids[0], ids[2], ids[1]])
        let rects = tiling.rects(in: bounds)
        XCTAssertEqual(rects[ids[2]], CGRect(x: 600, y: 0, width: 600, height: 300))
        XCTAssertEqual(rects[ids[1]], CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    func testRemovingCollapsesSplitsAndKeepsTheTreeFlat() {
        var tiling = IDETerminalTiling.preset(.twoColumns, ids: ids)
        tiling.insert(ids[2], beside: ids[1], edge: .bottom)
        XCTAssertTrue(tiling.remove(ids[1]))
        XCTAssertEqual(tiling, .preset(.twoColumns, ids: [ids[0], ids[2]]))
        XCTAssertTrue(tiling.remove(ids[0]))
        XCTAssertEqual(tiling, .single(ids[2]))
        XCTAssertFalse(tiling.remove(ids[0]))
        XCTAssertTrue(tiling.remove(ids[2]))
        XCTAssertTrue(tiling.isEmpty)
    }

    func testMovingTakesAPaneOutOfItsOldPlace() {
        var tiling = IDETerminalTiling.preset(.threeColumns, ids: ids)
        tiling.move(ids[0], beside: ids[2], edge: .bottom)
        XCTAssertEqual(tiling.paneIDs, [ids[1], ids[2], ids[0]])
        let rects = tiling.rects(in: bounds)
        XCTAssertEqual(rects[ids[1]]?.width, 600)
        XCTAssertEqual(rects[ids[0]], CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    func testReplaceAndSwap() {
        var tiling = IDETerminalTiling.preset(.twoColumns, ids: ids)
        tiling.replace(ids[0], with: ids[3])
        XCTAssertEqual(tiling.paneIDs, [ids[3], ids[1]])
        tiling.swap(ids[3], ids[1])
        XCTAssertEqual(tiling.paneIDs, [ids[1], ids[3]])
        tiling.replace(ids[1], with: ids[3])
        XCTAssertEqual(tiling.paneIDs, [ids[1], ids[3]], "a pane already showing is not duplicated")
    }

    func testDraggingADividerResizesTheNeighboursAndStopsAtTheMinimum() throws {
        var tiling = IDETerminalTiling.preset(.threeColumns, ids: ids)
        let divider = try XCTUnwrap(tiling.dividers(in: bounds).first)
        XCTAssertEqual(divider.position, 400)
        tiling.moveDivider(path: divider.path, index: divider.index, toFraction: 0.25)
        var rects = tiling.rects(in: bounds)
        XCTAssertEqual(rects[ids[0]]?.width, 300)
        XCTAssertEqual(rects[ids[1]]?.width, 500)
        XCTAssertEqual(rects[ids[2]]?.width, 400, "the pane after the pair is untouched")
        tiling.moveDivider(path: divider.path, index: divider.index, toFraction: 0.99)
        rects = tiling.rects(in: bounds)
        XCTAssertEqual(rects[ids[1]]?.width ?? 0, 1200 * 0.08, accuracy: 1)
        tiling.moveDivider(path: divider.path, index: divider.index, toFraction: -3)
        XCTAssertEqual(tiling.rects(in: bounds)[ids[0]]?.width ?? 0, 1200 * 0.08, accuracy: 1)
    }

    func testTheMinimumIsAFloorInPointsNotAShareOfTheSplit() throws {
        let tiling = IDETerminalTiling.preset(.twoRows, ids: ids)
        let tall = try XCTUnwrap(tiling.dividers(in: CGRect(x: 0, y: 0, width: 1200, height: 900)).first)
        let short = try XCTUnwrap(tiling.dividers(in: CGRect(x: 0, y: 0, width: 1200, height: 120)).first)
        XCTAssertEqual(IDETerminalTiling.minimumFraction(for: tall), 72.0 / 900, accuracy: 0.0001)
        XCTAssertEqual(IDETerminalTiling.minimumFraction(for: short), 72.0 / 120, accuracy: 0.0001)

        var squeezed = tiling
        squeezed.moveDivider(
            path: tall.path, index: tall.index, toFraction: 0.99,
            minimum: IDETerminalTiling.minimumFraction(for: tall))
        let rects = squeezed.rects(in: CGRect(x: 0, y: 0, width: 1200, height: 900))
        XCTAssertEqual(rects[ids[1]]?.height ?? 0, 72, accuracy: 1)
    }

    func testAPairTooSmallForTwoMinimumsSettlesAtItsMiddle() throws {
        var tiling = IDETerminalTiling.preset(.twoRows, ids: ids)
        let area = CGRect(x: 0, y: 0, width: 1200, height: 100)
        let divider = try XCTUnwrap(tiling.dividers(in: area).first)
        tiling.moveDivider(
            path: divider.path, index: divider.index, toFraction: 0.9,
            minimum: IDETerminalTiling.minimumFraction(for: divider))
        let rects = tiling.rects(in: area)
        XCTAssertEqual(rects[ids[0]]?.height, 50)
        XCTAssertEqual(rects[ids[1]]?.height, 50)
    }

    func testResettingADividerSharesTheTwoNeighboursEvenly() throws {
        var tiling = IDETerminalTiling.preset(.threeColumns, ids: ids)
        let divider = try XCTUnwrap(tiling.dividers(in: bounds).first)
        tiling.moveDivider(path: divider.path, index: divider.index, toFraction: 0.1)
        tiling.resetDivider(path: divider.path, index: divider.index)
        let rects = tiling.rects(in: bounds)
        XCTAssertEqual(rects[ids[0]]?.width, 400)
        XCTAssertEqual(rects[ids[1]]?.width, 400)
        XCTAssertEqual(rects[ids[2]]?.width, 400)

        // Only the pair moves: with the second divider off-centre, resetting the first leaves the
        // third pane's share alone.
        let second = try XCTUnwrap(tiling.dividers(in: bounds).last)
        tiling.moveDivider(path: second.path, index: second.index, toFraction: 0.5)
        let before = try XCTUnwrap(tiling.rects(in: bounds)[ids[2]]?.width)
        tiling.resetDivider(path: divider.path, index: divider.index)
        XCTAssertEqual(tiling.rects(in: bounds)[ids[2]]?.width, before)
    }

    @MainActor
    func testAKeyboardStepMovesADividerByAShareOfItsSplitAndStopsAtTheFloor() throws {
        let panel = IDEBottomPanelModel()
        panel.apply(.twoColumns, filling: ids)
        var divider = try XCTUnwrap(panel.tiling.dividers(in: bounds).first)
        XCTAssertEqual(IDETerminalTiling.fraction(of: divider), 0.5, accuracy: 0.001)
        panel.nudgeDivider(divider, by: 0.05)
        divider = try XCTUnwrap(panel.tiling.dividers(in: bounds).first)
        XCTAssertEqual(IDETerminalTiling.fraction(of: divider), 0.55, accuracy: 0.002)
        for _ in 0..<40 {
            divider = try XCTUnwrap(panel.tiling.dividers(in: bounds).first)
            panel.nudgeDivider(divider, by: -0.05)
        }
        divider = try XCTUnwrap(panel.tiling.dividers(in: bounds).first)
        XCTAssertEqual(divider.position, 120, accuracy: 1, "a column keeps 120 pt")
    }

    func testDividersOfANestedSplitKnowTheirContainer() throws {
        let tiling = IDETerminalTiling.preset(.quarters, ids: ids)
        let dividers = tiling.dividers(in: bounds)
        XCTAssertEqual(dividers.count, 3)
        let inner = try XCTUnwrap(dividers.first { $0.path == [1] })
        XCTAssertEqual(inner.container, CGRect(x: 0, y: 300, width: 1200, height: 300))
        XCTAssertEqual(inner.position, 600)
        XCTAssertEqual(Set(dividers.map(\.id)).count, 3)
    }

    func testNeighborFindsThePaneInADirection() {
        let tiling = IDETerminalTiling.preset(.quarters, ids: ids)
        XCTAssertEqual(tiling.neighbor(of: ids[0], toward: .trailing), ids[1])
        XCTAssertEqual(tiling.neighbor(of: ids[0], toward: .bottom), ids[2])
        XCTAssertEqual(tiling.neighbor(of: ids[3], toward: .leading), ids[2])
        XCTAssertEqual(tiling.neighbor(of: ids[3], toward: .top), ids[1])
        XCTAssertNil(tiling.neighbor(of: ids[0], toward: .leading))
        XCTAssertNil(tiling.neighbor(of: ids[1], toward: .trailing))
    }

    func testDropZonesAreTheEdgesAndTheMiddle() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(IDETerminalTiling.dropZone(at: CGPoint(x: 200, y: 100), in: size), .center)
        XCTAssertEqual(IDETerminalTiling.dropZone(at: CGPoint(x: 20, y: 100), in: size), .edge(.leading))
        XCTAssertEqual(IDETerminalTiling.dropZone(at: CGPoint(x: 390, y: 100), in: size), .edge(.trailing))
        XCTAssertEqual(IDETerminalTiling.dropZone(at: CGPoint(x: 200, y: 10), in: size), .edge(.top))
        XCTAssertEqual(IDETerminalTiling.dropZone(at: CGPoint(x: 200, y: 190), in: size), .edge(.bottom))
        XCTAssertEqual(IDETerminalTiling.dropZone(at: .zero, in: .zero), .center)
    }

    func testKeepDropsPanesWhoseTabIsGone() {
        var tiling = IDETerminalTiling.preset(.threeColumns, ids: ids)
        tiling.keep([ids[0], ids[2]])
        XCTAssertEqual(tiling.paneIDs, [ids[0], ids[2]])
    }
}
