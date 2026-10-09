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
        guard let launch = JavaLaunchCommand.makeProcessLaunch(
            configuration: configuration,
            javaHome: jdk.home,
            runtimeClasspath: classpath,
            projectRoot: host?.projectRootURL,
            jdkFeatureVersion: jdk.featureVersion,
            usesNewLaunchProtocol: newProtocol
        ) else {
            session.fail("It can't be launched: check its target.")
            return
        }
        session.appendNote("Java \(jdk.featureVersion) · \(jdk.home.path)")
        session.appendNote(launch.displayCommand + "\n")
        session.start(IDEProcessLaunch(launch))
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
            guard let classpath = runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile)) else {
                progress.fail("It needs a synced Gradle project that contains \((sourceFile as NSString).lastPathComponent).")
                return false
            }
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

    /// Why a Gradle run counts as failed, or `nil` when it succeeded.
    private static func failureDescription(of outcome: IDEGradleRunOutcome) -> String? {
        switch outcome {
        case .finished(let result): return result.exitCode == 0 ? nil : "Gradle exited with \(result.exitCode)"
        case .timedOut: return "Gradle timed out"
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
        case .gradleRun, .gradleTest: return false
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
