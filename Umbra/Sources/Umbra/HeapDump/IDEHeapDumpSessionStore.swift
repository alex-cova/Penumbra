import Foundation
import Observation

/// The heap dump tabs' sessions, by their document's id.
@MainActor
@Observable
final class IDEHeapDumpSessionStore {
    private(set) var sessions: [UUID: IDEHeapDumpSession] = [:]

    func session(for documentID: UUID) -> IDEHeapDumpSession? {
        sessions[documentID]
    }

    func register(_ session: IDEHeapDumpSession, for documentID: UUID) {
        sessions[documentID] = session
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> IDEHeapDumpSession? {
        sessions.removeValue(forKey: documentID)
    }

    /// The tab showing `sessionID`, by document id.
    func documentID(forSessionID sessionID: UUID) -> UUID? {
        sessions.first { $0.value.id == sessionID }?.key
    }

    func closeAll() {
        for session in sessions.values { session.cancel() }
        sessions.removeAll()
    }
}
