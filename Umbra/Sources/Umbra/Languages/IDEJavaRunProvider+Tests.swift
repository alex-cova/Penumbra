import EditorIntelligence
import Foundation
import JavaIntelligence

/// Tests through Gradle and what a finished Gradle task leaves behind: compiler errors in Problems,
/// test results in the Test Results tab, and the notification that a build ended. Debugging a test is
/// the window's (`IDEJavaRunHost.debugTests`); it asks this type to start the Gradle side.
extension IDEJavaRunProvider {
    // MARK: - Running tests

    func runTests(
        scope: JavaTestRunScope, title: String, recording: JavaRunConfiguration? = nil,
        instrumentation requested: JavaRunInstrumentation = .none
    ) {
        guard let host else { return }
        let instrumentation = requested != .none ? requested : (recording?.instrumentation ?? .none)
        recordTestRun(scope: scope, debug: false, from: recording, instrumentation: instrumentation)
        if usesMaven {
            guard let reason = mavenTestBlockReason() else {
                let suffix = instrumentation == .coverage ? " with coverage" : (instrumentation == .profile ? " with profiling" : "")
                host.testResults.beginRun(label: "Running \(title)\(suffix)…", scope: scope, instrumentation: instrumentation)
                host.showTestResults()
                startMavenTests(scope: scope, instrumentation: instrumentation)
                return
            }
            host.reportRunProblem(reason)
            return
        }
        guard let reason = gradleTestBlockReason() else {
            let suffix = instrumentation == .coverage ? " with coverage" : (instrumentation == .profile ? " with profiling" : "")
            host.testResults.beginRun(label: "Running \(title)\(suffix)…", scope: scope, instrumentation: instrumentation)
            host.showTestResults()
            startGradleTests(scope: scope, instrumentation: instrumentation)
            return
        }
        // A run that cannot start must not leave the Test Results tab on "Running…".
        host.reportRunProblem(reason)
    }

    /// The open test class when the editor is showing one. Otherwise every test task in the
    /// Gradle project: the Actions command is available as soon as a project is open, and a
    /// project with no test file focused still has tests to run.
    func runActiveTests(instrumentation: JavaRunInstrumentation = .none) {
        if let testClass = host?.activeJavaTestClass, !testClass.methods.isEmpty {
            runTests(scope: .testClass(testClass), title: Self.simpleName(testClass.qualifiedName), instrumentation: instrumentation)
            return
        }
        if usesMaven, maven.rootURL != nil {
            runTests(scope: .allInModule(gradleTaskPath: "test"), title: "all tests", instrumentation: instrumentation)
            return
        }
        guard gradle.isActive, gradle.rootURL != nil else {
            host?.reportRunProblem("Running tests needs a Gradle project.")
            return
        }
        runTests(scope: .allInModule(gradleTaskPath: "test"), title: "all tests", instrumentation: instrumentation)
    }

    /// Why a Gradle test task cannot start, or nil when it can.
    private func gradleTestBlockReason() -> String? {
        guard gradle.isActive, gradle.rootURL != nil else {
            return "Running tests needs a Gradle project."
        }
        guard !gradle.isBusy else {
            return "Gradle is busy. Stop the running task first, then run tests again."
        }
        return nil
    }

    /// Why a Maven test goal cannot start, or nil when it can.
    private func mavenTestBlockReason() -> String? {
        guard maven.isActive, maven.rootURL != nil else {
            return "Running tests needs a Maven project."
        }
        guard !maven.isBusy else {
            return "Maven is busy. Stop the running goal first, then run tests again."
        }
        return nil
    }

    func runTestMethod(_ method: JavaTestMethod, taskPath: String) {
        runTests(scope: .testMethod(method, taskPath: taskPath), title: "\(method.methodName)()")
    }

    /// Remembers a test run as a configuration, so Run Last and the picker can repeat it. The
    /// configuration a run came from keeps its settings; any other run is a temporary one.
    func recordTestRun(
        scope: JavaTestRunScope, debug: Bool, from configuration: JavaRunConfiguration?,
        instrumentation: JavaRunInstrumentation = .none
    ) {
        guard let host else { return }
        var recorded: JavaRunConfiguration
        if let configuration {
            recorded = configuration
        } else if usesMaven {
            let fresh = makeMavenTestLaunch(scope: scope)
            let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
            recorded = fresh.inheritingSettings(from: saved.last { $0.target == fresh.target })
        } else {
            let fresh = JavaRunConfiguration.makeTestLaunch(scope: scope)
            let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
            recorded = fresh.inheritingSettings(from: saved.last { $0.target == fresh.target })
        }
        recorded.launchMode = debug ? .debug : .run
        recorded.instrumentation = debug ? .none : instrumentation
        host.runConfigurationStore.setLast(recorded, forProject: host.projectRootURL)
        host.refreshLastRunConfiguration()
    }

