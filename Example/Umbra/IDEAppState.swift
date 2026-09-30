import Foundation
import Observation

/// App-wide state that every window shares: the recent files and projects, and the preferences
/// snapshot saved next to them (`app.json`). One instance owns it, so a recent recorded in one
/// window shows in every window's Open Recent menu and a save from any window writes the same
/// lists instead of overwriting another window's.
@MainActor
@Observable
final class IDEAppState {
    static let shared = IDEAppState(files: .standard, preferences: .shared)

    var recentFiles: [URL] = []
    var recentProjects: [URL] = []
    /// Files edited in the editor, most recent first: the ⌘E "Show edited only" list. Ignored by
    /// observation: it changes while typing.
    @ObservationIgnored var recentlyEditedFiles: [URL] = []

    @ObservationIgnored private let files: IDESessionFiles
    @ObservationIgnored private let preferences: IDEPreferences?
    @ObservationIgnored private var lastSaved: IDEAppSessionRecord?

    /// Loads `app.json` and, when `preferences` is given, applies the saved snapshot to it.
    init(files: IDESessionFiles, preferences: IDEPreferences?) {
        self.files = files
        self.preferences = preferences
        if let record = files.loadApp() {
            recentFiles = record.recentFiles
            recentlyEditedFiles = record.recentlyEditedFiles
            recentProjects = record.recentProjects
            if let snapshot = record.preferences {
                preferences?.restore(from: snapshot)
            }
            lastSaved = record
        }
    }

    /// Writes `app.json` when something changed since the last write. Cheap to call often.
    func save() {
        let record = IDEAppSessionRecord(
            recentFiles: recentFiles,
            recentlyEditedFiles: recentlyEditedFiles,
            recentProjects: recentProjects,
            preferences: preferences?.snapshot() ?? lastSaved?.preferences
        )
        guard record != lastSaved else { return }
        files.saveApp(record)
        lastSaved = record
    }
}
