import Foundation
import Penumbra

struct AppSession: Codable {
    var restoration: EditorRestorationState?
    var projectRootBookmark: Data?
    var recentFiles: [URL]
    var preferences: IDEPreferencesSnapshot
    var sidebarWidth: Double
    var isSidebarVisible: Bool

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
        isSidebarVisible: true
    )
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
