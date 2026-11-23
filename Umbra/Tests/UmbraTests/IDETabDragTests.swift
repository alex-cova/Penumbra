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

    func testDragPastANeighboursMiddleStepsItAside() {
        // Tab 0 dragged right by more than half of tab 1 (50 + spacing).
        let drag = IDETabDrag(tab: ids[0], translation: 60, location: 68, startScrollOffset: 0)
        let result = drag.reorder(in: bar())
        XCTAssertEqual(result?.destination, 1)
        XCTAssertEqual(result?.offsets[ids[0]], 60)
        XCTAssertEqual(result?.offsets[ids[1]], -104, "the passed tab steps aside by the dragged tab's stride")
        XCTAssertNil(result?.offsets[ids[2]])
    }

    func testShortDragStaysPut() {
        let drag = IDETabDrag(tab: ids[1], translation: 10, location: 122, startScrollOffset: 0)
        let result = drag.reorder(in: bar())
        XCTAssertEqual(result?.destination, 1)
        XCTAssertEqual(result?.offsets[ids[1]], 10)
        XCTAssertNil(result?.offsets[ids[0]])
    }

    func testDragIsClampedToTheEndsOfTheRow() {
        let drag = IDETabDrag(tab: ids[0], translation: -500, location: 0, startScrollOffset: 0)
        XCTAssertEqual(drag.reorder(in: bar())?.offsets[ids[0]], 0)
        // The last tab starts past the bar's trailing edge (row 424 > bar 400),
        // so keeping it in view lets it slide back by that overhang only.
        let last = IDETabDrag(tab: ids[3], translation: 500, location: 400, startScrollOffset: 0)
        XCTAssertEqual(last.reorder(in: bar())?.offsets[ids[3]], -20)
    }

    func testAutoscrollOnlyTowardsTheDraggedSide() {
        let layout = bar(barWidth: 200)
        let right = IDETabDrag(tab: ids[0], translation: 50, location: 195, startScrollOffset: 0)
        let target = right.autoscrollOffset(in: layout, elapsed: 0.1)
        XCTAssertNotNil(target)
        XCTAssertGreaterThan(target ?? 0, 0)
        let still = IDETabDrag(tab: ids[0], translation: 0, location: 195, startScrollOffset: 0)
        XCTAssertNil(still.autoscrollOffset(in: layout, elapsed: 0.1), "picking a tab up at the end does not scroll")
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
