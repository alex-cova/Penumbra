import XCTest
@testable import Penumbra
@testable import Umbra

/// The tab-drag math ported from Silica, and the workspace tab moves behind it.
@MainActor
final class IDETabDragTests: XCTestCase {
    private let ids = (0..<4).map { _ in UUID() }

    private func bar(scrollOffset: CGFloat = 0, barWidth: CGFloat = 400) -> IDETabBarLayout {
        IDETabBarLayout(
            tabs: ids,
            widths: Dictionary(uniqueKeysWithValues: ids.map { ($0, 100) }),
            spacing: 4, inset: 8, barWidth: barWidth, scrollOffset: scrollOffset
        )
    }

    func testTabAtPointFindsTabsAndMissesGaps() {
        let layout = bar()
        XCTAssertEqual(layout.tab(at: 8), ids[0])
        XCTAssertEqual(layout.tab(at: 107), ids[0])
        XCTAssertNil(layout.tab(at: 110), "the gap between tabs has none")
        XCTAssertEqual(layout.tab(at: 112), ids[1])
        XCTAssertNil(layout.tab(at: 1000))
    }

    func testMinXOfATabIsWhereItStartsInTheScrolledRow() {
        XCTAssertEqual(bar().minX(of: ids[2]), 8 + 2 * 104)
        XCTAssertEqual(bar(scrollOffset: 30).minX(of: ids[0]), -22)
        XCTAssertNil(bar().minX(of: UUID()))
    }

    // MARK: Where a dragged tab would go

    func testInsertionIndexPassesANeighbourAtItsMiddle() {
        let layout = bar()
        // Tab 0 is being dragged; the others sit at 8, 112, 216 as a row of three (middles 58, 162, 266).
        XCTAssertEqual(layout.insertionIndex(forCenterX: 0, excluding: ids[0]), 0)
        XCTAssertEqual(layout.insertionIndex(forCenterX: 58, excluding: ids[0]), 0, "on the middle is not past it")
        XCTAssertEqual(layout.insertionIndex(forCenterX: 59, excluding: ids[0]), 1)
        XCTAssertEqual(layout.insertionIndex(forCenterX: 200, excluding: ids[0]), 2)
        XCTAssertEqual(layout.insertionIndex(forCenterX: 1000, excluding: ids[0]), 3)
    }

    func testInsertionIndexInAnotherBarCountsEveryTab() {
        XCTAssertEqual(bar().insertionIndex(forCenterX: 300, excluding: nil), 3)
        XCTAssertEqual(bar().insertionIndex(forCenterX: 0, excluding: nil), 0)
    }

    func testInsertionIndexFollowsTheScroll() {
        // Scrolled by a tab's stride, what is at 59 is the middle of what was at 163.
        XCTAssertEqual(bar(scrollOffset: 104).insertionIndex(forCenterX: 59, excluding: nil), 2)
    }

    // MARK: The gap

    func testNoDragNoOffsets() {
        XCTAssertTrue(bar().gapOffsets(excluding: nil, insertingAt: nil, gapWidth: 100).isEmpty)
    }

    func testTheGapStaysInTheDraggedTabsSlotUntilItMoves() {
        XCTAssertTrue(bar().gapOffsets(excluding: ids[1], insertingAt: 1, gapWidth: 100).isEmpty)
    }

    func testTheGapMovesWithinTheBarItCameFrom() {
        // Tab 0 over the slot after tab 2 (index 2 among the others): 1 and 2 step back over its slot.
        let offsets = bar().gapOffsets(excluding: ids[0], insertingAt: 2, gapWidth: 100)
        XCTAssertEqual(offsets[ids[1]], -104)
        XCTAssertEqual(offsets[ids[2]], -104)
        XCTAssertNil(offsets[ids[3]], "past the gap it is where it was")
        XCTAssertNil(offsets[ids[0]], "the dragged tab is the ghost's")
        // The other way: tab 3 moves to the front, the ones it passes make room.
        let front = bar().gapOffsets(excluding: ids[3], insertingAt: 0, gapWidth: 100)
        XCTAssertEqual(front[ids[0]], 104)
        XCTAssertEqual(front[ids[1]], 104)
        XCTAssertEqual(front[ids[2]], 104)
    }

