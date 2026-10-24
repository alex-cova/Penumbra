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
