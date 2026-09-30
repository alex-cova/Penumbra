import AppKit
import EditorIntelligence
import JavaIntelligence
import Penumbra
import SwiftUI

/// What a Java file's gutter shows besides breakpoints, from one refresh.
struct JavaGutterContent {
    let fileURL: URL
    let testClass: JavaTestClass?
    /// The line of the test class's declaration, for its Run / Debug all button.
    let classLine: Int?
    let mains: [JavaMainMethodLocation]
}

/// The debugger's side of the workspace: the Java gutter (breakpoints, run buttons), breakpoint
/// properties, the editor's debug menu items, debugging tests, stepping beyond the basics,
/// watches and stream tracing.
extension IDEWorkspace {
    private static let breakpointDecorationPrefix = "breakpoint:"

    // MARK: - Java gutter

    /// The file the pane holding `textView` shows now.
    func documentURL(shownIn textView: TextView) -> URL? {
        workbench.panes.first { hostCache.peek($0.id)?.textView === textView }?.selectedDocument?.url?.standardizedFileURL
    }

    func applyJavaGutter(_ gutter: JavaGutterContent, to textView: TextView) {
        // A refresh that finishes after the pane moved to another file must not paint this one's.
        guard documentURL(shownIn: textView) == gutter.fileURL.standardizedFileURL else { return }
        textView.alwaysShowGutterDecorationColumn = true
        let fileBreakpoints = breakpointStore.breakpoints(forFile: gutter.fileURL, project: project.rootURL)
        var decorations = fileBreakpoints.map(breakpointDecoration)
        var occupied = Set(fileBreakpoints.map(\.line))
        let green = NSColor.systemGreen.cgColor
        if let testClass = gutter.testClass, !testClass.methods.isEmpty {
            if let line = gutter.classLine, occupied.insert(line).inserted {
                decorations.append(GutterDecoration(
                    line: line, symbolName: "play.circle.fill",
                    accessibilityLabel: "Run the tests in \(Self.simpleName(testClass.qualifiedName))", tintColor: green
                ))
            }
            for method in testClass.methods where occupied.insert(method.line).inserted {
                decorations.append(GutterDecoration(
                    line: method.line, symbolName: "play.circle", accessibilityLabel: "Run \(method.displayName)", tintColor: green
                ))
            }
        }
        for main in gutter.mains where occupied.insert(main.line).inserted {
            decorations.append(GutterDecoration(
                line: main.line, symbolName: "play.fill", accessibilityLabel: "Run \(main.simpleClassName).main()", tintColor: green
            ))
        }
        textView.setGutterDecorations(decorations)
        textView.gutterDecorationHandler = { [weak self, weak textView] line in
            guard let self, let textView else { return }
            self.javaGutterDecorationClicked(line: line, gutter: gutter, textView: textView)
        }
        textView.gutterLineClickHandler = { [weak self, weak textView] click in
            guard let self, let textView else { return false }
            return self.javaGutterLineClicked(click, gutter: gutter, textView: textView)
        }
        let shownIDs = Set(fileBreakpoints.map(\.id))
        textView.gutterDecorationsDidMove = { [weak self, weak textView] decorations in
            guard let self, let textView,
                  self.documentURL(shownIn: textView) == gutter.fileURL.standardizedFileURL else { return }
            self.breakpointDecorationsMoved(decorations, shownIDs: shownIDs, file: gutter.fileURL)
        }
    }

