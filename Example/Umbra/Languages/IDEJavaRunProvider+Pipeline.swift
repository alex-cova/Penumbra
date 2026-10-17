import Foundation
import JavaIntelligence

/// Starting, stopping and rerunning programs in the Run tool window: validation, the before-launch
/// steps, the build, the JDK, and the process itself. Gradle runs and tests keep their own consoles.
extension IDEJavaRunProvider {
    // MARK: - Starting

    /// Runs a compiled class or a single file in a console of the Run tab. A rerun of a
    /// configuration that is still going stops it first, unless the configuration allows several
    /// instances.
    @discardableResult
    func startRunSession(_ configuration: JavaRunConfiguration, replacing explicit: IDERunSession? = nil) -> IDERunSession? {
        guard let host else { return nil }
        if let problem = validationProblems(for: configuration).first {
            host.reportRunProblem("“\(configuration.displayName)” can't run: \(problem.message)")
            host.openRunConfigurationDraft(configuration)
            return nil
        }
        host.runConfigurationStore.setLast(configuration, forProject: host.projectRootURL)
        host.refreshLastRunConfiguration()

        let session = host.runSessions.start(
            IDERunRequest(
                id: configuration.id,
                title: configuration.displayName,
                providerID: id,
                payload: configuration,
                allowsMultipleInstances: configuration.allowMultipleInstances,
                prepare: { [weak self] session in
                    await self?.runPipeline(session: session, configuration: configuration)
                }
            ),
            replacing: explicit
        )
        host.showRunTab()
        return session
    }

