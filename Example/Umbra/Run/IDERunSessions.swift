import Foundation

/// The sessions shown in the Run tool window, newest last. Owned by `IDEWorkspace`.
@MainActor
@Observable
final class IDERunSessions {
    /// Finished sessions kept for reading; the oldest go first. Running ones are never dropped.
    static let maxFinished = 10

    private(set) var sessions: [IDERunSession] = []
    var selectedID: UUID?

    var hasContent: Bool { !sessions.isEmpty }
    var selected: IDERunSession? { sessions.first { $0.id == selectedID } ?? sessions.last }
    var activeSessions: [IDERunSession] { sessions.filter(\.isActive) }
    var isAnyActive: Bool { sessions.contains(where: \.isActive) }
    /// Running programs only: the ones a user could be waiting on or want to stop.
    var isAnyRunning: Bool { sessions.contains(where: \.isRunning) }

    /// The newest session of a configuration, running or not.
    func latest(forConfiguration id: UUID) -> IDERunSession? {
        sessions.last { $0.configurationID == id }
    }

    /// Adds `session` in the place of `replacing` (a rerun keeps its tab), else at the end, and selects it.
    func add(_ session: IDERunSession, replacing old: IDERunSession? = nil) {
        if let old, let index = sessions.firstIndex(where: { $0.id == old.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        selectedID = session.id
        trimFinished()
    }

    /// Starts `request` in a new session: in the place of the session it replaces (a rerun keeps its
    /// tab), else at the end, and selected. A rerun of a run that is still going stops it first,
    /// unless the request allows several instances, and waits for it to end before the request's
    /// `prepare` begins (a server that is going down still holds its port).
    @discardableResult
    func start(_ request: IDERunRequest, replacing explicit: IDERunSession? = nil) -> IDERunSession {
        let previous = explicit ?? latest(forConfiguration: request.id)
        let replaced: IDERunSession?
        if explicit != nil {
            replaced = explicit
        } else if let previous, !request.allowsMultipleInstances || !previous.isActive {
            replaced = previous
        } else {
            replaced = nil
        }
        let session = IDERunSession(
            configurationID: request.id, title: request.title, providerID: request.providerID, payload: request.payload
        )
        add(session, replacing: replaced)

        let toStop = replaced?.isActive == true ? replaced : nil
        toStop?.stop()
        let prepare = request.prepare
        Task { @MainActor [weak session] in
            if let toStop { await toStop.waitUntilFinished() }
            guard let session, session.isActive else { return }
            await prepare(session)
        }
        return session
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Closes a session; a running one is stopped first.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].stop()
        sessions.remove(at: index)
        if selectedID == id { selectedID = sessions.last?.id }
    }

    func closeFinished() {
        sessions.removeAll { !$0.isActive }
        if !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.last?.id }
    }

    func stopAll() {
        for session in sessions where session.isActive { session.stop() }
    }

    /// A chip title that tells two runs of one configuration apart: `Main`, `Main (2)`.
    func title(for session: IDERunSession) -> String {
        let same = sessions.filter { $0.title == session.title }
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == session.id }), index > 0 else {
            return session.title
        }
        return "\(session.title) (\(index + 1))"
    }

    private func trimFinished() {
        var finished = sessions.filter { !$0.isActive }.count
        guard finished > Self.maxFinished else { return }
        sessions.removeAll { session in
            guard finished > Self.maxFinished, !session.isActive, session.id != selectedID else { return false }
            finished -= 1
            return true
        }
    }
}
