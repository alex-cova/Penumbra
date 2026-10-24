import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// The window's side of a debug session: Evaluate, wiring a session's callbacks to the editor,
/// revealing where it stopped, and the stepping controls for Java (JDI), Swift and JavaScript sessions.
/// The tool window, gutters and breakpoint sync are in `IDEWorkspace+Debugger.swift`.
extension IDEWorkspace {

    /// Opens the Debug tool window on its Evaluate field (⌥F8), starting from the selection.
    func showEvaluateExpression() {
        guard isDebuggerStopped else { return }
        let textView = host(for: workbench.activePaneID).textView
        let range = textView.selectedRange
        let selected = range.length > 0 ? (textView.text as NSString).substring(with: range) : nil
        showBottomTab(.debug)
        debugSession.requestEvaluationInput(prefilledWith: selected.flatMap { $0.contains("\n") ? nil : $0 })
    }

    /// Shows the value of the selection, or of the name at the caret, in a popover (⌥⌘F8).
    func quickEvaluate() {
        guard isDebuggerStopped else { return }
        let textView = host(for: workbench.activePaneID).textView
        let range = textView.selectedRange
        guard let expression = IDEEvaluateExpressionScanner.expression(in: textView.text, selection: range) else {
            host(for: workbench.activePaneID).intelligenceController?.showHint("No expression at the caret")
            return
        }
        quickEvaluatePopover.present(expression: expression, session: debugSession, in: textView, at: range.location)
    }

    func debugSourceRoots() -> [URL] {
        javaRun.debugSourceRoots()
    }

    func configureDebugSession() {
        debugSession.onStopped = { [weak self] file, line in
            self?.revealDebugStop(file: file, line: line, selectsLine: false)
        }
        debugSession.onBreakpointRemovedByHit = { [weak self] id in
            guard let self else { return }
            self.breakpointStore.remove(breakpointID: id, project: self.project.rootURL)
            self.refreshBreakpoints()
            self.refreshBreakpointGutters()
        }
        // An open file's imports come from its buffer, which may be ahead of the disk.
        debugSession.importsProvider = { [weak self] path in
            if let text = self?.openBufferText(for: URL(fileURLWithPath: path)) {
                return JavaDebugSession.imports(inSource: text)
            }
            return JavaDebugSession.imports(ofFile: path)
        }
        debugSession.watches = watches
        debugSession.onBreakpointVerificationChanged = { [weak self] in
            self?.refreshBreakpointGutters()
        }
        debugSession.onVariablesChanged = { [weak self] in
            self?.refreshExecutionLineBackgrounds()
            self?.refreshInlineDebugValues()
        }
        dapDebugSession.onStopped = { [weak self] file, line in
            self?.revealDebugStop(file: file, line: line, selectsLine: false)
            self?.refreshExecutionLineBackgrounds()
        }
    }

    /// Opens the file the program stopped in and selects the stopped line. The execution point
    /// passes `selectsLine: false`: it puts the caret at the line's start and leaves the line to
    /// the background band of `refreshExecutionLineBackgrounds`.
    func revealDebugStop(file: URL, line: Int, selectsLine: Bool = true) {
        let text = openBufferText(for: file) ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let start = TextPosition(line: max(0, line - 1), column: 0, utf16Offset: 0)
        let end = TextPosition(line: max(0, line - 1), column: Int.max / 2, utf16Offset: 0)
        let nsRange = ProblemLocator.nsRange(for: EditorIntelligence.TextRange(start: start, end: end), in: text)
        let document = workbench.allDocuments().first { $0.url?.standardizedFileURL == file.standardizedFileURL }
        _ = openNavigationLocation(Location(
            documentID: document?.documentID ?? DocumentID(),
            url: file,
            range: EditorIntelligence.TextRange(
                start: TextPosition(line: start.line, column: 0, utf16Offset: nsRange.location),
                end: selectsLine
                    ? TextPosition(line: start.line, column: nsRange.length, utf16Offset: nsRange.location + nsRange.length)
                    : TextPosition(line: start.line, column: 0, utf16Offset: nsRange.location)
            ),
            displayName: file.lastPathComponent
        ))
    }

    /// True while a debug session is stopped at a line, so stepping and Resume mean something.
    var isDebuggerStopped: Bool {
        if dapDebugSession.isStopped { return true }
        if case .stopped = debugSession.state { return true }
        return false
    }

    var isDebuggerRunning: Bool {
        if dapDebugSession.state == .running { return true }
        if case .running = debugSession.state { return true }
        return false
    }

    var swiftDebugIsCurrent: Bool { dapDebugSession.isActive }

    func debugResume() {
        if swiftDebugIsCurrent { dapDebugSession.resume(); return }
        debugSession.resume()
    }

    func debugPause() {
        if swiftDebugIsCurrent { dapDebugSession.pause(); return }
        debugSession.pause()
    }

    func debugStepOver() {
        if swiftDebugIsCurrent { dapDebugSession.stepOver(); return }
        debugSession.stepOver()
    }

    func debugStepInto() {
        if swiftDebugIsCurrent { dapDebugSession.stepInto(); return }
        debugSession.stepInto()
    }

    func debugStepOut() {
        if swiftDebugIsCurrent { dapDebugSession.stepOut(); return }
        debugSession.stepOut()
    }

    func stopDebugging() {
        if gradleDebugActive || debugSession.isGradleAttachSession {
            gradleDebugActive = false
            gradle.cancelTasks()
        }
        if dapDebugSession.isActive { dapDebugSession.stop() }
        debugSession.stop()
    }
}