    func testTheRowClosesOverATabThatLeavesItsBar() {
        let offsets = bar().gapOffsets(excluding: ids[1], insertingAt: nil, gapWidth: 100)
        XCTAssertNil(offsets[ids[0]])
        XCTAssertEqual(offsets[ids[2]], -104)
        XCTAssertEqual(offsets[ids[3]], -104)
    }

    func testAGapOpensInABarTheTabIsOver() {
        let offsets = bar().gapOffsets(excluding: nil, insertingAt: 2, gapWidth: 80)
        XCTAssertNil(offsets[ids[0]])
        XCTAssertNil(offsets[ids[1]])
        XCTAssertEqual(offsets[ids[2]], 84, "the gap and the spacing after it")
        XCTAssertEqual(offsets[ids[3]], 84)
        XCTAssertTrue(bar().gapOffsets(excluding: nil, insertingAt: 4, gapWidth: 80).isEmpty, "a gap at the end moves nothing")
    }

    func testGapOffsetsUseTheScrolledRowButNotItsOffset() {
        XCTAssertEqual(
            bar(scrollOffset: 50).gapOffsets(excluding: ids[0], insertingAt: nil, gapWidth: 100),
            bar().gapOffsets(excluding: ids[0], insertingAt: nil, gapWidth: 100),
            "offsets are distances, so scrolling the row does not change them"
        )
    }

    // MARK: Autoscroll

    func testAutoscrollTowardsTheEndTheTabIsHeldAt() {
        let layout = bar(barWidth: 200)
        let right = layout.autoscrollOffset(pointerX: 195, elapsed: 0.1)
        XCTAssertGreaterThan(right ?? 0, 0)
        XCTAssertNil(layout.autoscrollOffset(pointerX: 100, elapsed: 0.1), "the middle of the bar does not scroll")
        XCTAssertNil(layout.autoscrollOffset(pointerX: 5, elapsed: 0.1), "already at the start")
        let scrolled = bar(scrollOffset: 100, barWidth: 200)
        XCTAssertLessThan(scrolled.autoscrollOffset(pointerX: 5, elapsed: 0.1) ?? 100, 100)
    }

    func testAutoscrollStopsAtTheEndOfTheRow() {
        // The row is 428 wide (an inset each side, four tabs and their spacing): it can scroll by 228 in a 200 bar.
        let layout = bar(scrollOffset: 228, barWidth: 200)
        XCTAssertNil(layout.autoscrollOffset(pointerX: 199, elapsed: 1))
    }

    func testEdgeFadesRampOverTheFadeDistance() {
        let fades = IDEEdgeFades(leading: 10, trailing: 40, over: 20)
        XCTAssertEqual(fades.leading, 0.5)
        XCTAssertEqual(fades.trailing, 1)
    }
}

