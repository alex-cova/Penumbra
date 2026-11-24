import AgentKit
import Foundation

/// One row of the agent transcript as drawn: a single entry, or a run of tool calls folded into one
/// "Worked · 14 steps" row.
enum IDEAgentTranscriptRow: Identifiable, Equatable {
    case entry(IDEAgentEntry)
    case work(IDEAgentWorkGroup)

    /// A group takes its first entry's id, so the row keeps its identity while the group grows.
    var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .work(let group): group.id
        }
    }
}

/// Consecutive tool calls between two things worth reading on their own (a reply, an approval, an error).
struct IDEAgentWorkGroup: Identifiable, Equatable {
    var entries: [IDEAgentEntry]
    /// The group the running turn is adding to: it is shown open until the run moves past it.
    var isLive: Bool
    var summary: IDEAgentWorkSummary

    var id: UUID { entries[0].id }
}

/// What a work group did, counted from its calls.
struct IDEAgentWorkSummary: Equatable {
    var steps = 0
    var filesEdited = 0
    var commands = 0

    func text(isLive: Bool) -> String {
        var parts = [isLive ? "Working" : "Worked", Self.count(steps, "step", "steps")]
        if filesEdited > 0 { parts.append(Self.count(filesEdited, "file edited", "files edited")) }
        if commands > 0 { parts.append(Self.count(commands, "command", "commands")) }
        return parts.joined(separator: " · ")
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}

enum IDEAgentTranscriptRows {
    /// Tools whose call runs a command line.
    static let commandTools: Set<String> = ["run_command", "gradle", "run_tests", "maven"]

    /// Folds runs of two or more tool calls into work groups. Calls the user has to see stay on their own:
    /// one waiting for an approval, a question, a plan, and a call that failed. Notices between two calls
    /// (a retry, a continuation) go inside the group; one after the last call stays outside.
    static func make(_ entries: [IDEAgentEntry], isRunning: Bool) -> [IDEAgentTranscriptRow] {
        var rows: [IDEAgentTranscriptRow] = []
        rows.reserveCapacity(entries.count)
        var group: [IDEAgentEntry] = []
        var notices: [IDEAgentEntry] = []

        func flush(isLive: Bool) {
            if group.count > 1 {
                rows.append(.work(IDEAgentWorkGroup(entries: group, isLive: isLive, summary: summarize(group))))
            } else {
                rows += group.map(IDEAgentTranscriptRow.entry)
            }
            rows += notices.map(IDEAgentTranscriptRow.entry)
            group = []
            notices = []
        }

        for entry in entries {
            if isGroupable(entry) {
                group += notices
                notices = []
                group.append(entry)
            } else if entry.kind == .notice, !group.isEmpty {
                notices.append(entry)
            } else {
                flush(isLive: false)
                rows.append(.entry(entry))
            }
        }
        // Only notices came after the last group: the running turn is still in it.
        flush(isLive: isRunning)
        return rows
    }

    /// A tool call that can be folded away. Anything that asks the user something, or failed, cannot.
    static func isGroupable(_ entry: IDEAgentEntry) -> Bool {
        guard case .toolCall(let name) = entry.kind else { return false }
        if name == "exit_plan_mode" || entry.plan != nil { return false }
        if entry.question != nil || entry.elicitation != nil { return false }
        if entry.approval != nil, entry.output == nil { return false }
        if entry.output?.isError == true { return false }
        return true
    }

    static func summarize(_ entries: [IDEAgentEntry]) -> IDEAgentWorkSummary {
        var summary = IDEAgentWorkSummary()
        var paths = Set<String>()
        for entry in entries {
            guard case .toolCall(let name) = entry.kind else { continue }
            summary.steps += 1
            if commandTools.contains(name) { summary.commands += 1 }
            // Arguments are parsed only for the editing tools, so a long transcript stays cheap to group.
            switch name {
            case "edit_file", "write_file":
                if let path = (try? JSONValue(parsing: entry.text))?.objectValue?["path"]?.stringValue {
                    paths.insert(path)
                }
            case "apply_patch":
                if let patch = (try? JSONValue(parsing: entry.text))?.objectValue?["patch"]?.stringValue {
                    paths.formUnion(patchedPaths(patch))
                }
            default:
                break
            }
        }
        summary.filesEdited = paths.count
        return summary
    }

    /// The files a unified diff writes: its `+++ b/path` lines.
    static func patchedPaths(_ patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("+++ ") else { return nil }
            var path = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if path == "/dev/null" { return nil }
            if path.hasPrefix("b/") { path.removeFirst(2) }
            return path.isEmpty ? nil : path
        }
    }

    /// The row that shows an entry: the entry's own, or the group it is folded into.
    static func rowID(containing entryID: UUID, in rows: [IDEAgentTranscriptRow]) -> UUID? {
        for row in rows {
            switch row {
            case .entry(let entry) where entry.id == entryID: return entry.id
            case .work(let group) where group.entries.contains(where: { $0.id == entryID }): return group.id
            default: continue
            }
        }
        return nil
    }
}
