import XCTest
@testable import Umbra

@MainActor
final class IDEBottomPanelModelTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func tab(_ name: String) -> IDETerminalTab {
        IDETerminalTab(id: UUID(), title: name, workingDirectory: home)
    }

    func testAppendingSelectsTheTabAndOpensThePanelOnTheShell() {
        let model = IDEBottomPanelModel()
        model.selectedTab = .problems
        let first = tab("a")
        model.append(first)
        XCTAssertEqual(model.selectedTabID, first.id)
        XCTAssertEqual(model.selectedTab, .terminal)
        XCTAssertTrue(model.isVisible)
    }

    func testClosingTheSelectedTabSelectsANeighbour() {
        let model = IDEBottomPanelModel()
        let (a, b, c) = (tab("a"), tab("b"), tab("c"))
        [a, b, c].forEach(model.append)
        XCTAssertEqual(model.selectedTabID, c.id)
        XCTAssertEqual(model.closeTab(c.id), .removed)
        XCTAssertEqual(model.selectedTabID, b.id)
        XCTAssertEqual(model.closeTab(a.id), .removed)
        XCTAssertEqual(model.selectedTabID, b.id, "closing another tab keeps the selection")
    }

    func testClosingTheLastTabSaysSoAndClearsTheSelection() {
        let model = IDEBottomPanelModel()
        let only = tab("a")
        model.append(only)
        XCTAssertEqual(model.closeTab(only.id), .lastClosed)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.closeTab(only.id), .notFound)
    }

    func testNextAndPreviousWrapAndNeedAVisiblePanel() {
        let model = IDEBottomPanelModel()
        let (a, b) = (tab("a"), tab("b"))
        model.append(a)
        model.append(b)
        XCTAssertEqual(model.nextTabID(), a.id, "wraps from the last to the first")
        XCTAssertEqual(model.previousTabID(), a.id)
        model.isVisible = false
        XCTAssertNil(model.nextTabID())
    }

    func testRestartAndClearOnlyTouchShells() {
        let model = IDEBottomPanelModel()
        let shell = tab("sh")
        model.append(shell)
        XCTAssertTrue(model.requestRestart(nil))
        XCTAssertEqual(model.tabs[0].restartRequestID, 1)
        model.requestClear()
        XCTAssertEqual(model.tabs[0].clearRequestID, 1)

        let command = UUID()
        XCTAssertTrue(model.showAgentCommand(id: command, title: "make", line: "x", directory: home))
        XCTAssertFalse(model.requestRestart(model.selectedTabID), "an agent command tab has no shell to restart")
    }

    func testAnAgentCommandOpensOneTabAndFeedsIt() {
        let model = IDEBottomPanelModel()
        let command = UUID()
        XCTAssertTrue(model.showAgentCommand(id: command, title: "swift build", line: "one\n", directory: home))
        XCTAssertFalse(model.showAgentCommand(id: command, title: "swift build", line: "two\n", directory: home))
        let tabID = model.tabs[0].id
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs[0].agentFeedGeneration, 2)
        XCTAssertEqual(model.takeAgentCommandFeed(tabID: tabID), "one\ntwo\n")
        XCTAssertEqual(model.takeAgentCommandFeed(tabID: tabID), "", "consumed once")
    }

    func testAFinishedOrClosedCommandNeverReopensItsTab() {
        let model = IDEBottomPanelModel()
        let ended = UUID()
        XCTAssertFalse(model.showAgentCommand(id: ended, title: "a", line: nil, directory: home))
        XCTAssertFalse(model.showAgentCommand(id: ended, title: "a", line: "late", directory: home))
        XCTAssertTrue(model.tabs.isEmpty)

        let closed = UUID()
        XCTAssertTrue(model.showAgentCommand(id: closed, title: "b", line: "x", directory: home))
        _ = model.closeTab(model.tabs[0].id)
        XCTAssertFalse(model.showAgentCommand(id: closed, title: "b", line: "more", directory: home))
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testResettingShellsRestartsOnlyThoseElsewhere() {
        let model = IDEBottomPanelModel()
        var elsewhere = tab("x")
        elsewhere.workingDirectory = URL(fileURLWithPath: "/tmp")
        model.append(elsewhere)
        model.append(tab("home"))
        model.resetShells(to: home)
        XCTAssertEqual(model.tabs[0].restartRequestID, 1)
        XCTAssertEqual(model.tabs[1].restartRequestID, 0)
        XCTAssertEqual(model.tabs[0].workingDirectory, home)
    }

    func testRenamingIgnoresBlankTitles() {
        let model = IDEBottomPanelModel()
        let shell = tab("zsh")
        model.append(shell)
        model.updateTitle(shell.id, to: "   ")
        XCTAssertEqual(model.tabs[0].title, "zsh")
        model.updateTitle(shell.id, to: " build ")
        XCTAssertEqual(model.tabs[0].title, "build")
    }
}

