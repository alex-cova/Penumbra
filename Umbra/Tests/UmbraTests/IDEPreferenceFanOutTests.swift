import Foundation
import XCTest
@testable import Umbra

/// A preference changed in one window's Settings or menus must reach the editors of every window.
@MainActor
final class IDEPreferenceFanOutTests: XCTestCase {
    private var originalShowMinimap = false
    private var originalTabWidth = 4
    private var registered: [IDEWorkspace] = []

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        // `IDEPreferences.shared` writes every change to `UserDefaults.standard`; put back what
        // the developer had so running the tests does not change their settings.
        originalShowMinimap = IDEPreferences.shared.showMinimap
        originalTabWidth = IDEPreferences.shared.tabWidth
    }

    override func tearDown() {
        IDEPreferences.shared.showMinimap = originalShowMinimap
        IDEPreferences.shared.tabWidth = originalTabWidth
        for workspace in registered {
            IDEWindowRegistry.shared.unregister(workspace)
        }
        registered = []
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    /// A bootstrapped, registered window. The first one registered stands in for "another window is
    /// open", so the ones after it start empty instead of restoring.
    private func makeWindow() -> IDEWorkspace {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        registered.append(workspace)
        return workspace
    }

    private func editor(of workspace: IDEWorkspace) -> TextViewProbe {
        let textView = workspace.host(for: workspace.activePaneID).textView
        return TextViewProbe(showMinimap: textView.showMinimap)
    }

    private struct TextViewProbe {
        let showMinimap: Bool
    }

    func testAPreferenceChangedFromOneWindowReachesEveryWindow() {
        let keeper = makeWindow()
        let first = makeWindow()
        let second = makeWindow()
        let newValue = !IDEPreferences.shared.showMinimap

        IDEPreferences.shared.showMinimap = newValue
        first.applyPreferencesToAllHosts()

        XCTAssertEqual(editor(of: keeper).showMinimap, newValue)
        XCTAssertEqual(editor(of: first).showMinimap, newValue)
        XCTAssertEqual(editor(of: second).showMinimap, newValue)
    }

    func testAWindowThatHasNotRegisteredYetIsStillUpdated() {
        _ = makeWindow()
        let unregistered = IDEWorkspace()
        unregistered.bootstrap()
        defer { unregistered.teardown() }
        let newValue = !IDEPreferences.shared.showMinimap

        IDEPreferences.shared.showMinimap = newValue
        unregistered.applyPreferencesToAllHosts()

        XCTAssertEqual(editor(of: unregistered).showMinimap, newValue)
    }

    func testATornDownWindowIsSkippedWithoutCrashing() {
        let survivor = makeWindow()
        let closing = makeWindow()
        closing.windowWillClose()
        let newValue = !IDEPreferences.shared.showMinimap

        IDEPreferences.shared.showMinimap = newValue
        survivor.applyPreferencesToAllHosts()

        XCTAssertEqual(editor(of: survivor).showMinimap, newValue)
    }
}