@MainActor
final class IDEWorkspaceTabMoveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func workspaceWithTwoPanes() -> (IDEWorkspace, UUID, UUID, [WorkbenchDocument]) {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        let docs = (0..<3).map { WorkbenchDocument(displayName: "f\($0).txt", text: "text \($0)") }
        for doc in docs { workspace.workbench.openDocument(doc) }
        let firstPane = workspace.workbench.activePaneID
        workspace.splitRight()
        let secondPane = workspace.workbench.activePaneID
        XCTAssertNotEqual(firstPane, secondPane)
        return (workspace, firstPane, secondPane, docs)
    }

    func testReorderTabChangesOrderInItsPane() {
        let (workspace, firstPane, _, docs) = workspaceWithTwoPanes()
        defer { workspace.teardown() }
        workspace.reorderTab(docs[0].id, in: firstPane, to: 2)
        let pane = workspace.workbench.layout.findPane(id: firstPane)
        XCTAssertEqual(pane?.documents.map(\.id), [docs[1].id, docs[2].id, docs[0].id])
    }

    func testMoveTabToAnotherPaneInsertsAtTheIndex() {
        let (workspace, firstPane, secondPane, docs) = workspaceWithTwoPanes()
        defer { workspace.teardown() }
        let target = workspace.workbench.layout.findPane(id: secondPane)
        let before = target?.documents.map(\.id) ?? []
        // The second pane starts as a copy of the first's active document; move another over, first.
        workspace.moveTab(docs[0].id, from: firstPane, toPane: secondPane, at: 0)
        XCTAssertEqual(target?.documents.first?.id, docs[0].id)
        XCTAssertEqual(target?.documents.count, before.count + (before.contains(docs[0].id) ? 0 : 1))
        workspace.moveTab(docs[1].id, from: firstPane, toPane: secondPane, at: 99)
        XCTAssertEqual(target?.documents.last?.id, docs[1].id, "an index past the end appends")
    }

    func testDroppingAtTheEndOfAnotherPaneAppendsWithoutAnIndex() {
        let (workspace, firstPane, secondPane, docs) = workspaceWithTwoPanes()
        defer { workspace.teardown() }
        workspace.moveTab(docs[2].id, from: firstPane, toPane: secondPane)
        XCTAssertEqual(workspace.workbench.layout.findPane(id: secondPane)?.documents.last?.id, docs[2].id)
    }

    func testMoveTabToAnotherPaneSelectsItThereWithoutClosingAnything() {
        let (workspace, firstPane, secondPane, docs) = workspaceWithTwoPanes()
        defer { workspace.teardown() }
        let dirty = docs[1]
        dirty.isDirty = true
        workspace.moveTab(dirty.id, from: firstPane, toPane: secondPane)
        let source = workspace.workbench.layout.findPane(id: firstPane)
        let target = workspace.workbench.layout.findPane(id: secondPane)
        XCTAssertFalse(source?.documents.contains { $0.id == dirty.id } ?? true)
        XCTAssertEqual(target?.selectedDocumentID, dirty.id)
        XCTAssertTrue(dirty.isDirty, "a move is not a close: unsaved state rides along")
        XCTAssertEqual(workspace.workbench.activePaneID, secondPane)
    }

    func testMovingTheLastTabOutClosesTheSourcePane() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let only = WorkbenchDocument(displayName: "only.txt", text: "x")
        workspace.workbench.openDocument(only)
        let firstPane = workspace.workbench.activePaneID
        workspace.splitRight()
        let secondPane = workspace.workbench.activePaneID
        // The split duplicated the document into the new pane; move the first
        // pane's only tab over and back so the source empties.
        workspace.moveTab(only.id, from: secondPane, toPane: firstPane)
        XCTAssertNil(workspace.workbench.layout.findPane(id: secondPane), "an emptied pane closes")
        XCTAssertEqual(workspace.workbench.layout.findPane(id: firstPane)?.selectedDocumentID, only.id)
    }

    func testCanSplitGuardUsesReportedEditorAreaSize() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        XCTAssertTrue(workspace.canSplitActivePane(along: .trailing), "no size reported yet: allowed")
        workspace.editorAreaSize = CGSize(width: 200, height: 200)
        XCTAssertFalse(workspace.canSplitActivePane(along: .trailing), "two panes at the 120pt minimum do not fit")
        workspace.editorAreaSize = CGSize(width: 800, height: 600)
        XCTAssertTrue(workspace.canSplitActivePane(along: .trailing))
        XCTAssertTrue(workspace.canSplitActivePane(along: .bottom))
        workspace.isTerminalVisible = true
        workspace.editorAreaSize = CGSize(width: 800, height: 300)
        XCTAssertFalse(workspace.canSplitActivePane(along: .bottom), "the terminal's minimum is reserved")
    }
}

@MainActor
final class IDEBottomPanelClampTests: XCTestCase {
    func testStoredHeightIsClampedToTheColumn() {
        let model = IDEBottomPanelModel()
        model.height = 900
        model.columnHeightChanged(800)
        XCTAssertEqual(model.height, 600, "the static maximum wins when the column is tall")
        model.columnHeightChanged(400)
        XCTAssertEqual(model.height, 280, "the editor keeps its minimum height")
        model.height = 40
        model.columnHeightChanged(400)
        XCTAssertEqual(model.height, IDEAppearance.Spacing.terminalMinHeight)
    }
}