@MainActor
final class IDEBottomPanelLayoutTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func tab(_ name: String) -> IDETerminalTab {
        IDETerminalTab(id: UUID(), title: name, workingDirectory: home)
    }

    private func model(tabs count: Int) -> (IDEBottomPanelModel, [IDETerminalTab]) {
        let model = IDEBottomPanelModel()
        let tabs = (0..<count).map { tab("t\($0)") }
        tabs.forEach(model.append)
        return (model, tabs)
    }

    func testAnUnsplitPanelShowsOnlyTheSelectedTab() {
        let (model, tabs) = model(tabs: 3)
        XCTAssertEqual(model.visibleTabIDs, [tabs[2].id])
    }

    func testSelectingAHiddenTabTakesTheFocusedPanesPlace() {
        let (model, tabs) = model(tabs: 3)
        model.place(tabs[0].id, beside: tabs[2].id, edge: .leading)
        XCTAssertEqual(model.visibleTabIDs, [tabs[0].id, tabs[2].id])
        XCTAssertTrue(model.selectTab(tabs[1].id))
        XCTAssertEqual(model.visibleTabIDs, [tabs[1].id, tabs[2].id], "placing t0 focused it, so t1 took its pane")
        XCTAssertEqual(model.selectedTabID, tabs[1].id)
    }

    func testSelectingAShownTabOnlyMovesTheFocus() {
        let (model, tabs) = model(tabs: 2)
        model.place(tabs[0].id, beside: tabs[1].id, edge: .trailing)
        XCTAssertTrue(model.selectTab(tabs[1].id))
        XCTAssertEqual(model.visibleTabIDs, [tabs[1].id, tabs[0].id])
        XCTAssertEqual(model.selectedTabID, tabs[1].id)
    }

    func testClosingAPaneCollapsesItAndFocusesTheNeighbour() {
        let (model, tabs) = model(tabs: 3)
        model.apply(.threeColumns, filling: tabs.map(\.id))
        model.focus(tabs[1].id)
        XCTAssertEqual(model.closeTab(tabs[1].id), .removed)
        XCTAssertEqual(model.visibleTabIDs, [tabs[0].id, tabs[2].id])
        XCTAssertEqual(model.selectedTabID, tabs[0].id)
    }

    func testClosingAHiddenTabLeavesThePanesAlone() {
        let (model, tabs) = model(tabs: 3)
        model.place(tabs[0].id, beside: tabs[2].id, edge: .trailing)
        XCTAssertEqual(model.closeTab(tabs[1].id), .removed)
        XCTAssertEqual(model.visibleTabIDs, [tabs[2].id, tabs[0].id])
    }

    func testClosingTheLastShownTabOfASinglePaneShowsTheNeighbourTab() {
        let (model, tabs) = model(tabs: 2)
        XCTAssertEqual(model.closeTab(tabs[1].id), .removed)
        XCTAssertEqual(model.visibleTabIDs, [tabs[0].id])
    }

    func testNoTabsShowWhileAnotherBottomTabIsSelected() {
        let (model, tabs) = model(tabs: 2)
        model.apply(.twoColumns, filling: tabs.map(\.id))
        model.selectedTab = .problems
        XCTAssertTrue(model.visibleTabIDs.isEmpty)
    }

    func testZoomShowsOnlyTheFocusedPaneAndNeedsASplit() {
        let (model, tabs) = model(tabs: 2)
        model.toggleZoom()
        XCTAssertNil(model.zoomedTabID, "nothing to zoom in a single pane")
        model.apply(.twoColumns, filling: tabs.map(\.id))
        model.focus(tabs[1].id)
        model.toggleZoom()
        XCTAssertEqual(model.visibleTabIDs, [tabs[1].id])
        model.toggleZoom()
        XCTAssertEqual(model.visibleTabIDs, tabs.map(\.id))
    }

    func testDroppingOnAnEdgeSplitsAndInTheMiddleSwaps() {
        let (model, tabs) = model(tabs: 3)
        model.apply(.twoColumns, filling: [tabs[0].id, tabs[1].id])
        model.drop(tabs[2].id, onto: tabs[0].id, at: .edge(.bottom))
        XCTAssertEqual(model.visibleTabIDs, [tabs[0].id, tabs[2].id, tabs[1].id])
        model.drop(tabs[1].id, onto: tabs[0].id, at: .center)
        XCTAssertEqual(model.visibleTabIDs, [tabs[1].id, tabs[2].id, tabs[0].id])
        model.closeTab(tabs[2].id)
        model.drop(tabs[2].id, onto: tabs[0].id, at: .center)
        XCTAssertFalse(model.visibleTabIDs.contains(tabs[2].id), "a closed tab is not dropped")
    }

    func testSizePresetsFollowTheEditorColumnHeight() {
        let model = IDEBottomPanelModel()
        model.columnHeightChanged(1200)
        model.applySize(.third)
        XCTAssertEqual(model.height, 400)
        model.columnHeightChanged(800)
        XCTAssertEqual(model.height, 267)
        model.applySize(.half)
        XCTAssertEqual(model.height, 400)
        model.sizePreset = nil
        model.columnHeightChanged(1000)
        XCTAssertEqual(model.height, 400, "a dragged size no longer follows the window")
    }

    func testSizePresetNeverGoesBelowTheMinimumAndLeavesFullscreen() {
        let model = IDEBottomPanelModel()
        model.isExpanded = true
        model.columnHeightChanged(300)
        model.applySize(.quarter)
        XCTAssertEqual(model.height, IDEAppearance.Spacing.terminalMinHeight)
        XCTAssertFalse(model.isExpanded)
    }
}
