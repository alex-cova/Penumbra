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
                gradleSidebarWidth: gradleSidebarWidth,
                isGradleSidebarVisible: isGradleSidebarVisible,
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

/// One window's state (`last-window.json`): its project, tabs and panel layout. Only the last
/// window is restored at launch, so there is one of these, not one per window.
struct IDEWindowSession: Codable {
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var sidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var isSidebarVisible = false
    /// The left sidebar's selected tab and the tabs closed with ×.
    var sidebarTab: IDESidebarTab?
    var closedSidebarTabs: [IDESidebarTab]?
    var gradleSidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var isGradleSidebarVisible = true
    var isTerminalVisible = false
    var terminalHeight = IDEAppearance.Spacing.terminalDefaultHeight
    var terminalTabs: [IDETerminalTab]?
    var selectedTerminalTabID: UUID?

    static let empty = IDEWindowSession()

    init(
        restoration: EditorRestorationState? = nil,
        projectRootBookmark: Data? = nil,
        sidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        isSidebarVisible: Bool = false,
        gradleSidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        isGradleSidebarVisible: Bool = true,
        isTerminalVisible: Bool = false,
        terminalHeight: Double = IDEAppearance.Spacing.terminalDefaultHeight,
        terminalTabs: [IDETerminalTab]? = nil,
        selectedTerminalTabID: UUID? = nil,
        sidebarTab: IDESidebarTab? = nil,
        closedSidebarTabs: [IDESidebarTab]? = nil
    ) {
        self.restoration = restoration
        self.projectRootBookmark = projectRootBookmark
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
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? IDEAppearance.Spacing.sidebarWidth
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? false
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

/// Where the session files live and how they are read and written. A directory is passed in so the
/// store can be pointed at a temporary folder; `standard` is Application Support.
///
/// - `app.json`: `IDEAppSessionRecord`, shared by all windows.
/// - `last-window.json`: `IDEWindowSession`, the most recently active window.
/// - `session.json`: the pre-split file, kept untouched so a downgrade still finds its session.
struct IDESessionFiles {
    let directory: URL

    /// Application Support, with the old `session.json` migrated on first use.
    static let standard: IDESessionFiles = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let files = IDESessionFiles(directory: base.appendingPathComponent("com.umbra.editor", isDirectory: true))
        files.migrateLegacySessionIfNeeded()
        return files
    }()

    var legacyURL: URL { directory.appendingPathComponent("session.json") }
    var appURL: URL { directory.appendingPathComponent("app.json") }
    var windowURL: URL { directory.appendingPathComponent("last-window.json") }

    /// Nil when the file is missing or unreadable, so callers fall back to defaults.
    func loadApp() -> IDEAppSessionRecord? { read(IDEAppSessionRecord.self, at: appURL) }
    func loadWindow() -> IDEWindowSession? { read(IDEWindowSession.self, at: windowURL) }

    func saveApp(_ record: IDEAppSessionRecord) { write(record, to: appURL) }
    func saveWindow(_ session: IDEWindowSession) { write(session, to: windowURL) }

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

/// The app's own `last-window.json`, for the workspace and root view.
enum IDEWindowSessionStore {
    static func load() -> IDEWindowSession {
        IDESessionFiles.standard.loadWindow() ?? .empty
    }

    static func save(_ session: IDEWindowSession) {
        IDESessionFiles.standard.saveWindow(session)
    }
}
