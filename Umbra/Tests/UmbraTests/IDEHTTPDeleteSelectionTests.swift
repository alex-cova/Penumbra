import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

/// An `.http` file in a real workspace editor (the user's preferences: keymap, Metal, minimap,
/// occurrence highlighting): a double-clicked method deleted with Backspace leaves a caret.
@MainActor
final class IDEHTTPDeleteSelectionTests: XCTestCase {
    func testDeletingADoubleClickedMethodCollapsesTheSelection() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("http-delete-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("stock.http")
        let first = "GET https://api.sicarx.com/stock/v1/medications?sku=7501125103049\n"
        let request = first + "\n###\n\nGET https://api.sicarx.com/stock/v1/medications?sku=1\n\n###\n\nGET https://api.sicarx.com/stock/v1/medications?sku=2\n"
        try request.write(to: file, atomically: true, encoding: .utf8)

        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.project.setRoot(project)
        workspace.bootstrap()
        await workspace.openDocument(from: file)
        try await Task.sleep(nanoseconds: 500_000_000)

        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        textView.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        _ = textView.focusTextInput()
        try await Task.sleep(nanoseconds: 300_000_000)

        let caret = textView.caretRectInViewport(at: 1)
        let inWindow = textView.convert(CGPoint(x: caret.midX, y: caret.midY), to: nil)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(inWindow, from: nil)))
        func mouse(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        hit.mouseDown(with: mouse(.leftMouseDown, 1))
        hit.mouseUp(with: mouse(.leftMouseUp, 1))
        hit.mouseDown(with: mouse(.leftMouseDown, 2))
        hit.mouseUp(with: mouse(.leftMouseUp, 2))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences).count, 3)

        send(keyEvent(keyCode: TestKeyCode.delete, characters: "\u{7F}"), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(textView.text as String, String(request.dropFirst(3)))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.selectionRectsForTesting.isEmpty)
        XCTAssertEqual(textView.emphasisManager.getEmphases(for: EmphasisGroup.occurrences), [])
    }
}
