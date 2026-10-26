import AgentKit
import Foundation
import Observation

/// One project's saved Code sessions, as the sidebar lists them.
struct IDEAISessionGroup: Identifiable, Equatable {
    var projectRoot: String
    var rows: [SessionSummary]

    var id: String { projectRoot }
    var name: String { URL(fileURLWithPath: projectRoot).lastPathComponent }
}

/// Saved Code sessions of every project, newest first, for AI mode's list. The current project's own
/// list is `IDEAgentController.history`, which is refreshed as chats are saved; this one adds the
/// others, read from the same store.
@MainActor
@Observable
final class IDEAISessions {
    private(set) var summaries: [SessionSummary] = []
    @ObservationIgnored private let store: SessionStore?

    init(store: SessionStore?) {
        self.store = store
    }

    /// Reads the newest sessions off the main actor (conversations can be large), decoding only the
    /// files written since the last read.
    func reload() async {
        guard let store else {
            summaries = []
            return
        }
        let previous = summaries
        summaries = await Task.detached(priority: .utility) { store.listAll(limit: 100, reusing: previous) }.value
    }

    /// The groups to list. The current project comes first and is built from `current` (what the
    /// window knows now); the others come from `others`, newest group first. A query keeps only the rows
    /// whose title it matches, and drops groups left empty, except the current project when there is
    /// no query, since it carries the New Session button.
    nonisolated static func groups(
        current: [SessionSummary], currentRoot: String?, others: [SessionSummary], query: String
    ) -> [IDEAISessionGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let currentKey = currentRoot.map(standardized)

        var groups: [IDEAISessionGroup] = []
        if let currentRoot {
            let rows = IDEAgentHistorySearch.rank(current, query: trimmed, requiresMatch: !trimmed.isEmpty)
            if !rows.isEmpty || trimmed.isEmpty { groups.append(IDEAISessionGroup(projectRoot: currentRoot, rows: rows)) }
        }

        var byProject: [String: [SessionSummary]] = [:]
        var order: [String] = []
        for summary in others {
            guard let root = summary.projectRoot, standardized(root) != currentKey else { continue }
            if byProject[root] == nil { order.append(root) }
            byProject[root, default: []].append(summary)
        }
        let rest: [IDEAISessionGroup] = order.compactMap { root in
            let rows = IDEAgentHistorySearch.rank(byProject[root] ?? [], query: trimmed, requiresMatch: !trimmed.isEmpty)
            return rows.isEmpty ? nil : IDEAISessionGroup(projectRoot: root, rows: rows)
        }
        // `others` arrives newest first, so each group's first row is its newest.
        return groups + rest.sorted { ($0.rows.first?.updatedAt ?? .distantPast) > ($1.rows.first?.updatedAt ?? .distantPast) }
    }
}
