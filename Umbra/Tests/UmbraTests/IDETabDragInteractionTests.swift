import AppKit
import Penumbra
import SwiftUI
import XCTest
@testable import Umbra

/// Dragging a tab with real mouse events through the real root view: the tracker follows the pointer,
/// the session says where the tab would land, and the release or Esc ends it.
///
/// Needs a window server: `UMBRA_UI_TESTS=1 swift test --filter IDETabDragInteractionTests`.
/// With `UMBRA_TAB_DRAG_SNAPSHOTS=<folder>` it also writes a picture of the window mid-drag.
@MainActor
final class IDETabDragInteractionTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var keeper: IDEWorkspace!
    private var window: NSWindow!
    private var eventNumber = 0

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        IDEWorkspace.isSessionPersistenceEnabled = false
        keeper = IDEWorkspace()
        IDEWindowRegistry.shared.register(keeper)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1250, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IDERootView().environment(workspace).frame(minWidth: 960, minHeight: 640))
        window.orderFront(nil)
        for name in ["alpha.txt", "beta.txt", "gamma.txt", "delta.txt"] {
            workspace.openUntitled(displayName: name, text: "text of \(name)")
        }
        await settle()
    }

    override func tearDown() async throws {
        if let workspace {
            workspace.windowWillClose()
            window?.contentView = nil
            window?.close()
            workspace.teardown()
            IDEWindowRegistry.shared.unregister(workspace)
        }
        if let keeper { IDEWindowRegistry.shared.unregister(keeper) }
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Helpers

    private var panes: [EditorPane] { workspace.workbench.layout.flattenedPanes() }

    private func order(of pane: EditorPane) -> [String] { pane.documents.map(\.displayName) }

    private func tracker(for paneID: UUID) throws -> IDETabDragTracker.AnchorView {
        let origin = try XCTUnwrap(workspace.tabBarGeometry[paneID]?.origin, "the bar reports where it is")
        var found: IDETabDragTracker.AnchorView?
        func walk(_ view: NSView) {
            if let anchor = view as? IDETabDragTracker.AnchorView, anchor.barOrigin == origin { found = anchor }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return try XCTUnwrap(found, "the bar has its tracker")
    }

    /// A window point for a point in a pane's bar (its own space, x along the row, y down from its top).
    private func windowPoint(inBarOf paneID: UUID, x: CGFloat, y: CGFloat = 16) throws -> CGPoint {
        try tracker(for: paneID).convert(CGPoint(x: x, y: y), to: nil)
    }

    private func centerX(of tab: UUID, in paneID: UUID) throws -> CGFloat {
        let layout = try XCTUnwrap(workspace.tabBarGeometry[paneID]?.layout)
        return try XCTUnwrap(layout.minX(of: tab)) + (layout.widths[tab] ?? 0) / 2
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        eventNumber += 1
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1
        )
        NSApp.sendEvent(try! XCTUnwrap(event))
    }

    private func escape() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        )
        NSApp.sendEvent(try! XCTUnwrap(event))
    }

    /// Presses on a tab and drags along `path` (points in the window), one event each.
    private func press(at start: CGPoint, dragThrough path: [CGPoint]) async {
        mouse(.leftMouseDown, at: start)
        for point in path {
            mouse(.leftMouseDragged, at: point)
            await settle(0.05)
        }
        await settle(0.3)
    }

    private func snapshot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["UMBRA_TAB_DRAG_SNAPSHOTS"],
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    // MARK: Tests

    func testDraggingATabAlongItsBarOpensTheGapAndTheDropReorders() async throws {
        let pane = try XCTUnwrap(panes.first)
        let alpha = try XCTUnwrap(pane.documents.first { $0.displayName == "alpha.txt" }).id
        let startX = try centerX(of: alpha, in: pane.id)
        let layout = try XCTUnwrap(workspace.tabBarGeometry[pane.id]?.layout)
        XCTAssertEqual(layout.tabs.count, 4)

        // Past the middle of the 2nd and 3rd tabs (the others, in order, are beta, gamma, delta).
        let gamma = try XCTUnwrap(pane.documents.first { $0.displayName == "gamma.txt" }).id
        // Where gamma's middle is in the row as it is: in the row without alpha that is delta's.
        let toGamma = try centerX(of: gamma, in: pane.id) - 5
        let press = try windowPoint(inBarOf: pane.id, x: startX)
        await self.press(at: press, dragThrough: [
            try windowPoint(inBarOf: pane.id, x: startX + 10),
            try windowPoint(inBarOf: pane.id, x: startX + 60),
            try windowPoint(inBarOf: pane.id, x: toGamma),
        ])

        XCTAssertEqual(workspace.tabDrag.tab, alpha, "a press that moves picks the tab up")
        XCTAssertEqual(workspace.tabDrag.sourcePaneID, pane.id)
        XCTAssertEqual(workspace.tabDrag.target, IDETabDropTarget(paneID: pane.id, edge: nil, index: 2), "after beta and gamma")
        XCTAssertEqual(order(of: pane), ["alpha.txt", "beta.txt", "gamma.txt", "delta.txt"], "nothing is reordered until the release")
        snapshot("reorder-in-bar")

        mouse(.leftMouseUp, at: try windowPoint(inBarOf: pane.id, x: toGamma))
        await settle()
        XCTAssertNil(workspace.tabDrag.tab, "released")
        XCTAssertEqual(order(of: pane), ["beta.txt", "gamma.txt", "alpha.txt", "delta.txt"])
    }

    func testEscapeMidDragLeavesEverythingWhereItWas() async throws {
        let pane = try XCTUnwrap(panes.first)
        let alpha = try XCTUnwrap(pane.documents.first { $0.displayName == "alpha.txt" }).id
        let startX = try centerX(of: alpha, in: pane.id)
        await press(at: try windowPoint(inBarOf: pane.id, x: startX), dragThrough: [
            try windowPoint(inBarOf: pane.id, x: startX + 20),
            try windowPoint(inBarOf: pane.id, x: startX + 220),
        ])
        XCTAssertEqual(workspace.tabDrag.tab, alpha)

        escape()
        await settle()
        XCTAssertNil(workspace.tabDrag.tab)
        mouse(.leftMouseUp, at: try windowPoint(inBarOf: pane.id, x: startX + 220))
        await settle()
        XCTAssertEqual(order(of: pane), ["alpha.txt", "beta.txt", "gamma.txt", "delta.txt"])
    }

    func testAPressThatDoesNotMoveIsAClickNotADrag() async throws {
        let pane = try XCTUnwrap(panes.first)
        let beta = try XCTUnwrap(pane.documents.first { $0.displayName == "beta.txt" }).id
        let point = try windowPoint(inBarOf: pane.id, x: try centerX(of: beta, in: pane.id) - 10)
        mouse(.leftMouseDown, at: point)
        mouse(.leftMouseDragged, at: CGPoint(x: point.x + 2, y: point.y))
        mouse(.leftMouseUp, at: point)
        await settle()
        XCTAssertNil(workspace.tabDrag.tab)
        XCTAssertEqual(order(of: pane), ["alpha.txt", "beta.txt", "gamma.txt", "delta.txt"])
    }

    func testDraggingToAnotherPanesBarInsertsWhereTheGapOpened() async throws {
        workspace.splitRight()
        await settle()
        let panes = self.panes
        XCTAssertEqual(panes.count, 2)
        guard panes.count == 2 else { return }
        let (left, right) = (panes[0], panes[1])
        // The new pane starts as a copy of the active tab; give it a known order.
        let moving = try XCTUnwrap(left.documents.first { $0.displayName == "beta.txt" }).id
        let startX = try centerX(of: moving, in: left.id)

        let rightLayout = try XCTUnwrap(workspace.tabBarGeometry[right.id]?.layout)
        let rightOrigin = try XCTUnwrap(workspace.tabBarGeometry[right.id]?.origin)
        let leftOrigin = try XCTUnwrap(workspace.tabBarGeometry[left.id]?.origin)
        XCTAssertGreaterThan(rightLayout.tabs.count, 0)
        // Over the very start of the right bar: before its first tab.
        let toRight = CGPoint(x: rightOrigin.x - leftOrigin.x + 20, y: 16)
        let rightCount = right.documents.count

        await press(at: try windowPoint(inBarOf: left.id, x: startX), dragThrough: [
            try windowPoint(inBarOf: left.id, x: startX + 30),
            try windowPoint(inBarOf: left.id, x: toRight.x, y: toRight.y),
        ])
        XCTAssertEqual(workspace.tabDrag.target?.paneID, right.id)
        XCTAssertEqual(workspace.tabDrag.target?.index, 0, "the dragged tab's centre is before the first tab's middle")
        snapshot("into-another-bar")

        mouse(.leftMouseUp, at: try windowPoint(inBarOf: left.id, x: toRight.x, y: toRight.y))
        await settle()
        XCTAssertNil(workspace.tabDrag.tab)
        XCTAssertEqual(right.documents.first?.id, moving, "inserted at the gap, not appended")
        XCTAssertEqual(right.documents.count, rightCount + 1)
        XCTAssertFalse(left.documents.contains { $0.id == moving })
        XCTAssertEqual(workspace.workbench.activePaneID, right.id)
    }
}
