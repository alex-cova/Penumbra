import Foundation
import Observation

/// The diagram tabs' sessions, by their document's id. Viewers, requests and project systems stay
/// on `IDEWorkspace` (F-11); this owns only the registry both sides share.
@MainActor
@Observable
final class IDEDiagramSessionStore {
    private(set) var sessions: [UUID: IDEDiagramSession] = [:]

    var isEmpty: Bool { sessions.isEmpty }

    func session(for documentID: UUID) -> IDEDiagramSession? {
        sessions[documentID]
    }

    func register(_ session: IDEDiagramSession, for documentID: UUID) {
        sessions[documentID] = session
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> IDEDiagramSession? {
        sessions.removeValue(forKey: documentID)
    }

    /// Cancels every session and empties the registry, returning what was removed.
    @discardableResult
    func closeAll() -> [IDEDiagramSession] {
        let removed = Array(sessions.values)
        for session in removed { session.cancel() }
        sessions.removeAll()
        return removed
    }

    /// After the project's sources were re-indexed or Gradle re-synced, open diagrams of that
    /// kind redraw.
    func reload(classes: Bool) {
        for session in sessions.values where classes
            ? session.request.isClassDiagram
            : (session.request.id == IDEDiagramRequest.gradleModules.id || session.request.id == IDEDiagramRequest.mavenModules.id) {
            session.reload()
        }
    }
}
