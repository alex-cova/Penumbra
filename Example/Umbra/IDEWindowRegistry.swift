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

    private var entries: [WeakWorkspace] = []
    private weak var lastActive: IDEWorkspace?
    /// The workspace that restored, and therefore writes, `session.json`. Until persistence is
    /// split per window, one workspace at a time may own it; a second window starts empty and
    /// never writes it, or two windows would overwrite each other's project and tabs.
    private weak var sessionOwner: IDEWorkspace?
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
        if let lastActive, workspaces.contains(where: { $0 === lastActive }) {
            return lastActive
        }
        return workspaces.last
    }

    func workspace(for window: NSWindow) -> IDEWorkspace? {
        workspaces.first { $0.window === window }
    }

    func register(_ workspace: IDEWorkspace) {
        guard !workspaces.contains(where: { $0 === workspace }) else { return }
        entries.append(WeakWorkspace(workspace: workspace))
        if lastActive == nil {
            lastActive = workspace
        }
        drainPendingOpenURLs()
    }

    /// Called when the workspace's window closes. Releases the session, so a window opened later
    /// (Dock reopen after closing the last one) restores what the closed window saved.
    func unregister(_ workspace: IDEWorkspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        if sessionOwner === workspace {
            sessionOwner = nil
        }
        if lastActive === workspace {
            lastActive = nil
        }
    }

    func didBecomeActive(_ workspace: IDEWorkspace) {
        lastActive = workspace
    }

    // MARK: - Session ownership

    /// True for the first workspace to ask while nobody owns the session; that workspace restores
    /// and saves it. Everyone else gets an empty window.
    func claimSession(for workspace: IDEWorkspace) -> Bool {
        guard sessionOwner == nil else { return sessionOwner === workspace }
        sessionOwner = workspace
        return true
    }

    func ownsSession(_ workspace: IDEWorkspace) -> Bool {
        sessionOwner === workspace
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

    func saveSessionsForTermination() {
        for workspace in workspaces {
            workspace.saveSession()
        }
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
