import Foundation
import Penumbra

/// The pre-split `session.json`: app-wide and window state in one file. Only read, to migrate it
/// once into `app.json` and `last-window.json` (`IDESessionFiles.migrateLegacySessionIfNeeded`).
struct IDELegacySession: Codable {
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var recentFiles: [URL]
    /// Files edited in the editor, most recent first (⌘E "Show edited only").
    var recentlyEditedFiles: [URL]
    var recentProjects: [URL]
    var preferences: IDEPreferencesSnapshot
    var sidebarWidth: Double
    var isSidebarVisible: Bool
    /// The left sidebar's selected tab and the tabs closed with ×. Optional so older sessions load.
    var sidebarTab: IDESidebarTab?
    var closedSidebarTabs: [IDESidebarTab]?
    var gradleSidebarWidth: Double
    var isGradleSidebarVisible: Bool
    var isTerminalVisible: Bool
    var terminalHeight: Double
    var terminalTabs: [IDETerminalTab]?
    var selectedTerminalTabID: UUID?

    static let empty = IDELegacySession(
        restoration: nil,
        projectRootBookmark: nil,
        recentFiles: [],
        recentlyEditedFiles: [],
        recentProjects: [],
        preferences: IDEPreferencesSnapshot(
            fontSize: 13,
            themeID: ThemeCatalog.defaultDarkID,
            tabWidth: 4,
            useSpacesForTab: true,
            wrapLines: false,
            showLineNumbers: true,
            isLineFoldingEnabled: true,
            showMinimap: true,
            isMetalRenderingEnabled: true,
            keymapPreset: .sublime
        ),
        sidebarWidth: IDEAppearance.Spacing.sidebarWidth,
        isSidebarVisible: false,
        gradleSidebarWidth: IDEAppearance.Spacing.sidebarWidth,
        isGradleSidebarVisible: true,
        isTerminalVisible: false,
        terminalHeight: IDEAppearance.Spacing.terminalDefaultHeight,
        terminalTabs: nil,
        selectedTerminalTabID: nil
    )

    init(
        restoration: EditorRestorationState?,
        projectRootBookmark: Data?,
        recentFiles: [URL],
        recentlyEditedFiles: [URL] = [],
        recentProjects: [URL] = [],
        preferences: IDEPreferencesSnapshot,
        sidebarWidth: Double,
        isSidebarVisible: Bool,
        gradleSidebarWidth: Double,
        isGradleSidebarVisible: Bool,
        isTerminalVisible: Bool,
        terminalHeight: Double,
        terminalTabs: [IDETerminalTab]? = nil,
        selectedTerminalTabID: UUID? = nil,
        sidebarTab: IDESidebarTab? = nil,
        closedSidebarTabs: [IDESidebarTab]? = nil
    ) {
        self.restoration = restoration
        self.projectRootBookmark = projectRootBookmark
        self.recentFiles = recentFiles
        self.recentlyEditedFiles = recentlyEditedFiles
        self.recentProjects = recentProjects
        self.preferences = preferences
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.sidebarTab = sidebarTab
        self.closedSidebarTabs = closedSidebarTabs
        self.gradleSidebarWidth = gradleSidebarWidth
        self.isGradleSidebarVisible = isGradleSidebarVisible
        self.isTerminalVisible = isTerminalVisible
        self.terminalHeight = terminalHeight
        self.terminalTabs = terminalTabs
        self.selectedTerminalTabID = selectedTerminalTabID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoration = try container.decodeIfPresent(EditorRestorationState.self, forKey: .restoration)
        projectRootBookmark = try container.decodeIfPresent(Data.self, forKey: .projectRootBookmark)
        recentFiles = try container.decode([URL].self, forKey: .recentFiles)
        recentlyEditedFiles = try container.decodeIfPresent([URL].self, forKey: .recentlyEditedFiles) ?? []
        recentProjects = try container.decodeIfPresent([URL].self, forKey: .recentProjects) ?? []
        preferences = try container.decode(IDEPreferencesSnapshot.self, forKey: .preferences)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
        isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
        sidebarTab = try? container.decodeIfPresent(IDESidebarTab.self, forKey: .sidebarTab)
        closedSidebarTabs = try? container.decodeIfPresent([IDESidebarTab].self, forKey: .closedSidebarTabs)
        gradleSidebarWidth = try container.decodeIfPresent(Double.self, forKey: .gradleSidebarWidth)
            ?? IDEAppearance.Spacing.sidebarWidth
        isGradleSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isGradleSidebarVisible) ?? true
        isTerminalVisible = try container.decodeIfPresent(Bool.self, forKey: .isTerminalVisible) ?? false
        terminalHeight = try container.decodeIfPresent(Double.self, forKey: .terminalHeight)
            ?? IDEAppearance.Spacing.terminalDefaultHeight
        terminalTabs = try container.decodeIfPresent([IDETerminalTab].self, forKey: .terminalTabs)
        selectedTerminalTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTerminalTabID)
    }
}

