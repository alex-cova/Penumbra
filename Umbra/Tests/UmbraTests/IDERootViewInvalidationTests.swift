import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// What makes SwiftUI re-evaluate `IDERootView.body` (F21). The root reads about thirty workspace
/// properties; every one of them that changes during ordinary editing re-diffs the whole window.
/// Counts evaluations (`IDERootViewDiagnostics`) while a real document is typed in, scrolled and
/// navigated in a real (offscreen) window.
///
/// Needs a window server, so it runs only with `UMBRA_UI_TESTS=1`:
/// `UMBRA_UI_TESTS=1 swift test --filter IDERootViewInvalidationTests`
@MainActor
final class IDERootViewInvalidationTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var window: NSWindow!
    private var keeper: IDEWorkspace!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("root-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Another window is open, so this workspace starts empty instead of restoring a session.
        keeper = IDEWorkspace()
        IDEWindowRegistry.shared.register(keeper)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IDERootView().environment(workspace))
        window.orderFront(nil)
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func write(_ name: String, lines: Int = 3_000) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let text = (0..<lines).map { "    int value\($0) = \($0); // line \($0)" }.joined(separator: "\n")
        try ("class C {\n" + text + "\n}\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let watched = [
        "IDERootView", "IDEToolbarPanel", "IDELeftSidebar", "IDEEditorLayoutNode", "IDEStatusBarPanel",
        "IDETerminalPanel", "IDEStatusToast", "IDEStatusPositionLabel",
    ]

    /// Body evaluations of every watched view while `work` runs.
    private func evaluations(_ label: String, _ work: () async -> Void) async -> [String: Int] {
        await settle()
        let before = IDEBodyDiagnostics.counts
        await work()
        await settle()
        var deltas: [String: Int] = [:]
        for name in Self.watched { deltas[name] = IDEBodyDiagnostics.count(name) - (before[name] ?? 0) }
        print("ROOTBODY \(label): " + Self.watched.map { "\($0)=\(deltas[$0] ?? 0)" }.joined(separator: " "))
        return deltas
    }

    /// While the user edits, only the position text follows the caret: nothing else is re-evaluated,
    /// and it is re-evaluated at most once per event.
    private func assertOnlyThePositionLabelMoves(
        _ deltas: [String: Int], events: Int, _ what: String, allowFirstEditChrome: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (view, count) in deltas where view != "IDEStatusPositionLabel" {
            // The first edit marks the document modified, which the toolbar and the breadcrumb show.
            let allowed = allowFirstEditChrome && (view == "IDEToolbarPanel" || view == "IDEStatusBarPanel") ? 1 : 0
            XCTAssertLessThanOrEqual(count, allowed, "\(what): \(view) was re-evaluated \(count) times", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(deltas["IDEStatusPositionLabel"] ?? 0, events + 1, "\(what): the label more than once per event", file: file, line: line)
    }

    func testEditingDoesNotReEvaluateTheRootView() async throws {
        let first = try write("First.java")
        await workspace.openDocument(from: first)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await settle(1.0)
        let textView = host.textView

        let typing = await evaluations("typing 40 characters") {
            for _ in 0..<40 { textView.insertText("x"); await Task.yield() }
        }
        assertOnlyThePositionLabelMoves(typing, events: 40, "typing", allowFirstEditChrome: true)
        XCTAssertGreaterThanOrEqual(typing["IDEStatusPositionLabel"] ?? 0, 40, "the position text follows every keystroke")

        var expectedColumn = 0
        let caret = await evaluations("moving the caret 40 times") {
            for index in 0..<40 {
                textView.selectedRange = NSRange(location: 200 + index * 37, length: 0)
                await Task.yield()
            }
            expectedColumn = workspace.statusColumn
        }
        assertOnlyThePositionLabelMoves(caret, events: 40, "caret moves")
        XCTAssertGreaterThanOrEqual(caret["IDEStatusPositionLabel"] ?? 0, 30, "the position text follows the caret")
        XCTAssertEqual(workspace.position.column, expectedColumn)
        XCTAssertEqual(workspace.statusColumn, workspace.position.column, "the forwarding properties read the same state")

        let scrolling = await evaluations("scrolling 60 steps") {
            for step in 0..<60 {
                textView.contentOffset = CGPoint(x: 0, y: CGFloat(step) * 120)
                textView.layoutIfNeeded()
                await Task.yield()
            }
        }
        assertOnlyThePositionLabelMoves(scrolling, events: 0, "scrolling")

        let enter = await evaluations("Enter 20 times") {
            for _ in 0..<20 { textView.insertText("\n"); await Task.yield() }
        }
        assertOnlyThePositionLabelMoves(enter, events: 20, "Enter")

        let selecting = await evaluations("selecting 20 ranges") {
            for index in 0..<20 {
                textView.selectedRange = NSRange(location: 300 + index * 53, length: 17)
                await Task.yield()
            }
        }
        assertOnlyThePositionLabelMoves(selecting, events: 20, "selections")
        XCTAssertEqual(workspace.position.selectionLength, 17)
    }

    /// Baseline for the events that legitimately change the chrome, to see what each costs.
    func testStructuralChangesAndWhatTheyCost() async throws {
        let first = try write("First.java", lines: 200)
        let second = try write("Second.java", lines: 200)
        await workspace.openDocument(from: first)
        await settle(1.0)
        _ = await evaluations("opening a second tab") { await workspace.openDocument(from: second) }
        _ = await evaluations("switching back to the first tab") { await workspace.openDocument(from: first) }
        _ = await evaluations("toggling the sidebar") { workspace.isSidebarVisible.toggle() }
        _ = await evaluations("toggling the bottom terminal") { workspace.isTerminalVisible.toggle() }
    }
}
