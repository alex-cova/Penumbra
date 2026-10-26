import AgentKit
import Foundation

/// A chat as a Markdown file: who said what, the tools it ran, and what it changed.
/// A shell, Gradle or test command also includes the command and the output the model got.
/// Any call that failed says so with the model's error, and a file edit or `diagnostics` shows its
/// result, so a refused write cannot read as "Ran `write_file`".
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
                } else if let result = resultLine(name: name, output: entry.output) {
                    out += result
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

    private static let fileChangingTools: Set<String> = ["edit_file", "write_file", "apply_patch"]

    /// What a non-command call returned: the error when it failed, the result line of an edit, the
    /// first lines of `diagnostics`. Nothing for a successful read or search, whose content is the file's.
    private static func resultLine(name: String, output: ToolOutput?) -> String? {
        guard let output else { return nil }
        let lines = output.text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return output.isError ? "  - Failed: (no message)\n" : nil }
        func clipped(_ text: String, _ limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        if output.isError {
            return "  - Failed: \(clipped(lines.prefix(3).joined(separator: " "), 400))\n"
        }
        if fileChangingTools.contains(name) {
            return "  - Result: \(clipped(String(lines[0]), 300))\n"
        }
        if name == "diagnostics" {
            let shown = lines.prefix(6).map { "  - \(clipped(String($0), 200))" }.joined(separator: "\n")
            let more = lines.count > 6 ? "\n  - … \(lines.count - 6) more lines" : ""
            return shown + more + "\n"
        }
        return nil
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