extension IDELegacySession {
    /// Splits the old single file into the app-wide and the window part.
    func split() -> (app: IDEAppSessionRecord, window: IDEWindowSession) {
        (
            IDEAppSessionRecord(
                recentFiles: recentFiles,
                recentlyEditedFiles: recentlyEditedFiles,
                recentProjects: recentProjects,
                preferences: preferences
            ),
            IDEWindowSession(
                restoration: restoration,
                projectRootBookmark: projectRootBookmark,
                sidebarWidth: sidebarWidth,
                isSidebarVisible: isSidebarVisible,
                projectSidebarWidth: gradleSidebarWidth,
                isProjectSidebarVisible: isGradleSidebarVisible,
                isTerminalVisible: isTerminalVisible,
                terminalHeight: terminalHeight,
                terminalTabs: terminalTabs,
                selectedTerminalTabID: selectedTerminalTabID,
                sidebarTab: sidebarTab,
                closedSidebarTabs: closedSidebarTabs
            )
        )
    }
}

/// What every window shares: the recent lists and the preferences snapshot (`app.json`). Owned by
/// `IDEAppState`, the single writer, so two windows never overwrite each other's recents.
struct IDEAppSessionRecord: Codable, Equatable {
    var recentFiles: [URL] = []
    /// Files edited in the editor, most recent first (⌘E "Show edited only").
    var recentlyEditedFiles: [URL] = []
    var recentProjects: [URL] = []
    /// Nil until the first save, so a fresh install keeps the preference defaults.
    var preferences: IDEPreferencesSnapshot?

    init(
        recentFiles: [URL] = [],
        recentlyEditedFiles: [URL] = [],
        recentProjects: [URL] = [],
        preferences: IDEPreferencesSnapshot? = nil
    ) {
        self.recentFiles = recentFiles
        self.recentlyEditedFiles = recentlyEditedFiles
        self.recentProjects = recentProjects
        self.preferences = preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentFiles = try container.decodeIfPresent([URL].self, forKey: .recentFiles) ?? []
        recentlyEditedFiles = try container.decodeIfPresent([URL].self, forKey: .recentlyEditedFiles) ?? []
        recentProjects = try container.decodeIfPresent([URL].self, forKey: .recentProjects) ?? []
        preferences = try? container.decodeIfPresent(IDEPreferencesSnapshot.self, forKey: .preferences)
    }
}

/// One window's state: its project, tabs and panel layout. `windows.json` holds one of these per
/// window that was open, most recently key first, and every one of them is restored at launch.
struct IDEWindowSession: Codable {
    /// Which window this is, so it updates its own entry and no other. Files written before windows
    /// were stored one by one have none; `IDESessionFiles.loadWindows` assigns one.
    var windowID: UUID?
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var sidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var isSidebarVisible = false
    /// The left sidebar's selected tab and the tabs closed with ×.
    var sidebarTab: IDESidebarTab?
    var closedSidebarTabs: [IDESidebarTab]?
    var projectSidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var isProjectSidebarVisible = true
    var isTerminalVisible = false
    var terminalHeight = IDEAppearance.Spacing.terminalDefaultHeight
    var terminalTabs: [IDETerminalTab]?
    var selectedTerminalTabID: UUID?
    /// The agent panel, when it is docked beside the editor. A panel that was a page over the editor is
    /// not reopened: it would hide the files being restored.
    var isAgentPanelVisible: Bool?
    var agentPanelWidth: Double?
    /// The saved conversations the agent's chat tabs showed, and which one was selected.
    var agentChats: [UUID]?
    var agentSelectedChat: UUID?
    /// Editor or AI mode, and which half of AI mode; older files have neither and open in the editor.
    var windowMode: IDEWindowMode?
    var aiTab: IDEAITab?
    /// AI mode's Changes / Plan / Browser panel: whether it shows, which tab, and how wide.
    var isAIInspectorVisible: Bool?
    var aiInspectorTab: IDEAIInspectorTab?
    var aiInspectorWidth: Double?

    static let empty = IDEWindowSession()