    /// Starts the Gradle test task for `scope`. With `debug` the test JVM waits for a debugger on the
    /// JDWP port (`--debug-jvm`), and Gradle's run is not timed out.
    func startGradleTests(scope: JavaTestRunScope, debug: Bool = false, instrumentation: JavaRunInstrumentation = .none) {
        guard let url = gradle.rootURL else { return }
        guard var request = JavaTestRunner.request(scope: scope, projectRoot: url, model: gradle.model) else { return }
        let taskPaths = JavaTestRunner.executionTaskPaths(scope: scope, model: gradle.model, debug: debug)
        let reports = JavaTestRunner.reportDirectories(forTaskPaths: taskPaths, model: gradle.model)
        if !reports.isEmpty {
            request = JavaTestRunRequest(
                gradleTaskPath: request.gradleTaskPath,
                testFilter: request.testFilter,
                additionalTestFilters: request.additionalTestFilters,
                projectRoot: request.projectRoot,
                reportDirectories: reports
            )
        }
        pendingTestRunRequest = request
        let args = JavaTestRunner.gradleArguments(for: request, debug: debug)
        guard instrumentation != .none, !debug else {
            runTestTasks(taskPaths, arguments: args, debug: debug)
            return
        }
        var configuration = JavaRunConfiguration.makeTestLaunch(scope: scope)
        configuration.instrumentation = instrumentation
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let plan = await self.instrumentationPlan(for: configuration, tasks: taskPaths) else {
                self.pendingTestRunRequest = nil
                self.host?.testResults.stopRun(message: "The tests were not started.")
                return
            }
            switch self.gradleArguments(for: plan) {
            case .failure(let failure):
                self.pendingTestRunRequest = nil
                self.host?.testResults.stopRun(message: failure.message)
                self.host?.reportRunProblem(failure.message)
            case .success(let extra):
                self.pendingInstrumentation = (plan, taskPaths)
                self.runTestTasks(taskPaths, arguments: args + extra, debug: false)
                if case .profile(let profile) = plan { self.beginLiveProfile(profile, processID: nil) }
            }
        }
    }

    /// A configuration that repeats `scope` through Maven. `makeTestLaunch` stays a Gradle test.
    private func makeMavenTestLaunch(scope: JavaTestRunScope) -> JavaRunConfiguration {
        switch scope {
        case .allInModule(let taskPath):
            return JavaRunConfiguration(target: .mavenTest(module: mavenModulePath(forTask: taskPath), filters: [], sourceFile: nil))
        case .testClass(let testClass):
            return JavaRunConfiguration(target: .mavenTest(
                module: mavenModulePath(forTask: testClass.gradleTaskPath),
                filters: [testClass.qualifiedName],
                sourceFile: testClass.sourceFile.path
            ))
        case .testMethod(let method, let taskPath):
            return JavaRunConfiguration(target: .mavenTest(
                module: mavenModulePath(forTask: taskPath),
                filters: [method.gradleTestFilter(includeMethod: true)],
                sourceFile: method.sourceFile.path
            ))
        case .tests(let taskPath, let filters):
            return JavaRunConfiguration(target: .mavenTest(module: mavenModulePath(forTask: taskPath), filters: filters, sourceFile: nil))
        }
    }

    /// `:services:api:test` is `:services:api`. `:test` is the root. An unqualified `test` is the reactor.
    func mavenModulePath(forTask taskPath: String) -> String? {
        if taskPath == "test" { return nil }
        if taskPath == ":test" { return ":" }
        if taskPath.hasSuffix(":test") {
            let head = String(taskPath.dropLast(":test".count))
            return head.isEmpty ? ":" : head
        }
        return taskPath
    }

    /// Starts Maven's `test` goal for `scope`. `module` stays nil because the command already carries `-pl`.
    func startMavenTests(scope: JavaTestRunScope, debug: Bool = false, instrumentation: JavaRunInstrumentation = .none) {
        guard let host, let url = maven.rootURL, let model = maven.model else { return }
        guard let command = MavenTestRunner.command(scope: scope, model: model, debug: debug) else {
            host.testResults.stopRun(message: "The tests were not started.")
            return
        }
        let taskPath = mavenTaskPath(scope)
        pendingTestRunRequest = JavaTestRunRequest(
            gradleTaskPath: taskPath,
            testFilter: MavenTestRunner.testPattern(scope),
            projectRoot: url,
            reportDirectories: command.reportDirectories
        )
        let tasks = command.goals
        guard instrumentation != .none, !debug else {
            runMavenTestGoals(command.goals, arguments: command.arguments)
            return
        }
        var configuration = makeMavenTestLaunch(scope: scope)
        configuration.instrumentation = instrumentation
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let plan = await self.instrumentationPlan(for: configuration, tasks: tasks) else {
                self.pendingTestRunRequest = nil
                self.host?.testResults.stopRun(message: "The tests were not started.")
                return
            }
            switch self.mavenTestArguments(for: plan, scope: scope) {
            case .failure(let failure):
                self.pendingTestRunRequest = nil
                self.host?.testResults.stopRun(message: failure.message)
                self.host?.reportRunProblem(failure.message)
            case .success(let extra):
                self.pendingInstrumentation = (plan, tasks)
                self.runMavenTestGoals(command.goals, arguments: command.arguments + extra)
                if case .profile(let profile) = plan { self.beginLiveProfile(profile, processID: nil) }
            }
        }
    }

    func mavenTaskPath(_ scope: JavaTestRunScope) -> String {
        switch scope {
        case .allInModule(let taskPath): return taskPath
        case .testClass(let testClass): return testClass.gradleTaskPath
        case .testMethod(_, let taskPath): return taskPath
        case .tests(let taskPath, _): return taskPath
        }
    }

    private func runMavenTestGoals(_ goals: [String], arguments: [String]) {
        maven.runGoals(goals, module: nil, extraArguments: arguments) { [weak self] outcome in
            guard let self, let host = self.host else { return }
            switch outcome {
            case .notStarted(let reason), .failed(let reason):
                self.pendingInstrumentation = nil
                host.testResults.stopRun(message: reason)
                host.reportRunProblem(reason)
            case .finished, .timedOut, .cancelled:
                break
            }
        }
    }

    private func runTestTasks(_ taskPaths: [String], arguments args: [String], debug: Bool) {
        gradle.runGradleTasks(taskPaths, extraArguments: args, runsApplication: debug) { [weak self] outcome in
            guard let self, let host = self.host else { return }
            switch outcome {
            case .notStarted(let reason), .failed(let reason):
                // A declined trust prompt or a missing Gradle never produces results. Leave the
                // Test Results tab on that reason instead of "Running…" with no run behind it.
                self.pendingInstrumentation = nil
                host.testResults.stopRun(message: reason)
                host.reportRunProblem(reason)
            case .finished, .timedOut, .cancelled:
                break
            }
        }
    }

    // MARK: - A Gradle task ended

    func projectTasksDidFinish(_ report: IDEProjectTaskReport) {
        applyBuildOutput(report)
        notifyTasks(report)
        applyTestOutput(report)
        applyInstrumentationOutput(report)
    }

    /// The task run a coverage or profile plan was made for ended: read what it wrote. A build or a
    /// before-launch task that ends meanwhile is not that run.
    private func applyInstrumentationOutput(_ report: IDEProjectTaskReport) {
        guard let pending = pendingInstrumentation, pending.tasks == report.tasks else { return }
        pendingInstrumentation = nil
        finishGradleRun(plan: pending.plan, report: report)
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
        let mavenRun = usesMaven
        let title = mavenRun ? "Maven" : "Gradle"
        let category: IDENotificationCategory = mavenRun ? .maven : .gradle
        let output: IDENotificationAction = mavenRun ? .showMavenOutput : .showGradleOutput
        if report.exitCode == 0 {
            host.notifications.post("\(title) \(label) finished", category: category, severity: .success, action: output)
        } else {
            host.notifications.post(
                "\(title) \(label) failed",
                detail: "Exit code \(report.exitCode)",
                category: category,
                severity: .error,
                action: host.problems.errorCount > 0 ? .showProblems : output
            )
        }
    }

    /// The text each built file's diagnostics were mapped against (the open buffer, else the
    /// file on disk), so the editors can tell current build rows from stale ones.
    private func buildTexts(for diagnostics: [URL: [Diagnostic]]) -> [URL: String] {
        var texts: [URL: String] = [:]
        for url in diagnostics.keys {
            if let text = host?.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) {
                texts[url] = text
            }
        }
        return texts
    }

    private func applyBuildOutput(_ result: IDEProjectTaskReport) {
        guard let host else { return }
        let projectRoot = result.root
        let command = GradleCommandResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        if usesMaven {
            let matches = MavenProblemMatcher.match(
                command,
                source: IDEProblemsStore.mavenBuildSource,
                baseDirectory: projectRoot
            ) { [weak host] url in
                host?.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
            }
            host.noteBuildDiagnostics(matches.diagnostics, source: IDEProblemsStore.mavenBuildSource, texts: buildTexts(for: matches.diagnostics))
            host.problems.setBuildMessages(matches.problems)
            if matches.diagnostics.values.contains(where: { $0.contains { $0.severity == .error } })
                || matches.problems.contains(where: { $0.severity == .error }) {
                host.showProblems()
            }
            return
        }
        let matches = GradleProblemMatcher.match(
            command,
            source: IDEProblemsStore.gradleBuildSource,
            baseDirectory: projectRoot
        ) { [weak host] url in
            host?.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        host.noteBuildDiagnostics(matches.diagnostics, source: IDEProblemsStore.gradleBuildSource, texts: buildTexts(for: matches.diagnostics))
        host.problems.setBuildMessages(matches.problems)
        if matches.diagnostics.values.contains(where: { $0.contains { $0.severity == .error } })
            || matches.problems.contains(where: { $0.severity == .error }) {
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
