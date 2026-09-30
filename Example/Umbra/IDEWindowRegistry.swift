import AppKit
import SwiftUI

/// Every Umbra window owns one `IDEWorkspace`. The registry keeps weak references to them so code
/// with no view context (the app delegate, Dock and Finder opens) can find the window it should
/// act on, and it holds the few process-wide facts that used to be implied by "there is one
/// workspace": who restores `session.json`, whether the launch arguments were used, and URLs that
/// arrived before any window existed.
@MainActor
final class IDEWindowRegistry {
    static let shared = IDEWindowRegistry()

    private struct WeakWorkspace {
        weak var workspace: IDEWorkspace?
    }

    /// Most recently key first. A window that has not been key yet sits after the ones that have.
    private var entries: [WeakWorkspace] = []
    private var hasHandledLaunchArguments = false
    /// Folders/files handed over by Finder or the Dock before any window was ready (cold launch).
    private var pendingOpenURLs: [URL] = []

    private init() {}

    var workspaces: [IDEWorkspace] {
        entries.removeAll { $0.workspace == nil }
        return entries.compactMap(\.workspace)
    }

    /// The workspace of the key window (following a sheet up to its parent), else the one that was
    /// key last, else any.
    var activeWorkspace: IDEWorkspace? {
        var window = NSApp.keyWindow
        while let current = window {
            if let workspace = workspace(for: current) {
                return workspace
            }
            window = current.sheetParent
        }
        return workspaces.first
    }

    func workspace(for window: NSWindow) -> IDEWorkspace? {
        workspaces.first { $0.window === window }
    }

    func register(_ workspace: IDEWorkspace) {
        guard !workspaces.contains(where: { $0 === workspace }) else { return }
        entries.append(WeakWorkspace(workspace: workspace))
        drainPendingOpenURLs()
    }

    /// Called when the workspace's window closes. When it was the session window and another
    /// window with content remains, that one takes over and saves its layout right away, so "the
    /// last window" stays a window that is still open. With none left the closed window's own
    /// save (made as it closed) stands.
    func unregister(_ workspace: IDEWorkspace) {
        let wasSessionWindow = sessionWindow === workspace
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        if wasSessionWindow {
            sessionWindow?.saveSession()
        }
    }

    func didBecomeActive(_ workspace: IDEWorkspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        entries.insert(WeakWorkspace(workspace: workspace), at: 0)
    }

    // MARK: - Session

    /// True while no other window is open: the window opening now restores the last window (launch,
    /// or Dock reopen after closing the last one). A window opened next to another starts empty.
    var shouldRestoreLastWindow: Bool {
        workspaces.isEmpty
    }

    /// The window whose layout is saved to `last-window.json` and restored at the next launch: the
    /// one that was key last, skipping pristine windows. A blank window opened next to others must
    /// not replace the project you were working in just because you clicked into it.
    var sessionWindow: IDEWorkspace? {
        workspaces.first { !$0.isPristine }
    }

    func isSessionWindow(_ workspace: IDEWorkspace) -> Bool {
        sessionWindow === workspace
    }

    // MARK: - Launch and external opens

    /// `--open` / `--open-folder` apply to the first window only, once per process.
    func consumeLaunchArguments() -> Bool {
        guard !hasHandledLaunchArguments else { return false }
        hasHandledLaunchArguments = true
        return true
    }

    /// Opens Finder/Dock URLs in the active window, or holds them until a window registers.
    func open(urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        drainPendingOpenURLs()
    }

    private func drainPendingOpenURLs() {
        guard !pendingOpenURLs.isEmpty, let target = activeWorkspace else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        target.openDroppedURLs(urls)
    }

    /// On quit: the shared lists, and the layout of the window that was active last.
    func saveSessionsForTermination() {
        IDEAppState.shared.save()
        sessionWindow?.saveSession()
    }
}

/// The focused window's workspace, for menu commands (`IDEAppCommands`).
private struct IDEWorkspaceFocusedKey: FocusedValueKey {
    typealias Value = IDEWorkspace
}

extension FocusedValues {
    var ideWorkspace: IDEWorkspace? {
        get { self[IDEWorkspaceFocusedKey.self] }
        set { self[IDEWorkspaceFocusedKey.self] = newValue }
    }
}
