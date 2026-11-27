import AppKit
import SwiftUI
import Penumbra
import XCTest
@testable import Umbra

/// Two panes on one document (a split) show the same text and stay in step while either is edited.
///
/// Needs a window server: `UMBRA_UI_TESTS=1 swift test --filter IDEEditorSplitMirrorTests`
@MainActor
final class IDEEditorSplitMirrorTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var keeper: IDEWorkspace!
    private var window: NSWindow!
    private var directory: URL!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("split-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func panes() -> [EditorPane] { workspace.workbench.layout.flattenedPanes() }
    private func text(of pane: EditorPane) -> String { workspace.host(for: pane.id).textView.text }

    /// A click on the pane, as the host reports it.
    private func activate(_ pane: EditorPane) {
        workspace.host(for: pane.id).onActivated?()
    }

    private func openUntitledSplit(_ initial: String = "alpha\nbeta\n") async -> (EditorPane, EditorPane) {
        workspace.openUntitled(displayName: "Untitled", text: initial)
        await settle()
        workspace.splitRight()
        await settle()
        let all = panes()
        return (all[0], all[1])
    }

    func testBothPanesStartWithTheSameText() async throws {
        let (first, second) = await openUntitledSplit()
        XCTAssertEqual(text(of: first), "alpha\nbeta\n")
        XCTAssertEqual(text(of: second), "alpha\nbeta\n")
    }

    func testTypingInTheNewPaneShowsInTheFirst() async throws {
        let (first, second) = await openUntitledSplit()
        XCTAssertEqual(workspace.workbench.activePaneID, second.id)
        let textView = workspace.host(for: second.id).textView
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertText("XYZ")
        await settle()
        XCTAssertEqual(text(of: second), "alphaXYZ\nbeta\n")
        XCTAssertEqual(text(of: first), "alphaXYZ\nbeta\n")
    }

    func testTypingInTheFirstPaneShowsInTheSecond() async throws {
        let (first, second) = await openUntitledSplit()
        activate(first)
        await settle()
        XCTAssertEqual(workspace.workbench.activePaneID, first.id)
        let textView = workspace.host(for: first.id).textView
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("1 ")
        textView.insertText("2 ")
        await settle()
        XCTAssertEqual(text(of: first), "1 2 alpha\nbeta\n")
        XCTAssertEqual(text(of: second), "1 2 alpha\nbeta\n")
    }

    func testEditsFlowBothWaysAndKeepEachCaretOnItsText() async throws {
        let (first, second) = await openUntitledSplit()
        let secondView = workspace.host(for: second.id).textView
        let firstView = workspace.host(for: first.id).textView
        secondView.selectedRange = NSRange(location: 11, length: 0)   // end of "beta\n"
        firstView.selectedRange = NSRange(location: 6, length: 0)     // start of "beta"
        secondView.insertText("tail")
        await settle()
        activate(first)
        await settle()
        firstView.insertText("head ")
        await settle()
        XCTAssertEqual(text(of: first), "alpha\nhead beta\ntail")
        XCTAssertEqual(text(of: second), "alpha\nhead beta\ntail")
        // A caret in the other pane stays on the text it was on, not at the edit.
        XCTAssertEqual(secondView.selectedRange.location, 20)
    }

    func testDeleteAndUndoReachBothPanes() async throws {
        let (first, second) = await openUntitledSplit()
        let secondView = workspace.host(for: second.id).textView
        secondView.selectedRange = NSRange(location: 5, length: 0)
        secondView.deleteBackward()
        await settle()
        XCTAssertEqual(text(of: first), "alph\nbeta\n")
        XCTAssertEqual(text(of: second), "alph\nbeta\n")
        secondView.undoManager?.undo()
        await settle()
        XCTAssertEqual(text(of: second), "alpha\nbeta\n")
        XCTAssertEqual(text(of: first), "alpha\nbeta\n", "undo in one pane is undone in the other")
    }

    func testFileBackedDocumentMirrorsToo() async throws {
        let url = directory.appendingPathComponent("Note.txt")
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        await settle(1.0)
        workspace.splitRight()
        await settle(1.0)
        let all = panes()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(text(of: all[0]), "one\ntwo\n")
        XCTAssertEqual(text(of: all[1]), "one\ntwo\n")
        let view = workspace.host(for: all[1].id).textView
        view.selectedRange = NSRange(location: 3, length: 0)
        view.insertText("!")
        await settle()
        XCTAssertEqual(text(of: all[0]), "one!\ntwo\n")
        XCTAssertEqual(text(of: all[1]), "one!\ntwo\n")
        XCTAssertTrue(workspace.workbench.activePane.selectedDocument?.isDirty ?? false)
    }

    func testClosingAPaneKeepsTheEdits() async throws {
        let (first, second) = await openUntitledSplit()
        let secondView = workspace.host(for: second.id).textView
        secondView.selectedRange = NSRange(location: 0, length: 0)
        secondView.insertText("new ")
        await settle()
        workspace.closeActivePane()
        await settle()
        XCTAssertEqual(panes().count, 1)
        XCTAssertEqual(text(of: first), "new alpha\nbeta\n")
    }
}