    /// Red for a breakpoint that stops, orange for one that only logs, grey when disabled or
    /// muted; a `?` when it has a condition, a check once the debugger placed it.
    func breakpointDecoration(_ breakpoint: JavaBreakpoint) -> GutterDecoration {
        let active = breakpoint.isEnabled && !breakpointsMuted
        let logOnly = breakpoint.suspendPolicy == .none
        let color: NSColor = active ? (logOnly ? .systemOrange : .systemRed) : .systemGray
        let symbol = logOnly ? (breakpoint.isEnabled ? "diamond.fill" : "diamond") : (breakpoint.isEnabled ? "circle.fill" : "circle")
        let verified = debugSession.isActive ? debugSession.breakpointVerification[breakpoint.id] : nil
        var badge: String?
        if breakpoint.isEnabled {
            badge = breakpoint.activeCondition != nil ? "questionmark" : (verified == true ? "checkmark" : nil)
        }
        var label = breakpoint.isEnabled ? "Breakpoint" : "Disabled breakpoint"
        if let condition = breakpoint.activeCondition { label += ", when \(condition)" }
        if breakpointsMuted { label += " (muted)" }
        return GutterDecoration(
            line: breakpoint.line,
            symbolName: symbol,
            accessibilityLabel: label,
            tintColor: color.cgColor,
            badgeSymbolName: badge,
            id: Self.breakpointDecorationPrefix + breakpoint.id.uuidString
        )
    }

    /// A click on a decoration: a breakpoint goes, a run button opens its Run / Debug menu.
    private func javaGutterDecorationClicked(line: Int, gutter: JavaGutterContent, textView: TextView) {
        if let breakpoint = lineBreakpoint(at: line, file: gutter.fileURL) {
            removeBreakpoint(breakpoint)
            return
        }
        if let testClass = gutter.testClass {
            if gutter.classLine == line {
                showTestRunMenu(scope: .testClass(testClass), title: Self.simpleName(testClass.qualifiedName), in: textView)
                return
            }
            if let method = testClass.methods.first(where: { $0.line == line }) {
                showTestRunMenu(scope: .testMethod(method, taskPath: testClass.gradleTaskPath), title: "\(method.methodName)()", in: textView)
                return
            }
        }
        if gutter.mains.contains(where: { $0.line == line }) {
            showMainRunMenu(atLine: line, file: gutter.fileURL, in: textView)
        }
    }

    /// A click on a line number or an empty part of the decoration column adds or removes a
    /// breakpoint; a right click opens the breakpoint's properties, or the line's menu.
    private func javaGutterLineClicked(_ click: GutterLineClick, gutter: JavaGutterContent, textView: TextView) -> Bool {
        let breakpoint = lineBreakpoint(at: click.line, file: gutter.fileURL)
        if click.isSecondary {
            if let breakpoint {
                showBreakpointPopover(breakpoint, in: textView, focusCondition: false)
            } else {
                showGutterLineMenu(click, gutter: gutter, textView: textView)
            }
            return true
        }
        if let breakpoint {
            removeBreakpoint(breakpoint)
        } else {
            addLineBreakpoint(atLine: click.line, file: gutter.fileURL, in: textView)
        }
        return true
    }

    private func showGutterLineMenu(_ click: GutterLineClick, gutter: JavaGutterContent, textView: TextView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let toggle = IDEClosureMenuItem(title: "Toggle Line Breakpoint") { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.addLineBreakpoint(atLine: click.line, file: gutter.fileURL, in: textView)
        }
        IDERunGutterMenu.showShortcut(IDEMenuShortcuts.shortcut(for: .toggleBreakpoint, in: preferences.keymapPreset), on: toggle)
        menu.addItem(toggle)
        menu.addItem(IDEClosureMenuItem(title: "Add Conditional Breakpoint…") { [weak self, weak textView] in
            guard let self, let textView,
                  let breakpoint = self.addLineBreakpoint(atLine: click.line, file: gutter.fileURL, in: textView) else { return }
            self.showBreakpointPopover(breakpoint, in: textView, focusCondition: true)
        })
        var runItems: [NSMenuItem] = []
        if let testClass = gutter.testClass {
            if gutter.classLine == click.line {
                runItems = testRunItems(scope: .testClass(testClass), title: Self.simpleName(testClass.qualifiedName))
            } else if let method = testClass.methods.first(where: { $0.line == click.line }) {
                runItems = testRunItems(scope: .testMethod(method, taskPath: testClass.gradleTaskPath), title: "\(method.methodName)()")
            }
        }
        if runItems.isEmpty, gutter.mains.contains(where: { $0.line == click.line }) {
            let text = textView.text
            if let location = JavaMainMethod.locations(in: text).first(where: { $0.line == click.line }),
               let configuration = mainRunConfiguration(for: location, file: gutter.fileURL, source: text) {
                runItems = IDERunGutterMenu.items(
                    title: "\(location.simpleClassName).main()",
                    keymapPreset: preferences.keymapPreset,
                    run: { [weak self] in self?.launch(configuration, mode: .run) },
                    debug: { [weak self] in self?.launch(configuration, mode: .debug) }
                )
            }
        }
        if !runItems.isEmpty {
            menu.addItem(.separator())
            runItems.forEach(menu.addItem)
        }
        NSMenu.popUpContextMenu(menu, with: click.event, for: textView)
    }

