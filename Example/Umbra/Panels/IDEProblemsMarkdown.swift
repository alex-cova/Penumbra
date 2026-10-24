import AppKit
import EditorIntelligence
import JavaIntelligence

/// The Problems list as Markdown, for the header's copy button. Pure, so it is tested without a window.
enum IDEProblemsMarkdown {
    /// An inspection's readable name; the tool's id for everything else.
    static func origin(of diagnostic: Diagnostic) -> String {
        diagnostic.code.flatMap { IDEWorkspace.diagnosticTitle(source: diagnostic.source, code: $0) } ?? diagnostic.source
    }

    /// Build messages first, then one section per file. `relativePath` names a file in a heading.
    static func render(
        files: [ProblemFile],
        messages: [GradleProblem],
        relativePath: (URL) -> String
    ) -> String {
        guard !files.isEmpty || !messages.isEmpty else { return "# Problems\n\nNo problems\n" }

        var errors = messages.filter { $0.severity == .error }.count
        var warnings = messages.filter { $0.severity == .warning }.count
        for file in files {
            errors += file.errorCount
            warnings += file.warningCount
        }

        var lines = ["# Problems", "", "\(count(errors, "error")), \(count(warnings, "warning"))"]

        if !messages.isEmpty {
            lines += ["", "## Build"]
            for message in messages {
                var line = "- **\(label(of: message.severity))**"
                if let task = message.task { line += " `\(task)`:" }
                line += " \(singleLine(message.message))"
                if let file = message.file {
                    line += " (\(relativePath(file))\(message.line.map { ":\($0)" } ?? ""))"
                }
                lines.append(line)
            }
        }

        for file in files {
            lines += ["", "## \(relativePath(file.url))"]
            for row in file.rows {
                let diagnostic = row.diagnostic
                let start = diagnostic.range.start
                lines.append(
                    "- **\(IDEProblemStyle.label(for: diagnostic.severity))** \(start.line + 1):\(start.column + 1): "
                        + "\(singleLine(diagnostic.message)) (\(origin(of: diagnostic)))"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func label(of severity: GradleProblem.Severity) -> String {
        switch severity {
        case .error: IDEProblemStyle.label(for: .error)
        case .warning: IDEProblemStyle.label(for: .warning)
        case .info: IDEProblemStyle.label(for: .information)
        }
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// Keeps a multi-line message inside its list item.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension IDEWorkspace {
    /// What the Problems list shows for the selected scope and severity filter.
    func visibleProblems() -> (files: [ProblemFile], messages: [GradleProblem]) {
        let isFileScope = inspectionRuns.selection == .file
        let all = problems.files
        guard isFileScope else { return (all, problems.visibleBuildMessages) }
        let activeURL = workbench.activePane.selectedDocument?.url?.standardizedFileURL
        return (all.filter { $0.url.standardizedFileURL == activeURL }, [])
    }

    /// Puts the visible Problems list on the pasteboard as Markdown.
    func copyProblemsAsMarkdown() {
        let visible = visibleProblems()
        let markdown = IDEProblemsMarkdown.render(files: visible.files, messages: visible.messages) {
            agentRelativePath($0)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}
