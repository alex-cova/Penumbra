import Foundation

/// A chat as a Markdown file: who said what, the tools it ran, and what it changed.
/// A shell, Gradle or test command also includes the command and the output the model got.
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
                if let command = IDEAgentToolSummary.commandLine(name: name, arguments: entry.text) {
                    out += "\n" + fenced(command, language: "sh")
                    let output = entry.output?.text ?? entry.liveOutput
                    if !output.isEmpty {
                        let heading = entry.output?.isError == true ? "Output (failed)" : "Output"
                        out += "\n\(heading):\n\n" + fenced(output)
                    }
                }
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

    /// A fenced block. The fence grows past any backtick run inside the text.
    private static func fenced(_ text: String, language: String = "") -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? text : text + "\n"
        return "\(fence)\(language)\n\(body)\(fence)\n"
    }

    /// A file name for the chat: letters, digits and dashes.
    static func fileName(for title: String) -> String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (collapsed.isEmpty ? "chat" : String(collapsed.prefix(60))) + ".md"
    }
}