    private func lineBreakpoint(at line: Int, file: URL) -> JavaBreakpoint? {
        breakpointStore.breakpoints(forFile: file, project: project.rootURL).first { $0.line == line }
    }

    /// Adds a line breakpoint, refusing a line with no code on it (blank, a comment, an import).
    @discardableResult
    func addLineBreakpoint(atLine line: Int, file: URL, in textView: TextView) -> JavaBreakpoint? {
        if let existing = lineBreakpoint(at: line, file: file) { return existing }
        if let text = Self.lineText(line, in: textView), !Self.canHoldBreakpoint(text) {
            host(for: workbench.activePaneID).intelligenceController?.showHint("No code on line \(line) to stop at")
            return nil
        }
        guard let breakpoint = breakpointStore.toggle(atLine: line, file: file, project: project.rootURL) else { return nil }
        refreshBreakpoints()
        refreshBreakpointGutters()
        return breakpoint
    }

    /// The line's text, at most 400 characters; nil when it cannot be read (the check is skipped).
    private static func lineText(_ line: Int, in textView: TextView) -> String? {
        guard line >= 1, line <= textView.lineCount,
              let start = textView.location(at: TextLocation(lineNumber: line - 1, column: 0)) else { return nil }
        let next = line < textView.lineCount ? textView.location(at: TextLocation(lineNumber: line, column: 0)) : nil
        let length = min(max(0, (next ?? start + 400) - start), 400)
        return textView.text(in: NSRange(location: start, length: length))
    }

