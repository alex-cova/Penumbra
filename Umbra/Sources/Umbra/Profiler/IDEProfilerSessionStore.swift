import Foundation
import Observation

/// The profiler tabs' sessions, by their document's id, plus the run-scoped queries the run and
/// the tabs share: which live recording belongs to a run, and which tab a session id names. The
/// viewers, line hints and baseline UI stay on `IDEWorkspace` (F-11); this owns only the registry
/// both sides share.
@MainActor
@Observable
final class IDEProfilerSessionStore {
    private(set) var sessions: [UUID: IDEProfilerSession] = [:]

    var isEmpty: Bool { sessions.isEmpty }

    var allSessions: [IDEProfilerSession] { Array(sessions.values) }

    func session(for documentID: UUID) -> IDEProfilerSession? {
        sessions[documentID]
    }

    func register(_ session: IDEProfilerSession, for documentID: UUID) {
        sessions[documentID] = session
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> IDEProfilerSession? {
        sessions.removeValue(forKey: documentID)
    }

    /// Cancels every session and empties the registry, returning what was removed.
    @discardableResult
    func closeAll() -> [IDEProfilerSession] {
        let removed = Array(sessions.values)
        for session in removed { session.cancel() }
        sessions.removeAll()
        return removed
    }

    /// Whether the registry holds `session` itself, not an equal copy: a baseline read for a
    /// comparison is in no tab and must not drive the editor.
    func contains(_ session: IDEProfilerSession) -> Bool {
        sessions.values.contains(where: { $0 === session })
    }

    /// The tab showing `sessionID`, by document id. Nil when the session is in no tab.
    func documentID(forSessionID sessionID: UUID) -> UUID? {
        sessions.first(where: { $0.value.id == sessionID })?.key
    }

    /// A run that was watched live reads its recording in the tab it already has: the tab's
    /// document id and its session.
    func liveSession(runID: String) -> (documentID: UUID, session: IDEProfilerSession)? {
        sessions.first { $0.value.runID == runID && $0.value.phase == .live }
            .map { (documentID: $0.key, session: $0.value) }
    }

    func hasLiveProfile(runID: String) -> Bool {
        liveSession(runID: runID) != nil
    }

    func failLive(runID: String, failure: String) {
        for session in sessions.values where session.runID == runID { session.failLive(failure) }
    }
}