    init(
        windowID: UUID? = nil,
        restoration: EditorRestorationState? = nil,
        projectRootBookmark: Data? = nil,
        sidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        isSidebarVisible: Bool = false,
        projectSidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        isProjectSidebarVisible: Bool = true,
        isTerminalVisible: Bool = false,
        terminalHeight: Double = IDEAppearance.Spacing.terminalDefaultHeight,
        terminalTabs: [IDETerminalTab]? = nil,
        selectedTerminalTabID: UUID? = nil,
        sidebarTab: IDESidebarTab? = nil,
        closedSidebarTabs: [IDESidebarTab]? = nil,
        isAgentPanelVisible: Bool? = nil,
        agentPanelWidth: Double? = nil,
        agentChats: [UUID]? = nil,
        agentSelectedChat: UUID? = nil,
        windowMode: IDEWindowMode? = nil,
        aiTab: IDEAITab? = nil,
        isAIInspectorVisible: Bool? = nil,
        aiInspectorTab: IDEAIInspectorTab? = nil,
        aiInspectorWidth: Double? = nil
    ) {
        self.windowID = windowID
        self.restoration = restoration
        self.projectRootBookmark = projectRootBookmark
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.sidebarTab = sidebarTab
        self.closedSidebarTabs = closedSidebarTabs
        self.projectSidebarWidth = projectSidebarWidth
        self.isProjectSidebarVisible = isProjectSidebarVisible
        self.isTerminalVisible = isTerminalVisible
        self.terminalHeight = terminalHeight
        self.terminalTabs = terminalTabs
        self.selectedTerminalTabID = selectedTerminalTabID
        self.isAgentPanelVisible = isAgentPanelVisible
        self.agentPanelWidth = agentPanelWidth
        self.agentChats = agentChats
        self.agentSelectedChat = agentSelectedChat
        self.windowMode = windowMode
        self.aiTab = aiTab
        self.isAIInspectorVisible = isAIInspectorVisible
        self.aiInspectorTab = aiInspectorTab
        self.aiInspectorWidth = aiInspectorWidth
    }

    private enum LegacyKeys: String, CodingKey {
        case gradleSidebarWidth
        case isGradleSidebarVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try? container.decodeIfPresent(UUID.self, forKey: .windowID)
        restoration = try container.decodeIfPresent(EditorRestorationState.self, forKey: .restoration)
        projectRootBookmark = try container.decodeIfPresent(Data.self, forKey: .projectRootBookmark)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? IDEAppearance.Spacing.sidebarWidth
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? false
        sidebarTab = try? container.decodeIfPresent(IDESidebarTab.self, forKey: .sidebarTab)
        closedSidebarTabs = try? container.decodeIfPresent([IDESidebarTab].self, forKey: .closedSidebarTabs)
        // These two were saved as `gradleSidebarWidth` / `isGradleSidebarVisible` before the right-hand
        // tool window belonged to whichever project system recognized the folder. A file written by
        // an older Umbra still restores; the new name wins when both are there.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        projectSidebarWidth = try container.decodeIfPresent(Double.self, forKey: .projectSidebarWidth)
            ?? legacy.decodeIfPresent(Double.self, forKey: .gradleSidebarWidth)
            ?? IDEAppearance.Spacing.sidebarWidth
        isProjectSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isProjectSidebarVisible)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .isGradleSidebarVisible)
            ?? true
        isTerminalVisible = try container.decodeIfPresent(Bool.self, forKey: .isTerminalVisible) ?? false
        terminalHeight = try container.decodeIfPresent(Double.self, forKey: .terminalHeight)
            ?? IDEAppearance.Spacing.terminalDefaultHeight
        terminalTabs = try container.decodeIfPresent([IDETerminalTab].self, forKey: .terminalTabs)
        selectedTerminalTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTerminalTabID)
        isAgentPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .isAgentPanelVisible)
        agentPanelWidth = try container.decodeIfPresent(Double.self, forKey: .agentPanelWidth)
        agentChats = try? container.decodeIfPresent([UUID].self, forKey: .agentChats)
        agentSelectedChat = try? container.decodeIfPresent(UUID.self, forKey: .agentSelectedChat)
        windowMode = try? container.decodeIfPresent(IDEWindowMode.self, forKey: .windowMode)
        aiTab = try? container.decodeIfPresent(IDEAITab.self, forKey: .aiTab)
        isAIInspectorVisible = try? container.decodeIfPresent(Bool.self, forKey: .isAIInspectorVisible)
        aiInspectorTab = try? container.decodeIfPresent(IDEAIInspectorTab.self, forKey: .aiInspectorTab)
        aiInspectorWidth = try? container.decodeIfPresent(Double.self, forKey: .aiInspectorWidth)
    }

    /// The session written when this window's folder is going away: no project, no editor tabs, and
    /// every terminal in `homeDirectory`. Panel sizes stay. A Dock click then opens the Welcome screen
    /// instead of the folder that was open when the window closed.
    func closingFolder(homeDirectory: URL) -> IDEWindowSession {
        var session = self
        session.restoration = nil
        session.projectRootBookmark = nil
        session.isSidebarVisible = false
        session.isAgentPanelVisible = false
        session.agentChats = nil
        session.agentSelectedChat = nil
        let title = IDETerminalTab.defaultTitle(for: homeDirectory)
        session.terminalTabs = session.terminalTabs?.map { tab in
            var tab = tab
            tab.workingDirectory = homeDirectory
            tab.title = title
            return tab
        }
        return session
    }
}