    /// Whether a line could have code a breakpoint stops at: not blank, a comment or a declaration
    /// that compiles to nothing.
    nonisolated static func canHoldBreakpoint(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        for prefix in ["//", "/*", "*", "import ", "package ", "@"] where trimmed.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// Keeps the store's lines in step with the gutter after an edit moved breakpoints; one on a
    /// deleted line goes with it.
    private func breakpointDecorationsMoved(_ decorations: [GutterDecoration], shownIDs: Set<UUID>, file: URL) {
        var lines: [UUID: Int] = [:]
        for decoration in decorations {
            guard let id = decoration.id, id.hasPrefix(Self.breakpointDecorationPrefix),
                  let uuid = UUID(uuidString: String(id.dropFirst(Self.breakpointDecorationPrefix.count))) else { continue }
            lines[uuid] = decoration.line
        }
        let removed = shownIDs.subtracting(lines.keys)
        if breakpointStore.moveLines(in: file, to: lines, removing: removed, project: project.rootURL) {
            refreshBreakpoints()
        }
    }

    private static func simpleName(_ qualifiedName: String) -> String {
        String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName)).replacingOccurrences(of: "$", with: ".")
    }

    /// Runs a command reached by a secondary key (``IDESecondaryShortcutMonitor``).
    func perform(_ command: IDEMenuCommand) {
        switch command {
        case .toggleBreakpoint: toggleBreakpointAtCaret()
        default: break
        }
    }

    /// Toggle Breakpoint (F3, ⌘F8 in the IntelliJ keymap) on the caret's line.
    func toggleBreakpointAtCaret() {
        guard let url = workbench.activePane.selectedDocument?.url, url.pathExtension.lowercased() == "java" else { return }
        let textView = host(for: workbench.activePaneID).textView
        let line = (textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0) + 1
        if let breakpoint = lineBreakpoint(at: line, file: url) {
            removeBreakpoint(breakpoint)
        } else {
            addLineBreakpoint(atLine: line, file: url, in: textView)
        }
    }

    // MARK: - Breakpoint properties

    func showBreakpointPopover(_ breakpoint: JavaBreakpoint, in textView: TextView, focusCondition: Bool) {
        breakpointPopover.present(
            breakpoint: breakpoint,
            workspace: self,
            focusCondition: focusCondition,
            in: textView
        )
    }

    func updateBreakpoint(_ breakpoint: JavaBreakpoint) {
        breakpointStore.update(breakpoint, project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
    }

    func addBreakpoint(_ breakpoint: JavaBreakpoint) {
        breakpointStore.add(breakpoint, project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
        selectedBreakpointID = breakpoint.id
    }

    func setBreakpointsMuted(_ muted: Bool) {
        breakpointStore.setMuted(muted, project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
    }

    func toggleBreakpointsMuted() {
        setBreakpointsMuted(!breakpointsMuted)
    }

    /// Sends the breakpoints to a running debug session: added, changed, removed and disabled
    /// ones reach the program without restarting it.
    func syncBreakpointsToDebugger() {
        guard debugSession.isActive else { return }
        let breakpoints = breakpoints
        let muted = breakpointsMuted
        Task { await debugSession.sync(breakpoints, muted: muted) }
    }

    /// View Breakpoints (⇧⌘F8): the Breakpoints tab, on the caret line's breakpoint when it has one.
    func viewBreakpoints(select id: UUID? = nil) {
        if let id {
            selectedBreakpointID = id
        } else if let url = workbench.activePane.selectedDocument?.url {
            let textView = host(for: workbench.activePaneID).textView
            let line = (textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0) + 1
            if let breakpoint = lineBreakpoint(at: line, file: url) { selectedBreakpointID = breakpoint.id }
        }
        showSidebarTab(.breakpoints)
    }

    // MARK: - Editor context menu

    /// The Java editor's debug items: Toggle Line Breakpoint always; while stopped, Evaluate
    /// Expression, Add to Watches, Run to Cursor and Smart Step Into.
    func editorContextMenuItems(context: EditorContextMenuContext, paneID: UUID, url: URL?) -> [NSMenuItem] {
        guard let url, url.pathExtension.lowercased() == "java" else { return [] }
        let textView = host(for: paneID).textView
        let location = context.location ?? textView.selectedRange.location
        let line = (textView.textLocation(at: location)?.lineNumber ?? 0) + 1
        let preset = preferences.keymapPreset
        var items: [NSMenuItem] = []
        let toggle = IDEClosureMenuItem(title: lineBreakpoint(at: line, file: url) == nil ? "Add Line Breakpoint" : "Remove Line Breakpoint") {
            [weak self, weak textView] in
            guard let self, let textView else { return }
            if let breakpoint = self.lineBreakpoint(at: line, file: url) {
                self.removeBreakpoint(breakpoint)
            } else {
                self.addLineBreakpoint(atLine: line, file: url, in: textView)
            }
        }
        IDERunGutterMenu.showShortcut(IDEMenuShortcuts.shortcut(for: .toggleBreakpoint, in: preset), on: toggle)
        items.append(toggle)
        guard isDebuggerStopped else { return items }

        let selection = context.selectedRange ?? NSRange(location: location, length: 0)
        let expression: String? = {
            if selection.length > 0, let text = textView.text(in: selection)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, !text.contains("\n") {
                return text
            }
            return IDEEvaluateExpressionScanner.expression(in: textView.text, selection: NSRange(location: location, length: 0))
        }()
        items.append(.separator())
        let evaluate = IDEClosureMenuItem(title: "Evaluate Expression…") { [weak self] in
            self?.showEvaluateExpression(prefill: expression)
        }
        IDERunGutterMenu.showShortcut(IDEMenuShortcuts.shortcut(for: .evaluateExpression, in: preset), on: evaluate)
        items.append(evaluate)
        if let expression {
            items.append(IDEClosureMenuItem(title: "Add to Watches") { [weak self] in self?.addWatch(expression) })
        }
        let runToCursor = IDEClosureMenuItem(title: "Run to Cursor") { [weak self] in
            self?.debugRunToCursor(file: url, line: line, force: false)
        }
        IDERunGutterMenu.showShortcut(IDEMenuShortcuts.shortcut(for: .debugRunToCursor, in: preset), on: runToCursor)
        items.append(runToCursor)
        items.append(IDEClosureMenuItem(title: "Force Run to Cursor") { [weak self] in
            self?.debugRunToCursor(file: url, line: line, force: true)
        })
        let smart = IDEClosureMenuItem(title: "Smart Step Into…") { [weak self] in self?.debugSmartStepInto() }
        IDERunGutterMenu.showShortcut(IDEMenuShortcuts.shortcut(for: .debugSmartStepInto, in: preset), on: smart)
        items.append(smart)
        return items
    }

    /// Evaluate Expression (⌥F8) opened with `prefill` in the field.
    func showEvaluateExpression(prefill: String?) {
        guard isDebuggerStopped else { return }
        selectDebugTab()
        debugSession.requestEvaluationInput(prefilledWith: prefill)
    }

    // MARK: - Running and debugging tests

    private func testRunItems(scope: JavaTestRunScope, title: String) -> [NSMenuItem] {
        IDERunGutterMenu.items(
            title: title,
            keymapPreset: preferences.keymapPreset,
            run: { [weak self] in self?.runTests(scope: scope, title: title) },
            debug: { [weak self] in self?.debugTests(scope: scope, title: title) }
        )
    }

    /// The Run / Debug menu of a test button (IntelliJ's popup on a test's gutter icon).
    private func showTestRunMenu(scope: JavaTestRunScope, title: String, in textView: TextView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        testRunItems(scope: scope, title: title).forEach(menu.addItem)
        IDERunGutterMenu.popUp(menu, in: textView)
    }

    func runTests(scope: JavaTestRunScope, title: String) {
        testResults.beginRun(label: "Running \(title)…", scope: scope)
        showTestResults()
        javaSupport.runTests(scope: scope)
    }

    /// Runs tests under the debugger: Gradle starts the test JVM with `--debug-jvm`, which waits on
    /// the JDWP port until the adapter attaches, then the breakpoints stop in the tests. The
    /// results still arrive in the Test Results tab.
    func debugTests(scope: JavaTestRunScope, title: String) {
        guard project.rootURL != nil, javaSupport.isGradleProject else {
            reportRunProblem("Debugging tests needs a Gradle project.")
            return
        }
        guard !javaSupport.isGradleBusy else {
            reportRunProblem("Gradle is busy. Stop the running task first, then debug ‘\(title)’ again.")
            return
        }
        let sourceFile: URL? = switch scope {
        case .testClass(let testClass): testClass.sourceFile
        case .testMethod(let method, _): method.sourceFile
        case .allInModule, .tests: nil
        }
        let classpath = sourceFile.flatMap { javaSupport.gradleModel?.runtimeClasspath(forFile: $0) } ?? []
        let maxLanguageLevel = javaSupport.gradleModel?.maxLanguageLevel
        Task { [self] in
            guard let jdk = await javaSupport.jdk.resolve(minimumFeatureVersion: maxLanguageLevel)?.installation else {
                reportRunProblem("No JDK found for debugging.")
                return
            }
            let breakpoints = breakpointStore.breakpoints(forProject: project.rootURL)
            let muted = breakpointsMuted
            selectDebugTab()
            do {
                try await debugSession.prepareAdapter(javaHome: jdk.home)
            } catch {
                reportRunProblem("Could not start the debug adapter: \(error.localizedDescription)")
                return
            }
            gradleDebugActive = true
            configureDebugSession()
            testResults.beginRun(label: "Debugging \(title)…", scope: scope, debug: true)
            let roots = debugSourceRoots()
            Task {
                await debugSession.attachForGradle(
                    suspendOnStart: false,
                    breakpoints: breakpoints,
                    muted: muted,
                    sourceRoots: roots,
                    classpath: classpath
                )
            }
            javaSupport.runTests(scope: scope, debug: true)
        }
    }

    /// Rerun (⌃⌥R in the Test Results tab): the last test run again, debugged if it was.
    func rerunTests(failedOnly: Bool, debug: Bool? = nil) {
        guard let last = testResults.lastScope else { return }
        let scope = failedOnly ? (testResults.failedScope ?? last) : last
        let title = testResults.title(for: scope)
        if debug ?? testResults.lastRunWasDebug {
            debugTests(scope: scope, title: title)
        } else {
            runTests(scope: scope, title: title)
        }
    }

    /// Opens a test case at its method, else at the line its failure points to.
    func openTestSource(_ testCase: JavaTestCaseResult) {
        Task { [self] in
            let classes = await javaSupport.allTestClasses()
            let methodName = String(testCase.name.prefix { $0 != "(" && $0 != "[" && $0 != " " })
            if let method = classes.lazy.flatMap(\.methods).first(where: { $0.className == testCase.className && $0.methodName == methodName }) {
                revealDebugStop(file: method.sourceFile, line: method.line)
            } else if let file = testCase.sourceFile {
                revealDebugStop(file: file, line: testCase.line ?? 1)
            }
        }
    }

    /// Runs or debugs one test case from the Test Results tree.
    func runTestCase(_ testCase: JavaTestCaseResult, debug: Bool) {
        Task { [self] in
            let classes = await javaSupport.allTestClasses()
            let methodName = String(testCase.name.prefix { $0 != "(" && $0 != "[" && $0 != " " })
            guard let testClass = classes.first(where: { $0.methods.contains { $0.className == testCase.className } }),
                  let method = testClass.methods.first(where: { $0.className == testCase.className && $0.methodName == methodName }) else {
                reportRunProblem("Cannot find the test ‘\(testCase.name)’ in the project.")
                return
            }
            let scope = JavaTestRunScope.testMethod(method, taskPath: testClass.gradleTaskPath)
            if debug { debugTests(scope: scope, title: "\(methodName)()") } else { runTests(scope: scope, title: "\(methodName)()") }
        }
    }

    /// Opens `File.java:N` of a stack frame: the class's package path under a source root.
    func openStackFrame(_ frame: IDEStackFrameReference) {
        var components = frame.className.split(separator: ".").map(String.init)
        components.removeLast()
        let relative = (components + [frame.fileName]).joined(separator: "/")
        for root in debugSourceRoots() {
            let candidate = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                revealDebugStop(file: candidate, line: frame.line)
                return
            }
        }
        reportRunProblem("\(frame.fileName) is not in the project's sources.")
    }

    /// The test a Structure node stands for in the active test class: the class, or one method.
    func structureTestTarget(for node: JavaStructureNode) -> (scope: JavaTestRunScope, title: String)? {
        guard let testClass = activeJavaTestClass, !testClass.methods.isEmpty else { return nil }
        let name = String(node.title.prefix { $0 != "(" && $0 != "<" && $0 != " " && $0 != ":" })
        switch node.kind {
        case .method:
            guard let method = testClass.methods.first(where: { $0.methodName == name }) else { return nil }
            return (.testMethod(method, taskPath: testClass.gradleTaskPath), "\(method.methodName)()")
        case .type:
            let simpleName = Self.simpleName(testClass.qualifiedName).split(separator: ".").last.map(String.init)
            guard name == simpleName else { return nil }
            return (.testClass(testClass), name)
        default:
            return nil
        }
    }

    /// Rerun in the Debug tool window: the last debugged tests, else the last configuration.
    func rerunDebugSession() {
        if testResults.lastRunWasDebug, testResults.lastScope != nil {
            rerunTests(failedOnly: false, debug: true)
        } else {
            debugLastConfiguration()
        }
    }

    // MARK: - Stepping

    func debugForceStepInto() { debugSession.forceStepInto() }
    func debugDropFrame() { debugSession.dropFrame() }

    /// Run to Cursor (⌥F9): to the caret's line in the active editor.
    func debugRunToCursor(force: Bool) {
        guard let url = workbench.activePane.selectedDocument?.url else { return }
        let textView = host(for: workbench.activePaneID).textView
        let line = (textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0) + 1
        debugRunToCursor(file: url, line: line, force: force)
    }

    func debugRunToCursor(file: URL, line: Int, force: Bool) {
        guard isDebuggerStopped else { return }
        debugSession.runToCursor(file: file.standardizedFileURL.path, line: line, force: force)
    }

    /// Smart Step Into (⇧F7): lists the calls on the stopped line and steps into the one picked.
    func debugSmartStepInto() {
        guard case .stopped(let file, let line, _) = debugSession.state, file.path.hasPrefix("/") else { return }
        let text = openBufferText(for: file) ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        Task { [self] in
            let calls = await Task.detached(priority: .userInitiated) { JavaCallSites.calls(onLine: line, in: text) }.value
            switch calls.count {
            case 0:
                debugSession.stepInto()
            case 1:
                debugSession.smartStepInto(methodName: calls[0].methodName)
            default:
                presentSmartStepChoices(calls)
            }
        }
    }

    private func presentSmartStepChoices(_ calls: [JavaLineCall]) {
        let menu = NSMenu(title: "Smart Step Into")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Step Into", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for call in calls {
            menu.addItem(IDEClosureMenuItem(title: call.displayText) { [weak self] in
                self?.debugSession.smartStepInto(methodName: call.methodName)
            })
        }
        let textView = host(for: workbench.activePaneID).textView
        let caret = textView.caretRectInViewport(at: textView.selectedRange.location)
        menu.popUp(positioning: nil, at: NSPoint(x: caret.minX, y: caret.maxY + 2), in: textView)
    }

    /// Force Return: asks for the value when the method returns one, then returns it.
    func debugForceReturn() {
        guard isDebuggerStopped, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Force Return"
        alert.informativeText = "The current method returns at once. Enter the value to return, or leave it empty for a void method."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Return value"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Return")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = field.stringValue
            Task {
                if let problem = await self.debugSession.forceReturn(expression: value) {
                    self.reportRunProblem("Force Return: \(problem)")
                }
            }
        }
    }

    /// Show Execution Point (⌥F10): back to the line the program is stopped at.
    func showExecutionPoint() {
        guard case .stopped(let file, let line, _) = debugSession.state, file.path.hasPrefix("/") else { return }
        revealDebugStop(file: file, line: line)
    }

    // MARK: - Inline values

    /// Shows the selected frame's locals at the end of the lines that last set them, as IntelliJ's
    /// inline debugger does; clears them when the program runs on. Only the stopped method's lines
    /// are looked at, once per stop or frame change.
    func refreshInlineDebugValues() {
        for pane in workbench.panes {
            if let textView = hostCache.peek(pane.id)?.textView, !textView.supplementaryInlayHints.isEmpty {
                textView.supplementaryInlayHints = []
            }
        }
        guard isDebuggerStopped,
              let frame = debugSession.stackFrames.first(where: { $0.index == debugSession.selectedFrameIndex }),
              frame.filePath.hasPrefix("/") else { return }
        let file = URL(fileURLWithPath: frame.filePath).standardizedFileURL
        let values = debugSession.variables.filter { $0.name != nil && $0.name != "this" }
        guard !values.isEmpty,
              let pane = workbench.panes.first(where: { $0.selectedDocument?.url?.standardizedFileURL == file }),
              let textView = hostCache.peek(pane.id)?.textView else { return }
        textView.supplementaryInlayHints = Self.inlineValueHints(
            values.map { ($0.name ?? "", $0.value) }, stopLine: frame.line, text: textView.text
        )
    }

    /// One hint per line, at its end: `name = value` for each local whose last mention at or above
    /// `stopLine`, within the method, is on that line.
    nonisolated static func inlineValueHints(_ values: [(name: String, value: String)], stopLine: Int, text: String) -> [InlayHint] {
        let string = text as NSString
        // The lines up to the stop line, without their line breaks.
        var lineRanges: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) {
            _, range, _, stop in
            lineRanges.append(range)
            if lineRanges.count >= stopLine { stop.pointee = true }
        }
        guard stopLine >= 1, lineRanges.count >= stopLine else { return [] }
        // Back to the method's signature, at most 200 lines.
        var firstLine = max(1, stopLine - 200)
        for line in stride(from: stopLine, through: firstLine, by: -1) {
            let content = string.substring(with: lineRanges[line - 1])
            if content.range(of: #"^\s*(?:(?:public|private|protected|static|final|synchronized|abstract)\s+)*[\w<>\[\],.? ]+\s+\w+\s*\([^;]*$"#,
                             options: .regularExpression) != nil,
               content.range(of: #"^\s*(if|for|while|switch|catch|return|else|new)\b"#, options: .regularExpression) == nil {
                firstLine = line
                break
            }
        }
        var labels: [Int: [String]] = [:]
        for (name, value) in values {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            for line in stride(from: stopLine, through: firstLine, by: -1) {
                let content = string.substring(with: lineRanges[line - 1])
                if content.range(of: pattern, options: .regularExpression) != nil {
                    let shown = value.count > 40 ? String(value.prefix(40)) + "…" : value
                    labels[line, default: []].append("\(name) = \(shown)")
                    break
                }
            }
        }
        return labels.compactMap { line, parts -> InlayHint? in
            // In front of the line break: the hint widens the line's last character.
            let range = lineRanges[line - 1]
            guard range.length > 0 else { return nil }
            return InlayHint(utf16Offset: NSMaxRange(range), label: parts.joined(separator: ", "), kind: .other)
        }
    }

    // MARK: - Watches

    private var watchesDefaultsKey: String {
        "umbra.debug.watches." + (project.rootURL?.standardizedFileURL.path ?? "")
    }

    func loadWatches() {
        watches = UserDefaults.standard.stringArray(forKey: watchesDefaultsKey) ?? []
        debugSession.watches = watches
    }

    func addWatch(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !watches.contains(trimmed) else { return }
        setWatches(watches + [trimmed])
        selectDebugTab()
    }

    func replaceWatch(_ old: String, with new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = watches.firstIndex(of: old) else { return }
        var updated = watches
        if trimmed.isEmpty { updated.remove(at: index) } else { updated[index] = trimmed }
        setWatches(updated)
    }

    func removeWatch(_ expression: String) {
        setWatches(watches.filter { $0 != expression })
    }

    private func setWatches(_ list: [String]) {
        watches = list
        UserDefaults.standard.set(list, forKey: watchesDefaultsKey)
        debugSession.watches = list
    }

    // MARK: - Stream trace

    /// Trace Current Stream Chain: finds the stream pipeline on the stopped line, runs it again
    /// with a `peek` after each stage, and shows what each stage saw.
    func traceCurrentStream() {
        guard case .stopped(let file, let line, _) = debugSession.state, file.path.hasPrefix("/") else { return }
        let text = openBufferText(for: file) ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        Task { [self] in
            let chains = await Task.detached(priority: .userInitiated) { JavaStreamChain.chains(onLine: line, in: text) }.value
            guard !chains.isEmpty else {
                reportRunProblem("There is no stream chain on line \(line).")
                return
            }
            if chains.count == 1 {
                await traceStream(chains[0])
                return
            }
            let menu = NSMenu(title: "Trace Stream")
            menu.autoenablesItems = false
            for chain in chains {
                let title = chain.source + chain.intermediates.map(\.text).joined() + chain.terminal.text
                menu.addItem(IDEClosureMenuItem(title: String(title.prefix(80))) { [weak self] in
                    Task { await self?.traceStream(chain) }
                })
            }
            let textView = host(for: workbench.activePaneID).textView
            let caret = textView.caretRectInViewport(at: textView.selectedRange.location)
            menu.popUp(positioning: nil, at: NSPoint(x: caret.minX, y: caret.maxY + 2), in: textView)
        }
    }

    private func traceStream(_ chain: JavaStreamChain) async {
        let controller = streamTraceWindow ?? IDEStreamTraceWindowController()
        streamTraceWindow = controller
        controller.showLoading(chain: chain)
        switch await debugSession.traceStream(expression: chain.tracedExpression()) {
        case .success(let trace):
            controller.show(chain: chain, stages: trace.stages, result: trace.result, session: debugSession)
        case .failure(let error):
            controller.showFailure(chain: chain, message: JavaDebugSession.message(for: error))
        }
    }
}