    private func runPipeline(session: IDERunSession, configuration: JavaRunConfiguration) async {
        var chain: Set<UUID> = [configuration.id]
        guard await prepareLaunch(configuration, session: session, chain: &chain) else { return }
        guard session.isActive else { return }

        guard let jdk = await resolveRunJDK(for: configuration) else {
            session.fail("No JDK found to run on. Choose one under Java ▸ Project JDK.")
            return
        }
        guard session.isActive else { return }

        let newProtocol = usesNewLaunchProtocol(configuration)
        if newProtocol, jdk.featureVersion < JavaLaunchCommand.minimumJavaForNewLaunchProtocol {
            session.fail(
                "Its main method (an instance main, no arguments, or a file without a class) needs Java "
                + "\(JavaLaunchCommand.minimumJavaForNewLaunchProtocol) or later, and this runs on Java \(jdk.featureVersion)."
            )
            return
        }

        var classpath: [URL]?
        if case .classpathMain(_, let sourceFile) = configuration.target {
            classpath = runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile))
            guard classpath != nil else {
                session.fail("It needs a synced Gradle project that contains \((sourceFile as NSString).lastPathComponent).")
                return
            }
        }
        var instrumentation: InstrumentationPlan?
        var extraVMArguments: [String] = []
        if configuration.instrumentation != .none {
            switch await makeInstrumentationPlan(for: configuration, jdk: jdk) {
            case .failure(let failure):
                session.fail(failure.message)
                return
            case .success(let plan):
                switch vmArguments(for: plan) {
                case .failure(let failure):
                    session.fail(failure.message)
                    return
                case .success(let arguments):
                    extraVMArguments = arguments
                    instrumentation = plan
                }
            }
        }
        guard let launch = JavaLaunchCommand.makeProcessLaunch(
            configuration: configuration,
            javaHome: jdk.home,
            runtimeClasspath: classpath,
            projectRoot: host?.projectRootURL,
            jdkFeatureVersion: jdk.featureVersion,
            usesNewLaunchProtocol: newProtocol,
            extraVMArguments: extraVMArguments
        ) else {
            session.fail("It can't be launched: check its target.")
            return
        }
        session.appendNote("Java \(jdk.featureVersion) · \(jdk.home.path)")
        if let instrumentation {
            switch instrumentation {
            case .coverage: session.appendNote("With coverage: the report is built when the program ends.")
            case .profile: session.appendNote("With Java Flight Recorder: the recording opens when the program ends.")
            }
            finishWhenSessionEnds(session, plan: instrumentation)
        }
        session.appendNote(launch.displayCommand + "\n")
        session.start(IDEProcessLaunch(launch))
        if case .profile(let plan)? = instrumentation {
            beginLiveProfile(plan, processID: { [weak session] in session?.processIdentifier })
        }
    }

    // MARK: - Before the program starts

    /// What reports on a launch in progress and learns that it was stopped: a run session, or the
    /// window's notes for a debug launch.
    struct LaunchProgress {
        var isActive: () -> Bool
        var note: (String) -> Void
        var fail: (String) -> Void
    }

    private func prepareLaunch(
        _ configuration: JavaRunConfiguration, session: IDERunSession, chain: inout Set<UUID>
    ) async -> Bool {
        let progress = LaunchProgress(
            isActive: { [weak session] in session?.isActive ?? false },
            note: { [weak session] in session?.appendNote($0) },
            fail: { [weak session] in session?.fail($0) }
        )
        return await prepareLaunch(configuration, progress: progress, chain: &chain)
    }

    /// The before-launch steps and the build that come ahead of the program. Reports why to
    /// `progress` when something fails, and returns `false` then (or when the launch was stopped).
    func prepareLaunch(
        _ configuration: JavaRunConfiguration, progress: LaunchProgress, chain: inout Set<UUID>, includesBuild: Bool = true
    ) async -> Bool {
        guard let host else { return false }
        for step in configuration.beforeLaunch {
            guard progress.isActive() else { return false }
            switch step {
            case .gradleTasks(let tasks):
                let names = tasks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                guard !names.isEmpty else { continue }
                progress.note("Before launch: gradle \(names.joined(separator: " "))")
                let outcome = await runGradleAndWait(names)
                guard progress.isActive() else { return false }
                if let failure = Self.failureDescription(of: outcome) {
                    host.showGradleConsole()
                    progress.fail("Before-launch step “gradle \(names.joined(separator: " "))” failed: \(failure)")
                    return false
                }
            case .mavenGoals(let goals):
                let names = goals.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                guard !names.isEmpty else { continue }
                progress.note("Before launch: mvn \(names.joined(separator: " "))")
                let outcome = await runMavenAndWait(names, module: nil)
                guard progress.isActive() else { return false }
                if let failure = Self.failureDescription(of: outcome) {
                    host.showMavenConsole()
                    progress.fail("Before-launch step “mvn \(names.joined(separator: " "))” failed: \(failure)")
                    return false
                }
            case .runConfiguration(let id):
                guard let other = host.runConfigurations.first(where: { $0.id == id }) else {
                    progress.fail("A configuration it runs first was deleted.")
                    return false
                }
                guard !chain.contains(other.id) else {
                    progress.fail("“\(other.displayName)” runs this configuration first, so they wait on each other.")
                    return false
                }
                progress.note("Before launch: run “\(other.displayName)”")
                chain.insert(other.id)
                let succeeded = await runToCompletion(other, waitingFor: progress)
                chain.remove(other.id)
                guard progress.isActive() else { return false }
                guard succeeded else {
                    progress.fail("“\(other.displayName)” did not finish successfully, so “\(configuration.displayName)” was not started.")
                    return false
                }
            }
        }

        if includesBuild, case .classpathMain(_, let sourceFile) = configuration.target {
            guard progress.isActive() else { return false }
            let fileName = (sourceFile as NSString).lastPathComponent
            guard runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile)) != nil else {
                let build = usesMaven ? "Maven" : "Gradle"
                progress.fail("It needs a synced \(build) project that contains \(fileName).")
                return false
            }
            if usesMaven {
                guard let compile = mavenCompile(forSourceFile: sourceFile) else { return true }
                let missing = !FileManager.default.fileExists(atPath: compile.output.path)
                if configuration.buildBeforeRun || missing {
                    progress.note("Building \(compile.selector) \(compile.goal) — output is in the Maven tab")
                    let outcome = await runMavenAndWait([compile.goal], module: compile.modulePath)
                    guard progress.isActive() else { return false }
                    if let failure = Self.failureDescription(of: outcome) {
                        host.showMavenConsole()
                        progress.fail("Build failed, so it was not started: \(failure). Errors are listed under Problems.")
                        return false
                    }
                }
            } else if let classpath = runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile)) {
                let missing = !JavaRunConfiguration.missingClassDirectories(in: classpath).isEmpty
                if configuration.buildBeforeRun || missing, let task = classesTaskPath(forSourceFile: sourceFile) {
                    progress.note("Building \(task) — output is in the Gradle tab")
                    let outcome = await runGradleAndWait([task])
                    guard progress.isActive() else { return false }
                    if let failure = Self.failureDescription(of: outcome) {
                        host.showGradleConsole()
                        progress.fail("Build failed, so it was not started: \(failure). Errors are listed under Problems.")
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Runs a configuration's before-launch steps ahead of a launch that has no console of its own
    /// (a Gradle task, tests), then `proceed`. A failing step is reported in the Gradle console and
    /// the launch does not happen; Stop cancels a wait. With no steps `proceed` runs at once.
    func runBeforeLaunchSteps(for configuration: JavaRunConfiguration, then proceed: @escaping @MainActor () -> Void) {
        guard !configuration.beforeLaunch.isEmpty else {
            proceed()
            return
        }
        let epoch = launchEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let progress = LaunchProgress(
                isActive: { [weak self] in self?.launchEpoch == epoch },
                note: { _ in },
                fail: { [weak self] in self?.host?.reportRunProblem("“\(configuration.displayName)”: \($0)") }
            )
            var chain: Set<UUID> = [configuration.id]
            guard await self.prepareLaunch(configuration, progress: progress, chain: &chain, includesBuild: false),
                  self.launchEpoch == epoch else { return }
            proceed()
        }
    }

    /// Runs another configuration to its end for a before-launch step. `true` when it succeeded.
    /// Stopping the waiting session stops it too.
    private func runToCompletion(_ configuration: JavaRunConfiguration, waitingFor parent: LaunchProgress) async -> Bool {
        switch configuration.target {
        case .classpathMain, .singleFile:
            guard let other = startRunSession(configuration) else { return false }
            while other.isActive {
                if !parent.isActive() { other.stop() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return other.state == .exited(0)
        case .gradleRun(let projectPath, let taskName):
            let outcome = await runGradleAndWait(
                [JavaLaunchCommand.gradleRunTask(for: projectPath, taskName: taskName ?? "run")],
                extra: JavaLaunchCommand.gradleRunArguments(configuration: configuration), runsApplication: true
            )
            return Self.failureDescription(of: outcome) == nil
        case .gradleTest(let taskPath, let filters, _):
            var extra = ["--no-configuration-cache"]
            for filter in filters { extra += ["--tests", filter] }
            return Self.failureDescription(of: await runGradleAndWait([taskPath], extra: extra)) == nil
        case .mavenGoals(let module, let goals):
            let extra = JavaCommandLine.split(configuration.programArguments)
            return Self.failureDescription(of: await runMavenAndWait(goals, module: module, extra: extra)) == nil
        case .mavenTest:
            guard let scope = configuration.mavenTestScope, let model = maven.model,
                  let command = MavenTestRunner.command(scope: scope, model: model) else { return false }
            return Self.failureDescription(of: await runMavenAndWait(command.goals, module: nil, extra: command.arguments)) == nil
        }
    }

    /// Runs Gradle tasks through the window's one Gradle runner and waits for the outcome.
    private func runGradleAndWait(
        _ tasks: [String], extra: [String] = [], runsApplication: Bool = false
    ) async -> IDEGradleRunOutcome {
        await withCheckedContinuation { continuation in
            gradle.runGradleTasks(tasks, extraArguments: extra, runsApplication: runsApplication) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Runs Maven goals and waits. `module` is a module path; `nil` is the reactor. The selector is
    /// resolved here so a test command that already carries `-pl` is not given it twice.
    private func runMavenAndWait(
        _ goals: [String], module: String?, extra: [String] = []
    ) async -> IDEMavenRunOutcome {
        let selector: String?
        if let module {
            guard let found = mavenSelector(modulePath: module) else {
                return .notStarted("There is no Maven module “\(module)”.")
            }
            selector = found
        } else {
            selector = nil
        }
        return await withCheckedContinuation { continuation in
            maven.runGoals(goals, module: selector, extraArguments: extra) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// `compile` or `test-compile` for the Maven module that contains `sourceFile`.
    private func mavenCompile(forSourceFile sourceFile: String) -> (modulePath: String, selector: String, goal: String, output: URL)? {
        guard let modules = maven.model?.modules else { return nil }
        let path = URL(fileURLWithPath: sourceFile).standardizedFileURL.path
        for module in modules {
            let inDirectory: (URL) -> Bool = { directory in
                let root = directory.standardizedFileURL.path
                return path == root || path.hasPrefix(root + "/")
            }
            if module.testSourceDirectories.contains(where: inDirectory) {
                return (module.path, module.selector, "test-compile", module.testOutputDirectory)
            }
            if module.sourceDirectories.contains(where: inDirectory) || module.generatedSourceDirectories.contains(where: inDirectory) {
                return (module.path, module.selector, "compile", module.outputDirectory)
            }
        }
        return nil
    }

    /// Why a Gradle run counts as failed, or `nil` when it succeeded.
    private static func failureDescription(of outcome: IDEGradleRunOutcome) -> String? {
        switch outcome {
        case .finished(let result): return result.exitCode == 0 ? nil : "Gradle exited with \(result.exitCode)"
        case .timedOut: return "Gradle timed out"
        case .cancelled: return "it was cancelled"
        case .notStarted(let reason), .failed(let reason): return reason
        }
    }

    /// Why a Maven goal counts as failed, or `nil` when it succeeded.
    private static func failureDescription(of outcome: IDEMavenRunOutcome) -> String? {
        switch outcome {
        case .finished(let result): return result.exitCode == 0 ? nil : "Maven exited with \(result.exitCode)"
        case .timedOut: return "Maven timed out"
        case .cancelled: return "it was cancelled"
        case .notStarted(let reason), .failed(let reason): return reason
        }
    }

    /// `:app:classes` for the source set that holds `sourceFile`; `nil` outside any.
    func classesTaskPath(forSourceFile sourceFile: String) -> String? {
        guard let match = gradle.model?.sourceSet(containing: URL(fileURLWithPath: sourceFile)) else { return nil }
        let name = match.sourceSet.name == "main" ? "classes" : "\(match.sourceSet.name)Classes"
        return match.subproject.path == ":" ? name : "\(match.subproject.path):\(name)"
    }

    /// Whether the program's `main` needs Java 21+'s launch protocol (an instance `main`, one without
    /// arguments, or a compact source file). Reads the source, from the editor if it is open.
    func usesNewLaunchProtocol(_ configuration: JavaRunConfiguration) -> Bool {
        let path: String
        let className: String?
        switch configuration.target {
        case .classpathMain(let name, let sourceFile): (path, className) = (sourceFile, name)
        case .singleFile(let file): (path, className) = (file, nil)
        case .gradleRun, .gradleTest, .mavenGoals, .mavenTest: return false
        }
        let url = URL(fileURLWithPath: path)
        guard let source = host?.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return false }
        let locations = JavaMainMethod.locations(in: source, fileName: url.lastPathComponent)
        if let className {
            return locations.first { $0.binaryClassName == className }?.usesNewLaunchProtocol ?? false
        }
        // `java File.java` starts the first class of the file; its main decides.
        return locations.first?.usesNewLaunchProtocol ?? false
    }
}
