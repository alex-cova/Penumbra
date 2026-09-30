import AppKit
import SwiftUI

/// Every Umbra window owns one `IDEWorkspace`. The registry keeps weak references to them so code
/// with no view context (the app delegate, Dock and Finder opens) can find the window it should
/// act on, and it holds the few process-wide facts that used to be implied by "there is one
/// workspace": which window is restored next launch, whether the launch arguments were used, and
/// opens that arrived before any window existed. It is also where opening a folder or file is
/// routed to a window (`IDEOpenRouter` decides, the registry and workspaces act).
@MainActor
final class IDEWindowRegistry {
    static let shared = IDEWindowRegistry()

    private struct WeakWorkspace {
        weak var workspace: IDEWorkspace?
    }

    /// Most recently key first. A window that has not been key yet sits after the ones that have.
    private var entries: [WeakWorkspace] = []
    private var hasHandledLaunchArguments = false
    /// Set once the first window has registered. Before that (cold launch) an open waits for the
    /// restored window instead of asking for a new one, which would also stop it restoring.
    private var hasHadWindow = false

    private struct PendingOpen {
        let url: URL
        let origin: IDEOpenOrigin
    }

    /// Opens waiting for something they need: a window to exist, or SwiftUI's `openWindow` to be
    /// wired (cold launch, before the first window has appeared).
    private var pendingOpens: [PendingOpen] = []
    /// SwiftUI's `openWindow(id: "main")`, registered by `IDEWindowReopenBridge`.
    private var openWindowAction: (() -> Void)?
    /// One entry per window requested through `openNewWindow`, in request order; the next workspace
    /// to register takes the first and opens its URLs.
    private var newWindowJobs: [[URL]] = []
    /// The window a requested new window should join as a native tab, taken by its configurator.
    private var pendingTabParent: NSWindow?

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
        hasHadWindow = true
        // A window that is already key (the first one, or a new one brought forward) leads.
        let entry = WeakWorkspace(workspace: workspace)
        if workspace.window?.isKeyWindow == true {
            entries.insert(entry, at: 0)
        } else {
            entries.append(entry)
        }
        if !newWindowJobs.isEmpty {
            let urls = newWindowJobs.removeFirst()
            if !urls.isEmpty {
                workspace.openDroppedURLs(urls)
            }
        }
        drainPendingOpens()
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

    /// Moves a registered window to the front. A window that has not registered yet (it becomes key
    /// before its workspace finishes bootstrapping) is ignored: adding it here would make
    /// `register` skip it and would count it as open while it is still deciding whether to restore.
    func didBecomeActive(_ workspace: IDEWorkspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        entries.insert(WeakWorkspace(workspace: workspace), at: 0)
    }

    // MARK: - Session

    /// True while no other window is open: the window opening now restores the last window (launch,
    /// or Dock reopen after closing the last one). A window opened next to another starts empty, and
    /// so does one opened to show a folder or file the user just asked for.
    var shouldRestoreLastWindow: Bool {
        workspaces.isEmpty && newWindowJobs.allSatisfy(\.isEmpty)
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

    /// Routes folders and files to a window (see `IDEOpenRouter`). External opens (Dock, Finder,
    /// `open -a`) pass `.external`; requests made inside a window pass `.window(id)`. Anything that
    /// cannot be placed yet, because no window exists or `openWindow` is not wired, waits.
    func open(urls: [URL], origin: IDEOpenOrigin = .external) {
        pendingOpens.append(contentsOf: urls.map { PendingOpen(url: $0, origin: origin) })
        drainPendingOpens()
    }

    /// Shows the Open Folder panel and routes the chosen folder.
    func chooseFolder(from origin: IDEOpenOrigin) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            _ = url.startAccessingSecurityScopedResource()
            self?.open(urls: [url], origin: origin)
        }
    }

    func workspace(withID id: UUID) -> IDEWorkspace? {
        workspaces.first { $0.windowID == id }
    }

    private func makeRouter() -> IDEOpenRouter {
        let primary = activeWorkspace
        return IDEOpenRouter(
            windows: workspaces.map { workspace in
                IDEOpenWindow(
                    id: workspace.windowID,
                    projectRoot: workspace.project.rootURL,
                    isEmpty: workspace.isEmpty,
                    isPrimary: workspace === primary
                )
            },
            preference: IDEPreferences.shared.openFoldersIn
        )
    }

    private func drainPendingOpens() {
        let queue = pendingOpens
        pendingOpens = []
        var deferred: [PendingOpen] = []
        for item in queue where !route(item) {
            deferred.append(item)
        }
        pendingOpens = deferred + pendingOpens
    }

    /// Acts on the router's decision; false when it cannot be carried out yet.
    private func route(_ item: PendingOpen) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.url.path, isDirectory: &isDirectory) else {
            return true
        }
        // Cold launch: hold the open until the first window (the restored one) exists.
        guard hasHadWindow else { return false }
        let router = makeRouter()
        if isDirectory.boolValue {
            switch router.routeFolder(item.url, origin: item.origin) {
            case .focus(let id):
                workspace(withID: id)?.focusWindow()
            case .reuse(let id):
                workspace(withID: id)?.openProjectFolder(item.url)
            case .replace(let id):
                workspace(withID: id)?.replaceProject(with: item.url)
            case .askReplaceOrNew(let id):
                workspace(withID: id)?.askHowToOpenFolder(item.url)
            case .newWindow:
                return openNewWindow(urls: [item.url])
            }
        } else {
            switch router.routeFile(item.url) {
            case .window(let id):
                workspace(withID: id)?.openDroppedURLs([item.url])
            case .newWindow:
                return openNewWindow(urls: [item.url])
            }
        }
        return true
    }

    // MARK: - New windows

    /// Called by `IDEWindowReopenBridge` once SwiftUI's `openWindow` is available.
    func setOpenWindowAction(_ action: @escaping () -> Void) {
        openWindowAction = action
        drainPendingOpens()
    }

    /// Opens a window and gives it `urls` once it exists. With a `parent`, the new window joins
    /// that window's native tab group. False when `openWindow` is not wired yet.
    @discardableResult
    func openNewWindow(urls: [URL] = [], asTabOf parent: NSWindow? = nil) -> Bool {
        guard let openWindowAction else { return false }
        newWindowJobs.append(urls)
        pendingTabParent = parent
        openWindowAction()
        return true
    }

    /// File ▸ New Window Tab and the tab bar's + button.
    func openNewTab() {
        openNewWindow(asTabOf: activeWorkspace?.window)
    }

    /// Taken once by the new window's configurator, which adds itself to that tab group.
    func takePendingTabParent() -> NSWindow? {
        defer { pendingTabParent = nil }
        return pendingTabParent
    }

    /// Preferences (theme, font, layout toggles, zoom) are shared, so a change made in one window
    /// has to reach every window's editors. `workspace` is included even when it has not registered
    /// yet.
    func applyPreferencesToAllWindows(including workspace: IDEWorkspace) {
        var targets = workspaces
        if !targets.contains(where: { $0 === workspace }) {
            targets.append(workspace)
        }
        for target in targets {
            target.applyPreferencesToOwnHosts()
        }
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
