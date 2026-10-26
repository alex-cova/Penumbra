import AppKit
import JavaIntelligence
import Penumbra
import SubprocessKit

/// Coverage as the window shows it: the tab, the editor bands (applied with the execution line,
/// which shares `lineBackgrounds`), navigation between uncovered lines and the exports.
extension IDEWorkspace {
    var showsCoverageTab: Bool { coverage.hasContent }

    func showCoverageTab() {
        showBottomTab(.coverage)
        isTerminalVisible = true
    }

    /// Whether the editor's theme is a dark one, for the band colours.
    var isDarkEditorTheme: Bool {
        let color = IDEEditorTheme.shared.current.textColor.usingColorSpace(.deviceRGB) ?? .white
        return (0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent) > 0.5
    }

    /// The coverage bands for the file `url` shows, honouring the Settings switch.
    func coverageLineBackgrounds(forFile url: URL?) -> [LineBackground] {
        guard IDEPreferences.shared.javaCoverageShowsInEditor else { return [] }
        return IDECoverageController.lineBackgrounds(for: coverage.bands(forFile: url), darkTheme: isDarkEditorTheme)
    }

    /// Repaints every open editor's bands after the snapshot or the setting changed.
    func refreshCoverageBands() {
        refreshExecutionLineBackgrounds()
    }

    /// The caret moved into an edit of a file that has coverage: its bands are no longer true.
    func noteCoverageEdit(in textView: TextView) {
        guard coverage.snapshot != nil, coverage.noteEdit(file: textView.documentURL) else { return }
        refreshCoverageBands()
    }

    // MARK: - Opening and moving

    func openCoverageSource(_ url: URL, line: Int) {
        Task {
            await openDocument(from: url)
            _ = host(for: workbench.activePaneID).textView.goToLine(max(0, line - 1), select: .beginning)
        }
    }

    /// Moves the caret to the next (or previous) line the run did not fully execute in the active file.
    func goToUncoveredLine(forward: Bool) {
        guard let url = runFileURL, coverage.hasLiveCoverage(forFile: url),
              let file = coverage.snapshot?.report.sourceFile(at: url) else {
            NSSound.beep()
            return
        }
        let textView = host(for: workbench.activePaneID).textView
        let location = textView.selectedRange.location
        let text = textView.text as NSString
        let caretLine = 1 + text.substring(to: min(location, text.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let target = forward ? file.nextUncovered(after: caretLine) : file.previousUncovered(before: caretLine)
        guard let target else {
            NSSound.beep()
            return
        }
        _ = textView.goToLine(target - 1, select: .beginning)
    }

    // MARK: - Run with Coverage / Profile

    /// Run ▸ Run with Coverage and Profile: what the caret is in, else the active file's launch.
    func runInstrumented(_ instrumentation: JavaRunInstrumentation) {
        Task { @MainActor [self] in
            let started = await javaRun.runInstrumented(activeRunDocument(), instrumentation: instrumentation)
            if !started { reportRunProblem("There is nothing to run. Open a Java file with a main method or a test.") }
        }
    }

    /// Run ▸ Run All Tests with Coverage / Profile All Tests: the active test class, else every test.
    func runTestsInstrumented(_ instrumentation: JavaRunInstrumentation) {
        javaRun.runActiveTests(instrumentation: instrumentation)
    }

    func clearCoverage() {
        coverage.clear()
        refreshCoverageBands()
    }

    // MARK: - Exports

    /// Saves the run's report as the JaCoCo XML it was read from.
    func exportCoverageXML() {
        guard let snapshot = coverage.snapshot else { return }
        let source = snapshot.runDirectory.appendingPathComponent("report.xml")
        guard FileManager.default.fileExists(atPath: source.path) else {
            reportRunProblem("The report file is gone. Run with coverage again.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jacoco-report.xml"
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            reportRunProblem("Could not save the report: \(error.localizedDescription)")
        }
    }

    /// Writes the HTML report (`jacococli --html`, with the sources) into a folder the user picks.
    func exportCoverageHTML() {
        guard let snapshot = coverage.snapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to write the HTML coverage report."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("coverage-\(snapshot.runID)", isDirectory: true)
        let call = JavaCoverageCommand.htmlInvocation(
            java: snapshot.java, cliJar: snapshot.cliJar,
            executionFiles: snapshot.executionFiles.filter { FileManager.default.fileExists(atPath: $0.path) },
            classDirectories: snapshot.classDirectories,
            sourceDirectories: snapshot.sourceDirectories,
            htmlOutput: destination,
            name: snapshot.label
        )
        Task { [weak self] in
            var request = SubprocessRequest(executable: call.executable.path, arguments: call.arguments)
            request.timeout = .seconds(180)
            request.stderrCapture = .bounded(head: 2_000, tail: 4_000)
            let result = try? await SubprocessRunner.run(request)
            guard let self else { return }
            if result?.exit.succeeded == true {
                NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("index.html")])
            } else {
                self.reportRunProblem("The HTML report could not be made: \(result?.stderr.text ?? "the tool did not start").")
            }
        }
    }
}