/// Where the session files live and how they are read and written. A directory is passed in so the
/// store can be pointed at a temporary folder; `standard` is Application Support.
///
/// - `app.json`: `IDEAppSessionRecord`, shared by all windows.
/// - `windows.json`: `[IDEWindowSession]`, one per open window, most recently key first.
/// - `last-window.json`: the single window older versions kept; read once when `windows.json` does
///   not exist yet, and left untouched so a downgrade still finds its session.
/// - `session.json`: the pre-split file, likewise left untouched.
struct IDESessionFiles {
    let directory: URL

    /// Application Support, with the old `session.json` migrated on first use.
    static let standard: IDESessionFiles = {
        #if DEBUG
        if let directory = IDEACPUITestBootstrap.sessionDirectory {
            let files = IDESessionFiles(directory: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return files
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let files = IDESessionFiles(directory: base.appendingPathComponent("com.umbra.editor", isDirectory: true))
        files.migrateLegacySessionIfNeeded()
        return files
    }()

    var legacyURL: URL { directory.appendingPathComponent("session.json") }
    var appURL: URL { directory.appendingPathComponent("app.json") }
    var windowURL: URL { directory.appendingPathComponent("last-window.json") }
    var windowsURL: URL { directory.appendingPathComponent("windows.json") }

    /// Nil when the file is missing or unreadable, so callers fall back to defaults.
    func loadApp() -> IDEAppSessionRecord? { read(IDEAppSessionRecord.self, at: appURL) }
    func loadWindow() -> IDEWindowSession? { read(IDEWindowSession.self, at: windowURL) }

    func saveApp(_ record: IDEAppSessionRecord) { write(record, to: appURL) }
    func saveWindow(_ session: IDEWindowSession) { write(session, to: windowURL) }

    /// Every stored window, most recently key first. Without a `windows.json` the old single window
    /// is the only one. Entries that have no `windowID` get one, and the file is written then, so
    /// the id a window adopts is the id the file already holds.
    func loadWindows() -> [IDEWindowSession] {
        var windows: [IDEWindowSession]
        var needsWrite = false
        if let stored = read([IDEWindowSession].self, at: windowsURL) {
            windows = stored
        } else if let legacy = loadWindow() {
            windows = [legacy]
            needsWrite = true
        } else {
            return []
        }
        for index in windows.indices where windows[index].windowID == nil {
            windows[index].windowID = UUID()
            needsWrite = true
        }
        if needsWrite { saveWindows(windows) }
        return windows
    }

    func saveWindows(_ windows: [IDEWindowSession]) { write(windows, to: windowsURL) }

    /// Stores `session` as its window's entry: in place when the window is already listed, at the
    /// front when it is new. A session with no `windowID` cannot be matched and is ignored.
    func upsertWindow(_ session: IDEWindowSession) {
        guard let id = session.windowID else { return }
        var windows = loadWindows()
        if let index = windows.firstIndex(where: { $0.windowID == id }) {
            windows[index] = session
        } else {
            windows.insert(session, at: 0)
        }
        saveWindows(windows)
    }

    /// Drops a window's entry; writes nothing when it has none.
    func removeWindow(id: UUID) {
        let windows = loadWindows()
        guard windows.contains(where: { $0.windowID == id }) else { return }
        saveWindows(windows.filter { $0.windowID != id })
    }

    /// First launch after the split: turns `session.json` into `app.json` and `last-window.json`.
    /// Does nothing once `app.json` exists, or when there is no readable old session. The old file
    /// is left as it is.
    func migrateLegacySessionIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: appURL.path),
              let legacy = read(IDELegacySession.self, at: legacyURL) else { return }
        let (app, window) = legacy.split()
        saveApp(app)
        if !fileManager.fileExists(atPath: windowURL.path) {
            saveWindow(window)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The app's own `windows.json`, for the workspace and root view.
enum IDEWindowSessionStore {
    /// Every window to restore, most recently key first.
    static func loadAll() -> [IDEWindowSession] {
        IDESessionFiles.standard.loadWindows()
    }

    /// The window restored first: its layout is also what a new blank window opens at.
    static func load() -> IDEWindowSession {
        loadAll().first ?? .empty
    }

    /// Stores one window's session under its `windowID`.
    static func save(_ session: IDEWindowSession) {
        IDESessionFiles.standard.upsertWindow(session)
    }

    static func remove(windowID: UUID) {
        IDESessionFiles.standard.removeWindow(id: windowID)
    }

    /// Replaces the whole list: at quit (every open window) and when the last window closes (just that one).
    static func replaceAll(_ sessions: [IDEWindowSession]) {
        IDESessionFiles.standard.saveWindows(sessions)
    }
}
