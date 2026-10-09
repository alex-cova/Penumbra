import EditorIntelligence
import Foundation
import JavaIntelligence

/// Tests through Gradle and what a finished Gradle task leaves behind: compiler errors in Problems,
/// test results in the Test Results tab, and the notification that a build ended. Debugging a test is
/// the window's (`IDEJavaRunHost.debugTests`); it asks this type to start the Gradle side.
extension IDEJavaRunProvider {
    // MARK: - Running tests

    func runTests(scope: JavaTestRunScope, title: String, recording: JavaRunConfiguration? = nil) {
        guard let host else { return }
        recordTestRun(scope: scope, debug: false, from: recording)
        host.testResults.beginRun(label: "Running \(title)…", scope: scope)
        host.showTestResults()
        startGradleTests(scope: scope)
    }

    func runActiveTests() {
        guard let testClass = host?.activeJavaTestClass else { return }
        runTests(scope: .testClass(testClass), title: Self.simpleName(testClass.qualifiedName))
    }

    func runTestMethod(_ method: JavaTestMethod, taskPath: String) {
        runTests(scope: .testMethod(method, taskPath: taskPath), title: "\(method.methodName)()")
    }

    /// Remembers a test run as a configuration, so Run Last and the picker can repeat it. The
    /// configuration a run came from keeps its settings; any other run is a temporary one.
    func recordTestRun(scope: JavaTestRunScope, debug: Bool, from configuration: JavaRunConfiguration?) {
        guard let host else { return }
        var recorded: JavaRunConfiguration
        if let configuration {
            recorded = configuration
        } else {
            let fresh = JavaRunConfiguration.makeTestLaunch(scope: scope)
            let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
            recorded = fresh.inheritingSettings(from: saved.last { $0.target == fresh.target })
        }
        recorded.launchMode = debug ? .debug : .run
        host.runConfigurationStore.setLast(recorded, forProject: host.projectRootURL)
        host.refreshLastRunConfiguration()
    }

    /// Starts the Gradle test task for `scope`. With `debug` the test JVM waits for a debugger on the
    /// JDWP port (`--debug-jvm`), and Gradle's run is not timed out.
    func startGradleTests(scope: JavaTestRunScope, debug: Bool = false) {
        guard let url = gradle.rootURL else { return }
        guard let request = JavaTestRunner.request(scope: scope, projectRoot: url, model: gradle.model) else { return }
        pendingTestRunRequest = request
        let args = JavaTestRunner.gradleArguments(for: request, debug: debug)
        gradle.runGradleTasks(JavaTestRunner.taskPaths(for: request, debug: debug), extraArguments: args, runsApplication: debug)
    }

    // MARK: - A Gradle task ended

    func projectTasksDidFinish(_ report: IDEProjectTaskReport) {
        applyBuildOutput(report)
        notifyTasks(report)
        applyTestOutput(report)
    }

    /// Run and test tasks have their own panels; only builds and the like are announced.
    private func notifyTasks(_ report: IDEProjectTaskReport) {
        guard let host else { return }
        func isRunTask(_ task: String) -> Bool {
            let name = task.split(separator: ":").last.map(String.init) ?? task
            return name == "run" || name == "bootRun"
        }
        guard !report.tasks.contains(where: { JavaTestRunner.isTestTask($0) || isRunTask($0) }) else { return }
        let label = report.tasks.joined(separator: " ")
        if report.exitCode == 0 {
            host.notifications.post("Gradle \(label) finished", category: .gradle, severity: .success, action: .showGradleOutput)
        } else {
            host.notifications.post(
                "Gradle \(label) failed",
                detail: "Exit code \(report.exitCode)",
                category: .gradle,
                severity: .error,
                action: host.problems.errorCount > 0 ? .showProblems : .showGradleOutput
            )
        }
    }

