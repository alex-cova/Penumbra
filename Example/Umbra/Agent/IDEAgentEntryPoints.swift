import AgentKit
import AppKit
import EditorIntelligence
import Foundation
import Penumbra

/// The messages the editor's "Ask Agent" and "Fix with Agent" entry points compose.
enum IDEAgentPrompts {
    /// Longer selections are cut; the agent can read the rest of the file itself.
    static let selectionLimit = 8_000

    static func aboutSelection(path: String, startLine: Int, endLine: Int, text: String) -> String {
        var code = text
        var note = ""
        if code.count > selectionLimit {
            code = String(code.prefix(selectionLimit))
            note = "\n(The selection was cut here; read the file for the rest.)"
        }
        // A fence the code can't close early.
        var fence = "```"
        while code.contains(fence) { fence += "`" }
        let range = startLine == endLine ? "line \(startLine)" : "lines \(startLine)–\(endLine)"
        let language = URL(fileURLWithPath: path).pathExtension.lowercased()
        let body = code.hasSuffix("\n") ? String(code.dropLast()) : code
        return "About `\(path)`, \(range):\n\n\(fence)\(language)\n\(body)\n\(fence)\(note)\n\n"
    }

    static func fixProblem(path: String, line: Int, column: Int, severity: String, source: String, message: String) -> String {
        let reporter = source.isEmpty ? "" : " (reported by \(source))"
        return """
        Fix this \(severity.lowercased()) in `\(path)` at line \(line), column \(column)\(reporter):

        \(message)

        Read the code around it, fix the cause rather than hiding the message, and check diagnostics for the file when you are done.
        """
    }
}

extension IDEAgentController {
    /// Puts `text` in the composer and shows the panel, or sends it at once when `send` is set and
    /// a message can be sent now. A draft the user was typing is kept either way: it is restored
    /// after a send and extended otherwise.
    func compose(_ text: String, send shouldSend: Bool) {
        showPanel()
        if shouldSend, !isRunning, settings.hasAcceptedDisclosure {
            let previous = draft
            draft = text
            send()
            // `send()` refuses without an open project; keep the text rather than lose it.
            if draft.isEmpty { draft = previous }
            return
        }
        draft = draft.isEmpty ? text : draft + "\n\n" + text
    }
}

extension IDEWorkspace {
    /// "Ask Agent About Selection": quotes the selected code in the composer for the user to add a question to.
    func askAgentAboutSelection(in textView: TextView, url: URL?, range: NSRange) {
        guard hasOpenProject, let url, range.length > 0, let selected = textView.text(in: range), !selected.isEmpty else { return }
        let start = (textView.textLocation(at: range.location)?.lineNumber ?? 0) + 1
        // A selection that ends right after a newline doesn't include the next line.
        let trimmed = selected.hasSuffix("\n") ? String(selected.dropLast()) : selected
        let end = start + trimmed.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        agent.compose(
            IDEAgentPrompts.aboutSelection(path: agentRelativePath(url), startLine: start, endLine: end, text: selected), send: false)
    }

    func askAgentAboutActiveSelection() {
        let textView = host(for: workbench.activePaneID).textView
        guard let url = workbench.activePane.selectedDocument?.url else { return }
        askAgentAboutSelection(in: textView, url: url, range: textView.selectedRange)
    }

    /// "Fix with Agent" on a Problems row: starts a run at once, because the user asked for exactly that.
    func fixProblemWithAgent(_ row: ProblemRow) {
        guard hasOpenProject else { return }
        let start = row.diagnostic.range.start
        agent.compose(
            IDEAgentPrompts.fixProblem(
                path: agentRelativePath(row.url), line: start.line + 1, column: start.column + 1,
                severity: IDEProblemStyle.label(for: row.diagnostic.severity), source: row.diagnostic.source,
                message: row.diagnostic.message),
            send: true)
    }

    func agentContextMenuItems(context: EditorContextMenuContext, textView: TextView, url: URL?) -> [NSMenuItem] {
        guard hasOpenProject, let url, let range = context.selectedRange, range.length > 0 else { return [] }
        return [
            .separator(),
            IDEClosureMenuItem(title: "Ask Agent About Selection") { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.askAgentAboutSelection(in: textView, url: url, range: range)
            },
        ]
    }
}
