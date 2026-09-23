import Foundation
import Penumbra

struct AppSession: Codable {
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var recentFiles: [URL]
    var recentProjects: [URL]
    var preferences: IDEPreferencesSnapshot
    var sidebarWidth: Double
    var isSidebarVisible: Bool
    var gradleSidebarWidth: Double
    var isGradleSidebarVisible: Bool
    var isTerminalVisible: Bool
    var terminalHeight: Double
    var terminalTabs: [IDETerminalTab]?
    var selectedTerminalTabID: UUID?

    static let empty = AppSession(
        restoration: nil,
        projectRootBookmark: nil,
        recentFiles: [],
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
        isSidebarVisible: true,
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
        recentProjects: [URL] = [],
        preferences: IDEPreferencesSnapshot,
        sidebarWidth: Double,
        isSidebarVisible: Bool,
        gradleSidebarWidth: Double,
        isGradleSidebarVisible: Bool,
        isTerminalVisible: Bool,
        terminalHeight: Double,
        terminalTabs: [IDETerminalTab]? = nil,
        selectedTerminalTabID: UUID? = nil
    ) {
        self.restoration = restoration
        self.projectRootBookmark = projectRootBookmark
        self.recentFiles = recentFiles
        self.recentProjects = recentProjects
        self.preferences = preferences
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
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
        recentProjects = try container.decodeIfPresent([URL].self, forKey: .recentProjects) ?? []
        preferences = try container.decode(IDEPreferencesSnapshot.self, forKey: .preferences)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
        isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
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

enum IDESessionStore {
    private static let appSupportSubpath = "com.umbra.editor"
    private static let sessionFileName = "session.json"

    static var sessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportSubpath, isDirectory: true)
            .appendingPathComponent(sessionFileName)
    }

    static func load() -> AppSession {
        let url = sessionURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(AppSession.self, from: data) else {
            return .empty
        }
        return session
    }

    static func save(_ session: AppSession) {
        let url = sessionURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