    private func applyBuildOutput(_ result: IDEProjectTaskReport) {
        guard let host else { return }
        let projectRoot = result.root
        let messages = JavacOutputParser.parse(result.stderr) + JavacOutputParser.parse(result.stdout)
        let javacByFile = JavacDiagnosticsMapper.diagnostics(
            from: messages, source: "gradle", baseDirectory: projectRoot
        ) { [weak host] url in
            host?.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        let gradleProblems = GradleProblemMatcher.parse(
            result.output,
            baseDirectory: projectRoot,
            model: gradle.model
        )
        let gradleByFile = GradleProblemMatcher.diagnostics(from: gradleProblems, baseDirectory: projectRoot)
        var merged = javacByFile
        for (url, diagnostics) in gradleByFile {
            merged[url, default: []].append(contentsOf: diagnostics)
        }
        host.problems.setBuildDiagnostics(merged)
        if merged.values.contains(where: { $0.contains { $0.severity == .error } }) {
            host.showProblems()
        }
    }

    private func applyTestOutput(_ result: IDEProjectTaskReport) {
        guard result.tasks.contains(where: JavaTestRunner.isTestTask) || pendingTestRunRequest != nil else { return }
        let request = takePendingTestRunRequest()
        let projectRoot = result.root
        Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            let classes = await self.java.allTestClasses()
            let lookup: (String) -> URL? = { className in
                classes.first(where: { $0.qualifiedName == className })?.sourceFile
            }
            var parsed = JUnitXMLReportParser.parseReports(
                in: request?.reportDirectories ?? [],
                projectRoot: projectRoot,
                sourceLookup: lookup
            )
            if parsed.cases.isEmpty {
                parsed = JUnitXMLReportParser.parseGradleSummary(result.output)
            }
            host.testResults.finishRun(parsed)
            host.showTestResults()
        }
    }

    private func takePendingTestRunRequest() -> JavaTestRunRequest? {
        defer { pendingTestRunRequest = nil }
        return pendingTestRunRequest
    }

    // MARK: - ⌥↩ Run actions

    /// Carries out a Run, Debug or Modify Run Configuration chosen in the ⌥↩ menu on a `main`, a
    /// test method or a test class of the file shown in the editor.
    func performRunCodeAction(_ command: CodeActionCommand, file: URL, source: @autoclosure () -> String) {
        typealias Provider = IDERunCodeActionProvider
        guard let host, [Provider.runCommand, Provider.debugCommand, Provider.modifyCommand].contains(command.id),
              command.arguments.count == 2, let kind = Provider.Kind(rawValue: command.arguments[0]),
              let line = Int(command.arguments[1]) else { return }
        let mode: JavaLaunchMode = command.id == Provider.debugCommand ? .debug : .run
        let modify = command.id == Provider.modifyCommand

        switch kind {
        case .main:
            let text = source()
            guard let location = JavaMainMethod.locations(in: text, fileName: file.lastPathComponent).first(where: { $0.line == line }),
                  let configuration = mainRunConfiguration(for: location, file: file, source: text) else {
                host.reportRunProblem("There is nothing to run at that line.")
                return
            }
            if modify { host.openRunConfigurationDraft(configuration) } else { launch(configuration, mode: mode) }
        case .testMethod, .testClass:
            guard let testClass = host.activeJavaTestClass else {
                host.reportRunProblem("The tests of this file are not known yet. Try again in a moment.")
                return
            }
            let scope: JavaTestRunScope
            let title: String
            if kind == .testMethod, let method = testClass.methods.first(where: { $0.line == line }) {
                scope = .testMethod(method, taskPath: testClass.gradleTaskPath)
                title = "\(method.methodName)()"
            } else {
                scope = .testClass(testClass)
                title = testClass.qualifiedName.split(separator: ".").last.map(String.init) ?? testClass.qualifiedName
            }
            if modify {
                let fresh = JavaRunConfiguration.makeTestLaunch(scope: scope)
                let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
                host.openRunConfigurationDraft(fresh.inheritingSettings(from: saved.last { $0.target == fresh.target }))
            } else if mode == .debug {
                host.debugTests(scope: scope, title: title, recording: nil)
            } else {
                runTests(scope: scope, title: title)
            }
        }
    }
}
