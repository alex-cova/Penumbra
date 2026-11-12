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
        var aiOpen: IDEAIOpenRequest?
    }

    private struct NewWindowJob {
        var urls: [URL]
        var aiOpen: IDEAIOpenRequest?
        /// A window that was open at the last quit, to be reopened as it was. Taken by that
        /// window's `bootstrap` (`takeRestoreSession`), never by `register`.
        var restore: IDEWindowSession?
    }

    /// Opens waiting for something they need: a window to exist, or SwiftUI's `openWindow` to be
    /// wired (cold launch, before the first window has appeared).
    private var pendingOpens: [PendingOpen] = []
    /// SwiftUI's `openWindow(id: "main")`, registered by `IDEWindowReopenBridge`.
    private var openWindowAction: (() -> Void)?
    /// One entry per window requested through `openNewWindow`, in request order; the next workspace
    /// to register takes the first and opens its URLs.
    private var newWindowJobs: [NewWindowJob] = []
    /// Windows to reopen after the first one restored, waiting for `openWindow` to be wired.
    private var pendingRestoredSessions: [IDEWindowSession] = []
    /// The window a requested new window should join as a native tab, taken by its configurator.
    private var pendingTabParent: NSWindow?
    /// Set by a Dock reopen with no window left: the next window to appear is centered on screen
    /// instead of taking SwiftUI's saved or cascaded position.
    private var centersNextWindow = false
    /// Quitting is going ahead. `noteTermination` has stored every window; a window that closes
    /// after that must not change what was stored.
    private(set) var isTerminating = false

    private init() {
        // Saving when Umbra loses the focus (Settings ▸ Saving). One observer for every window: a
        // window that has nothing unsaved does nothing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.workspaces.forEach { $0.autosaveBecauseFocusMoved() }
            }
        }
    }

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

    /// `restoredFromJob`: the window took one of the queued restore jobs in `bootstrap`, so it is
    /// not also the window a queued folder or file request is waiting for.
    func register(_ workspace: IDEWorkspace, restoredFromJob: Bool = false) {
        guard !workspaces.contains(where: { $0 === workspace }) else { return }
        hasHadWindow = true
        let current = workspaces
        entries.append(WeakWorkspace(workspace: workspace))
        reorder(IDESessionWindowPolicy.registered(
            workspace.windowID,
            isKey: workspace.window?.isKeyWindow == true,
            in: current.map(\.windowID)
        ))
        if !restoredFromJob, let index = newWindowJobs.firstIndex(where: { $0.restore == nil }) {
            let job = newWindowJobs.remove(at: index)
            if !job.urls.isEmpty {
                workspace.pendingAIOpen = job.aiOpen
                workspace.openDroppedURLs(job.urls)
            }
        }
        drainPendingOpens()
    }

    /// Called when the workspace's window closes. Its stored entry was already dealt with as it
    /// closed (`IDEWorkspace.saveSessionForWindowClose`): dropped, or kept with the folder closed
    /// when it was the last window with content.
    func unregister(_ workspace: IDEWorkspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        IDESettingsPresentation.shared.workspaceDidClose(workspace)
    }

    /// Quitting has been confirmed. Call before any window closes: this stores every window with
    /// its project and tabs, most recently key first, so the next launch brings them all back. The
    /// windows that close after it leave the stored list alone (`isTerminating`).
    func noteTermination() {
        isTerminating = true
        guard IDEWorkspace.isSessionPersistenceEnabled else { return }
        IDEWindowSessionStore.replaceAll(Self.sessionsForTermination(of: workspaces))
    }

    /// What quitting stores: every window that has been used, in the order given (most recently key
    /// first), with its project and tabs as they are. A blank window opened beside others is left out.
    static func sessionsForTermination(of workspaces: [IDEWorkspace]) -> [IDEWindowSession] {
        workspaces.filter { !$0.isPristine }.map { $0.makeSession() }
    }

    /// True when this window is the last one with content, so it closes with its folder forgotten
    /// and a Dock click opens the Welcome screen. Any other window just drops its stored entry.
    func forgetsFolderWhenClosing(_ workspace: IDEWorkspace) -> Bool {
        guard isSessionWindow(workspace) else { return false }
        return IDESessionWindowPolicy.successor(afterClosing: workspace.windowID, in: policyWindows) == nil
    }

    /// Moves a registered window to the front. A window that has not registered yet (it becomes key
    /// before its workspace finishes bootstrapping) is ignored: adding it here would make
    /// `register` skip it and would count it as open while it is still deciding whether to restore.
    func didBecomeActive(_ workspace: IDEWorkspace) {
        reorder(IDESessionWindowPolicy.activated(workspace.windowID, in: workspaces.map(\.windowID)))
    }

    /// Puts the entries in the order of `ids`, dropping closed windows.
    private func reorder(_ ids: [UUID]) {
        let current = workspaces
        entries = ids.compactMap { id in
            current.first { $0.windowID == id }.map { WeakWorkspace(workspace: $0) }
        }
    }

    private var policyWindows: [IDESessionWindowPolicy.Window] {
        workspaces.map { IDESessionWindowPolicy.Window(id: $0.windowID, isPristine: $0.isPristine) }
    }

    // MARK: - Session

    /// True while no other window is open: the window opening now restores the last window (launch,
    /// or Dock reopen after closing the last one). A window opened next to another starts empty, and
    /// so does one opened to show a folder or file the user just asked for.
    var shouldRestoreLastWindow: Bool {
        IDESessionWindowPolicy.shouldRestoreLastWindow(
            openWindowCount: workspaces.count,
            pendingNewWindowJobs: newWindowJobs.filter { !$0.urls.isEmpty }.count
        )
    }

    /// The window that was key last, skipping pristine ones: the one whose stored entry leads the
    /// list, and the last window with content when it closes. A blank window opened next to others
    /// must not count just because you clicked into it.
    var sessionWindow: IDEWorkspace? {
        IDESessionWindowPolicy.sessionWindow(in: policyWindows).flatMap { workspace(withID: $0) }
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
    func open(urls: [URL], origin: IDEOpenOrigin = .external, aiOpen: IDEAIOpenRequest? = nil) {
        pendingOpens.append(contentsOf: urls.map { PendingOpen(url: $0, origin: origin, aiOpen: aiOpen) })
        drainPendingOpens()
    }

    /// Shows the Open Folder panel and routes the chosen folder.
    func chooseFolder(from origin: IDEOpenOrigin, aiOpen: IDEAIOpenRequest? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            // The panel already grants access to what it returns; the workspace that opens the
            // folder holds it from there (`IDESecurityScopedAccess`).
            guard result == .OK, let url = panel.url else { return }
            self?.open(urls: [url], origin: origin, aiOpen: aiOpen)
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
                let target = workspace(withID: id)
                target?.focusWindow()
                // The folder is already open there: apply the AI request at once.
                if let request = item.aiOpen { target?.applyAIOpen(request) }
            case .reuse(let id):
                let target = workspace(withID: id)
                target?.pendingAIOpen = item.aiOpen
                target?.openProjectFolder(item.url)
            case .replace(let id):
                let target = workspace(withID: id)
                target?.pendingAIOpen = item.aiOpen
                target?.replaceProject(with: item.url)
            case .askReplaceOrNew(let id):
                let target = workspace(withID: id)
                target?.pendingAIOpen = item.aiOpen
                target?.askHowToOpenFolder(item.url)
            case .newWindow:
                return openNewWindow(urls: [item.url], aiOpen: item.aiOpen)
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

    /// Unwires `openWindow` and forgets queued restores, so a test that wired a fake leaves the shared
    /// registry as it found it.
    func resetOpeningForTests() {
        openWindowAction = nil
        pendingRestoredSessions = []
        newWindowJobs = []
    }

    /// Called by `IDEWindowReopenBridge` once SwiftUI's `openWindow` is available.
    func setOpenWindowAction(_ action: @escaping () -> Void) {
        openWindowAction = action
        drainRestoredWindows()
        drainPendingOpens()
    }

    /// Opens a window and gives it `urls` once it exists. With a `parent`, the new window joins
    /// that window's native tab group. False when `openWindow` is not wired yet.
    @discardableResult
    func openNewWindow(urls: [URL] = [], asTabOf parent: NSWindow? = nil, aiOpen: IDEAIOpenRequest? = nil) -> Bool {
        guard let openWindowAction else { return false }
        newWindowJobs.append(NewWindowJob(urls: urls, aiOpen: aiOpen))
        pendingTabParent = parent
        openWindowAction()
        return true
    }

    // MARK: - Restoring every window

    /// The first window has restored the first stored window; this opens one more window for each of
    /// the others. They wait for `openWindow` when it is not wired yet (cold launch).
    func queueRestoredWindows(_ sessions: [IDEWindowSession]) {
        pendingRestoredSessions.append(contentsOf: sessions)
        drainRestoredWindows()
    }

    private func drainRestoredWindows() {
        guard let openWindowAction, !pendingRestoredSessions.isEmpty else { return }
        let sessions = pendingRestoredSessions
        pendingRestoredSessions = []
        for session in sessions {
            newWindowJobs.append(NewWindowJob(urls: [], aiOpen: nil, restore: session))
            openWindowAction()
        }
    }

    /// Called by a window's `bootstrap`: the stored window it is to become, if one was queued for it.
    func takeRestoreSession() -> IDEWindowSession? {
        guard let index = newWindowJobs.firstIndex(where: { $0.restore != nil }) else { return nil }
        return newWindowJobs.remove(at: index).restore
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

    /// Opens a window for a Dock click with every window closed, and centers it on screen.
    func openWindowForReopen(_ open: () -> Void) {
        centersNextWindow = true
        open()
    }

    /// Taken once by the new window's configurator.
    func takeCentersNextWindow() -> Bool {
        defer { centersNextWindow = false }
        return centersNextWindow
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

    /// The Markdown preview's light/dark choice was flipped in one window; the others follow.
    func applyMarkdownPreviewAppearanceToAllWindows(including workspace: IDEWorkspace) {
        var targets = workspaces
        if !targets.contains(where: { $0 === workspace }) {
            targets.append(workspace)
        }
        for target in targets {
            target.applyMarkdownPreviewAppearanceToOwnHosts()
        }
    }

    /// Like `applyPreferencesToAllWindows`, for the settings that live below the text views.
    func applyCodeInsightPreferencesToAllWindows(including workspace: IDEWorkspace) {
        var targets = workspaces
        if !targets.contains(where: { $0 === workspace }) {
            targets.append(workspace)
        }
        for target in targets {
            target.applyCodeInsightPreferences()
        }
    }

    /// Whether any window has an editor with unsaved changes.
    var hasUnsavedDocuments: Bool { workspaces.contains { $0.hasUnsavedDocuments } }

    /// Quitting saves every window's unsaved editors, then asks once about the ones that could not
    /// be saved (untitled buffers, files changed on disk), where closing each window would ask per
    /// window. Nothing to ask when everything is saved.
    func confirmQuit() async -> Bool {
        for workspace in workspaces where workspace.hasUnsavedDocuments {
            _ = await workspace.saveAll(reason: .quitting)
        }
        let details = workspaces.flatMap { $0.unsavedChangeLines() }.filter { $0.contains("changed bytes") }
        guard let text = Self.quitPromptText(
            unsavedPerWindow: workspaces.map(\.unsavedDocumentCount), details: details
        ) else {
            return true
        }
        var alert = IDEAlert.confirm("Quit Umbra?", detail: text, confirm: "Quit")
        return alert.confirms()
    }

    /// What the quit prompt says, or nil when no window has unsaved editors. `unsavedPerWindow` holds
    /// each open window's count of editors with unsaved changes.
    static func quitPromptText(unsavedPerWindow: [Int], details: [String] = []) -> String? {
        let unsaved = unsavedPerWindow.filter { $0 > 0 }
        let total = unsaved.reduce(0, +)
        guard total > 0 else { return nil }
        let editors = "\(total) open editor\(total == 1 ? " has" : "s have")"
        let windows = unsaved.count > 1 ? " in \(unsaved.count) windows" : ""
        let base = "\(editors) unsaved changes\(windows) that will be lost."
        guard !details.isEmpty else { return base }
        return ([base] + details).joined(separator: "\n")
    }

    /// Quitting: stop what every window started (debug sessions, Gradle runs, watchers), so nothing
    /// outlives the app. Call after saving.
    func tearDownAll() {
        for workspace in workspaces {
            workspace.teardown()
        }
    }

    /// On quit: the shared lists. The windows themselves were stored by `noteTermination`, before
    /// they started to close.
    func saveSessionsForTermination() {
        IDEAppState.shared.save()
    }
}

/// A weak handle to a window's workspace. The menu bar is built from the focused window's handle,
/// never the workspace itself: SwiftUI keeps menu items and their action closures after a window
/// closes, and a strong capture in any of them kept the closed window's whole workspace (its
/// editors, index and watchers) alive until the menu next rebuilt.
final class IDEWorkspaceRef {
    weak var workspace: IDEWorkspace?

    init(_ workspace: IDEWorkspace? = nil) {
        self.workspace = workspace
    }
}

/// The focused window's workspace handle, for menu commands (`IDEAppCommands`).
private struct IDEWorkspaceFocusedKey: FocusedValueKey {
    typealias Value = IDEWorkspaceRef
}

extension FocusedValues {
    var ideWorkspace: IDEWorkspaceRef? {
        get { self[IDEWorkspaceFocusedKey.self] }
        set { self[IDEWorkspaceFocusedKey.self] = newValue }
    }
}

private struct IDESettingsWindowFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var ideSettingsWindow: Bool? {
        get { self[IDESettingsWindowFocusedKey.self] }
        set { self[IDESettingsWindowFocusedKey.self] = newValue }
    }
}
