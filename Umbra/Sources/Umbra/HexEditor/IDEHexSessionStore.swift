import Foundation
import Observation

/// The hex tabs' sessions, by their document's id. The viewers, the documents and disk I/O stay
/// on `IDEWorkspace` (F-11); this owns only the registry both sides share.
@MainActor
@Observable
final class IDEHexSessionStore {
    private(set) var sessions: [UUID: IDEHexSession] = [:]

    var isEmpty: Bool { sessions.isEmpty }

    func session(for documentID: UUID) -> IDEHexSession? {
        sessions[documentID]
    }

    func register(_ session: IDEHexSession, for documentID: UUID) {
        sessions[documentID] = session
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> IDEHexSession? {
        sessions.removeValue(forKey: documentID)
    }

    /// Closes every session and empties the registry, returning what was removed.
    @discardableResult
    func closeAll() -> [IDEHexSession] {
        let removed = Array(sessions.values)
        for session in removed { session.close() }
        sessions.removeAll()
        return removed
    }
}
