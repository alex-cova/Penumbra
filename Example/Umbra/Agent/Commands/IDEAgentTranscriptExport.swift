import Foundation

/// A chat as a Markdown file: who said what, the tools it ran, and what it changed.
enum IDEAgentTranscriptExport {
    static func markdown(title: String, entries: [IDEAgentEntry], exportedAt: Date = Date()) -> String {
        var out = "# \(title)\n\n_Exported \(exportedAt.formatted(date: .abbreviated, time: .shortened)) from Umbra._\n"
        for entry in entries {
            switch entry.kind {
            case .user:
                out += "\n## You\n\n\(entry.text)\n"
            case .assistant:
                out += "\n## Agent\n\n\(entry.text)\n"
            case .toolCall(let name):
                out += "\n- Ran `\(name)`: \(IDEAgentToolSummary.title(name: name, arguments: entry.text))"
                if let outcome = entry.approvalOutcome { out += " (\(outcome.lowercased()))" }
                out += "\n"
            case .changes:
                let files = entry.fileChanges.map { "`\($0.path)`" }.joined(separator: ", ")
                out += "\n> Changed \(entry.fileChanges.count) \(entry.fileChanges.count == 1 ? "file" : "files"): \(files)\n"
            case .notice:
                out += "\n_\(entry.text)_\n"
            case .error:
                out += "\n> **Error:** \(entry.text)\n"
            }
        }
        return out
    }

    /// A file name for the chat: letters, digits and dashes.
    static func fileName(for title: String) -> String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (collapsed.isEmpty ? "chat" : String(collapsed.prefix(60))) + ".md"
    }
}
