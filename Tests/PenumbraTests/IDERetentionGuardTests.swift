import AppKit
import Foundation
import XCTest
@testable import Umbra

/// Guards for the three things that kept a closed window's workspace (its editors, index and
/// watchers) alive in the running app: the close guard not forwarding delegate messages, menu
/// closures capturing the workspace, and terminal callbacks capturing it.
@MainActor
final class IDERetentionGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    // MARK: - Close guard forwards to SwiftUI's delegate

    private final class StubDelegate: NSObject, NSWindowDelegate {
        var willCloseCount = 0
        var didResizeCount = 0
        var shouldClose = true
        var shouldCloseCount = 0

        func windowWillClose(_ notification: Notification) { willCloseCount += 1 }
        func windowDidResize(_ notification: Notification) { didResizeCount += 1 }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCount += 1
            return shouldClose
        }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    /// The stub is held by the test: the guard's reference to the original delegate is weak on
    /// purpose (a strong one would keep SwiftUI's window controller alive after the window closes).
    func testTheCloseGuardForwardsMessagesItDoesNotHandleToTheOriginalDelegate() {
        let window = makeWindow()
        let stub = StubDelegate()
        window.delegate = stub
        let closeGuard = IDEWindowCloseGuard()
        closeGuard.install(on: window)

        let delegate = try! XCTUnwrap(window.delegate)
        XCTAssertTrue(delegate === closeGuard)
        XCTAssertTrue(closeGuard.responds(to: #selector(NSWindowDelegate.windowWillClose(_:))))
        XCTAssertTrue(closeGuard.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))

        delegate.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: window))
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))

        // Without this SwiftUI never hears the window closed and keeps its scene, hosting view and
        // workspace alive for the rest of the run.
        XCTAssertEqual(stub.willCloseCount, 1)
        XCTAssertEqual(stub.didResizeCount, 1)
    }

    func testTheCloseGuardDoesNotRespondToWhatNeitherItNorTheOriginalDelegateImplements() {
        let window = makeWindow()
        let stub = StubDelegate()
        window.delegate = stub
        let closeGuard = IDEWindowCloseGuard()
        closeGuard.install(on: window)

        XCTAssertFalse(closeGuard.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
    }

    func testTheOriginalDelegateCanVetoClosing() {
        let window = makeWindow()
        let stub = StubDelegate()
        stub.shouldClose = false
        window.delegate = stub
        let closeGuard = IDEWindowCloseGuard()
        // The guard holds its workspace weakly.
        let workspace = IDEWorkspace()
        closeGuard.workspace = workspace
        closeGuard.install(on: window)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(stub.shouldCloseCount, 1)

        stub.shouldClose = true
        XCTAssertTrue(closeGuard.windowShouldClose(window))
        withExtendedLifetime(workspace) {}
    }

    // MARK: - Menu views reach the workspace only through the weak handle

    private func source(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        // Tests/PenumbraTests/<this file> -> repository root.
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func codeLines(_ text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { offset, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? nil : (offset + 1, String(line))
        }
    }

    /// SwiftUI keeps menu items and their action closures after a window closes, so anything they
    /// hold outlives it. The menu views hold a weak handle (`IDEWorkspaceRef`) and read the
    /// workspace at the moment they use it, through an optional property.
    func testMenuViewsNeverHoldOrBindTheWorkspace() throws {
        let lines = codeLines(try source("Example/Umbra/IDEAppCommands.swift"))
        var problems: [String] = []

        for (number, line) in lines {
            if line.contains("IDEWorkspace.placeholder") {
                problems.append("\(number): uses IDEWorkspace.placeholder")
            }
            // A stored workspace.
            if line.range(of: #"^\s*(let|var)\s+workspace\s*:\s*IDEWorkspace\??\s*$"#, options: .regularExpression) != nil {
                problems.append("\(number): stores a workspace")
            }
            // Member access on a non-optional `workspace` (only `workspace?.x` and `workspace.map`).
            if line.range(of: #"(?<![\w?.!])workspace\.(?!map\b)[A-Za-z]"#, options: .regularExpression) != nil {
                problems.append("\(number): non-optional workspace access: \(line.trimmingCharacters(in: .whitespaces))")
            }
            // `ref.workspace` may only feed the optional property or the JDK menu's environment.
            if line.contains("ref.workspace") || line.contains("ref?.workspace") {
                let isProperty = line.range(of: #"var workspace: IDEWorkspace\? \{ ref\??\.workspace \}"#, options: .regularExpression) != nil
                let isJDKMenu = line.contains("if let workspace = ref.workspace {")
                if !isProperty && !isJDKMenu {
                    problems.append("\(number): binds the workspace: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertTrue(problems.isEmpty, "menu code may keep a window's workspace alive:\n" + problems.joined(separator: "\n"))
    }

    func testTheGuardSeesWhatItIsMeantToCatch() {
        // The rules above are regular expressions; make sure they match the mistakes they name.
        let bad = [
            "    let workspace: IDEWorkspace",
            "        Button(\"Go\", action: { workspace.showQuickOpen() })",
            "    private var workspace: IDEWorkspace { ref.workspace ?? IDEWorkspace.placeholder }"
        ]
        XCTAssertNotNil(bad[0].range(of: #"^\s*(let|var)\s+workspace\s*:\s*IDEWorkspace\??\s*$"#, options: .regularExpression))
        XCTAssertNotNil(bad[1].range(of: #"(?<![\w?.!])workspace\.(?!map\b)[A-Za-z]"#, options: .regularExpression))
        XCTAssertTrue(bad[2].contains("IDEWorkspace.placeholder"))
        let good = "        Button(\"Go\", action: { workspace?.showQuickOpen() })"
        XCTAssertNil(good.range(of: #"(?<![\w?.!])workspace\.(?!map\b)[A-Za-z]"#, options: .regularExpression))
    }

    // MARK: - Terminal

    /// A running shell keeps its terminal view alive, so a callback that captures the workspace
    /// strongly keeps the whole window alive through it.
    func testTerminalCallbacksInThePanelCaptureTheWorkspaceWeakly() throws {
        let lines = codeLines(try source("Example/Umbra/IDETerminalPanel.swift"))
        let callbacks = lines.filter {
            $0.text.contains("onTitleUpdate: {")
                || $0.text.contains("onDirectoryUpdate: {")
                || $0.text.contains("onHostCreated: {")
        }
        XCTAssertGreaterThanOrEqual(callbacks.count, 3, "the panel's terminal callbacks moved; update this guard")
        for callback in callbacks {
            XCTAssertTrue(
                callback.text.contains("[weak workspace = workspace]"),
                "line \(callback.number) captures the workspace strongly: \(callback.text.trimmingCharacters(in: .whitespaces))"
            )
        }
    }

    func testATerminalHostViewIsFreedWhenNothingReferencesIt() {
        weak var weakView: IDETerminalHostView?
        autoreleasepool {
            let view = IDETerminalHostView(frame: .zero)
            view.onTitleUpdate = { _ in }
            view.onDirectoryUpdate = { _ in }
            weakView = view
        }
        XCTAssertNil(weakView, "the terminal host view keeps itself alive (its coordinator or callbacks)")
    }
}
