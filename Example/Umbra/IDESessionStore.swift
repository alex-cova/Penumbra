import Foundation
import Penumbra

struct AppSession: Codable {
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var recentFiles: [URL]
    var preferences: IDEPreferencesSnapshot
    var sidebarWidth: Double
    var isSidebarVisible: Bool
    var isTerminalVisible: Bool
    var terminalHeight: Double

    static let empty = AppSession(
        restoration: nil,
        projectRootBookmark: nil,
        recentFiles: [],
        preferences: IDEPreferencesSnapshot(
            fontSize: 13,
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
        isTerminalVisible: false,
        terminalHeight: IDEAppearance.Spacing.terminalDefaultHeight
    )

    init(
        restoration: EditorRestorationState?,
        projectRootBookmark: Data?,
        recentFiles: [URL],
        preferences: IDEPreferencesSnapshot,
        sidebarWidth: Double,
        isSidebarVisible: Bool,
        isTerminalVisible: Bool,
        terminalHeight: Double
    ) {
        self.restoration = restoration
        self.projectRootBookmark = projectRootBookmark
        self.recentFiles = recentFiles
        self.preferences = preferences
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.isTerminalVisible = isTerminalVisible
        self.terminalHeight = terminalHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoration = try container.decodeIfPresent(EditorRestorationState.self, forKey: .restoration)
        projectRootBookmark = try container.decodeIfPresent(Data.self, forKey: .projectRootBookmark)
        recentFiles = try container.decode([URL].self, forKey: .recentFiles)
        preferences = try container.decode(IDEPreferencesSnapshot.self, forKey: .preferences)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
        isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
        isTerminalVisible = try container.decodeIfPresent(Bool.self, forKey: .isTerminalVisible) ?? false
        terminalHeight = try container.decodeIfPresent(Double.self, forKey: .terminalHeight)
            ?? IDEAppearance.Spacing.terminalDefaultHeight
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
