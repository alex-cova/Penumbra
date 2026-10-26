import Foundation
import XCTest
@testable import Umbra

/// The panel widths a window saves must be the ones it shows: `saveSession()` is called from
/// dozens of places that know nothing about the sidebar, so the workspace has to hold the widths.
@MainActor
final class IDEWorkspacePanelWidthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    func testASessionMadeWithNoArgumentsCarriesTheWorkspacesOwnSizes() {
        let workspace = IDEWorkspace()
        workspace.sidebarWidth = 333
        workspace.projectSidebarWidth = 277
        workspace.terminalHeight = 410

        let session = workspace.makeSession()

        XCTAssertEqual(session.sidebarWidth, 333)
        XCTAssertEqual(session.projectSidebarWidth, 277)
        XCTAssertEqual(session.terminalHeight, 410)
    }

    func testExplicitSizesWinOverTheWorkspacesOwn() {
        let workspace = IDEWorkspace()
        workspace.sidebarWidth = 333

        let session = workspace.makeSession(sidebarWidth: 250)

        XCTAssertEqual(session.sidebarWidth, 250)
    }

    func testSeedingTakesBothWidthsFromTheSavedSession() {
        let workspace = IDEWorkspace()
        let saved = IDEWindowSession(sidebarWidth: 301, projectSidebarWidth: 288)

        workspace.seedPanelWidths(from: saved)

        XCTAssertEqual(workspace.sidebarWidth, 301)
        XCTAssertEqual(workspace.projectSidebarWidth, 288)
        // What gets written next is what was seeded, not the default.
        XCTAssertEqual(workspace.makeSession().sidebarWidth, 301)
        XCTAssertEqual(workspace.makeSession().projectSidebarWidth, 288)
    }

    func testAnUntouchedWorkspaceStartsAtTheDefaultWidths() {
        let workspace = IDEWorkspace()

        XCTAssertEqual(workspace.sidebarWidth, IDEAppearance.Spacing.sidebarWidth)
        XCTAssertEqual(workspace.projectSidebarWidth, IDEAppearance.Spacing.sidebarWidth)
    }
}
