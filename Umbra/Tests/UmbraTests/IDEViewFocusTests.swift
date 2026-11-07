import AppKit
import SwiftUI
import XCTest

@testable import Umbra

@MainActor
private final class FocusProbeState {
    var focused = false
    var asks = 0
}

/// A focusable view driven by `ideFocus(onRequest:)`, with a second binding that reports whether
/// SwiftUI considers it focused. A decoy comes first, so it is the default focus and the target is
/// focused only when a request lands (a lone focusable view is focused on mount).
private struct FocusProbe: View {
    let state: FocusProbeState
    let requestID: UInt64
    let consume: () -> Bool
    @FocusState private var observed: Bool
    @FocusState private var decoyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 20)
                .focusable()
                .focused($decoyFocused)
            Color.clear.frame(height: 20)
                .focusable()
                .ideFocus(onRequest: requestID, consume: consume)
                .focused($observed)
                .onChange(of: observed) { _, now in state.focused = now }
        }
        .onAppear { decoyFocused = true }
    }
}

/// Views that take the keyboard when a workspace focus request lands, hosted in a real window.
/// `IDESidebarFocusTests` holds the workspace's side (which tab is pending); these hold the other
/// half: that SwiftUI's focus really moves, once per request, and not on a plain mount or for a
/// request meant for another tab.
///
/// Needs a window server, so it runs only with `UMBRA_UI_TESTS=1`:
/// `UMBRA_UI_TESTS=1 caffeinate -u -d -i -s swift test --package-path Umbra --filter IDEViewFocusTests`
@MainActor
final class IDEViewFocusTests: XCTestCase {
    private var window: NSWindow!
    private var hosting: NSHostingView<AnyView>!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        hosting = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func host(_ view: some View) {
        hosting = NSHostingView(rootView: AnyView(view.frame(width: 300, height: 200)))
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
    }

    private func show(_ view: some View) {
        hosting.rootView = AnyView(view.frame(width: 300, height: 200))
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        hosting.layoutSubtreeIfNeeded()
    }

    // MARK: - The shared modifier

    func testAConsumedRequestMovesFocusToTheView() async {
        let state = FocusProbeState()
        host(FocusProbe(state: state, requestID: 0) { state.asks += 1; return false })
        await settle()
        XCTAssertFalse(state.focused, "a mount with nothing pending leaves focus alone")

        show(FocusProbe(state: state, requestID: 1) { state.asks += 1; return true })
        await settle()

        XCTAssertTrue(state.focused)
        XCTAssertEqual(state.asks, 2, "asked once on mount and once for the request, not on every update")
    }

    func testARequestThatIsNotForThisViewDoesNotTakeFocus() async {
        let state = FocusProbeState()
        host(FocusProbe(state: state, requestID: 0) { false })
        await settle()

        show(FocusProbe(state: state, requestID: 1) { state.asks += 1; return false })
        await settle()

        XCTAssertEqual(state.asks, 1, "the view was asked")
        XCTAssertFalse(state.focused, "and declined, so another tab's request cannot steal focus")
    }

    func testASecondRequestFiresAfterTheFirstWasConsumed() async {
        let state = FocusProbeState()
        host(FocusProbe(state: state, requestID: 0) { false })
        await settle()
        show(FocusProbe(state: state, requestID: 1) { true })
        await settle()
        XCTAssertTrue(state.focused)

        show(FocusProbe(state: state, requestID: 2) { state.asks += 1; return true })
        await settle()

        XCTAssertEqual(state.asks, 1, "a new request id is asked even though the last one was consumed")
    }

    // MARK: - A real panel

    private func workspaceWithSidebar() throws -> (IDEWorkspace, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("view-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(directory)
        workspace.isSidebarVisible = true
        return (workspace, directory)
    }

    /// SwiftUI's focus state of a panel's inner list is not observable from outside, so these check
    /// the wiring: the mounted panel asks the workspace, and takes only its own tab's request.
    func testTheBookmarksPanelConsumesOnlyItsOwnShortcutRequest() async throws {
        let (workspace, directory) = try workspaceWithSidebar()
        defer {
            workspace.windowWillClose()
            try? FileManager.default.removeItem(at: directory)
        }
        host(IDEBookmarksPanel().environment(workspace))
        await settle()
        XCTAssertNil(workspace.pendingSidebarFocusTab)

        // Structure's shortcut: a mounted Bookmarks panel must leave it alone.
        workspace.pendingSidebarFocusTab = .structure
        workspace.sidebarFocusRequestID += 1
        await settle()
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .structure, "not Bookmarks' request")

        workspace.pendingSidebarFocusTab = .bookmarks
        workspace.sidebarFocusRequestID += 1
        await settle()
        XCTAssertNil(workspace.pendingSidebarFocusTab, "Bookmarks' own request is consumed by its view")
    }

    func testAPanelMountedByAShortcutConsumesTheRequestOnAppear() async throws {
        let (workspace, directory) = try workspaceWithSidebar()
        defer {
            workspace.windowWillClose()
            try? FileManager.default.removeItem(at: directory)
        }
        // The shortcut switches tabs: the request exists before the new tab's view does.
        workspace.pendingSidebarFocusTab = .bookmarks
        workspace.sidebarFocusRequestID += 1

        host(IDEBookmarksPanel().environment(workspace))
        await settle()

        XCTAssertNil(workspace.pendingSidebarFocusTab)
    }
}
