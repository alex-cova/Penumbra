import Foundation

/// Find in the agent transcript: which entries hold the text, in transcript order.
enum IDEAgentTranscriptFind {
    /// The entries whose text, tool title, output, live command output or file names contain `query`,
    /// ignoring case and diacritics. An empty or blank query finds nothing.
    static func matches(_ query: String, in entries: [IDEAgentEntry]) -> [UUID] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return entries.compactMap { entry in
            searchableTexts(of: entry).contains { contains($0, needle) } ? entry.id : nil
        }
    }

    /// What a row shows, or shows when opened. For a tool call that is its title (not the raw JSON
    /// arguments, which would match `"path"` everywhere) and its output.
    static func searchableTexts(of entry: IDEAgentEntry) -> [String] {
        switch entry.kind {
        case .user, .assistant, .notice, .error:
            return [entry.text]
        case .toolCall(let name):
            var texts = [IDEAgentToolSummary.title(name: name, arguments: entry.text)]
            if let output = entry.output?.text { texts.append(output) }
            if !entry.liveOutput.isEmpty { texts.append(entry.liveOutput) }
            if let plan = entry.plan { texts.append(plan) }
            if let question = entry.question?.question { texts.append(question) }
            return texts
        case .changes:
            return entry.fileChanges.map(\.path)
        }
    }

    /// The match to show after `current` when moving by `step` (1 or -1), wrapping around. With no current
    /// match (a new query), the first one, or the last when going back.
    static func next(after current: UUID?, by step: Int, in matches: [UUID]) -> UUID? {
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(of: current) else {
            return step >= 0 ? matches.first : matches.last
        }
        return matches[(index + step + matches.count) % matches.count]
    }

    /// "3 of 12", or "No results" for a query that found nothing.
    static func position(of current: UUID?, in matches: [UUID]) -> String {
        guard !matches.isEmpty else { return "No results" }
        guard let current, let index = matches.firstIndex(of: current) else { return "\(matches.count) found" }
        return "\(index + 1) of \(matches.count)"
    }

    private static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The ticks on the transcript's minimap rail: one per user message.
struct IDEAgentMinimapItem: Identifiable, Equatable {
    /// The user entry; clicking the tick scrolls to it.
    var id: UUID
    var prompt: String
    /// The last assistant reply of that turn, if one came.
    var reply: String?
    /// Where the turn starts, as a share of the transcript's entries (0 at the top).
    var position: Double
    /// The turn's runs changed files.
    var changedFiles: Bool
    /// Something in the turn still waits for the user.
    var isWaiting: Bool
}

enum IDEAgentMinimapItems {
    /// The rail appears from this many user messages on; below it the transcript is short enough to scroll.
    static let minimumTurns = 4

    static func make(_ entries: [IDEAgentEntry]) -> [IDEAgentMinimapItem] {
        var items: [IDEAgentMinimapItem] = []
        let count = max(entries.count, 1)
        for (index, entry) in entries.enumerated() {
            if entry.kind == .user {
                items.append(IDEAgentMinimapItem(
                    id: entry.id, prompt: firstLine(entry.text), reply: nil,
                    position: Double(index) / Double(count), changedFiles: false, isWaiting: false))
                continue
            }
            guard !items.isEmpty else { continue }
            if entry.kind == .assistant, !entry.text.isEmpty { items[items.count - 1].reply = firstLine(entry.text) }
            if entry.kind == .changes, !entry.isReverted { items[items.count - 1].changedFiles = true }
            if entry.isWaitingForUser { items[items.count - 1].isWaiting = true }
        }
        return items
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count <= 120 ? line : String(line.prefix(119)) + "…"
    }
}
