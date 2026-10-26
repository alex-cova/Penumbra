import Foundation
import JavaIntelligence

/// Run with Coverage and Profile: the same launch with the JaCoCo agent or Flight Recorder added,
/// and the step after it that reads what the JVM wrote.
///
/// A plan is made before the launch (it finds the jars and the run directory and fails with a
/// sentence when something is missing), the launch carries its VM argument or Gradle arguments,
/// and the plan's `finish` runs when the process or the Gradle task ends. Nothing here runs on a
/// keystroke: the report and the recording are read off the main actor.
extension IDEJavaRunProvider {
    /// Where coverage runs and recordings are kept, `Caches/com.umbra.editor` unless a test moved it.
    nonisolated(unsafe) static var artifactsRootOverride: URL?

    static var artifacts: JavaRunArtifacts {
        if let artifactsRootOverride { return JavaRunArtifacts(root: artifactsRootOverride) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return JavaRunArtifacts(root: caches.appendingPathComponent("com.umbra.editor", isDirectory: true))
    }

    /// Where the bundled JaCoCo jars may be, most specific first: the app's Resources (the Xcode
    /// project copies them flat), the SwiftPM resource bundle inside Resources (`Scripts/build-app.sh`)
    /// or next to the executable (`swift run`), and last the source tree (a build run in place).
    /// The bundle is `Umbra_Umbra.bundle` (the package's name leads; it was `Penumbra_Umbra.bundle`
    /// while Umbra was a target of the root package) and keeps the jars flat in
    /// `Contents/Resources` under Swift Build and under `Tools/JaCoCo/build` under the native build
    /// system. `Bundle.module` is not used: its accessor traps when the bundle is not where it looks.
    static func coverageToolchainDirectories(
        resources: URL? = Bundle.main.resourceURL,
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent(),
        sourceDirectory: URL = IDEDevelopmentPaths.sourceRoot
    ) -> [URL] {
        let relative = "Tools/JaCoCo/build"
        var directories: [URL] = []
        func addBundles(in parent: URL) {
            for name in ["Penumbra_Umbra.bundle", "Umbra_Umbra.bundle"] {
                let bundle = parent.appendingPathComponent(name, isDirectory: true)
                directories.append(bundle.appendingPathComponent("Contents/Resources", isDirectory: true))
                directories.append(bundle.appendingPathComponent("Contents/Resources/\(relative)", isDirectory: true))
                directories.append(bundle)
                directories.append(bundle.appendingPathComponent(relative, isDirectory: true))
            }
        }
        if let resources {
            directories.append(resources)
            addBundles(in: resources)
        }
        if let executableDirectory { addBundles(in: executableDirectory) }
        directories.append(sourceDirectory.appendingPathComponent(relative, isDirectory: true))
        return directories
    }

    static func coverageToolchain() throws -> JavaCoverageToolchain {
        try JavaCoverageToolchain.locate(in: coverageToolchainDirectories())
    }

    /// Removes old coverage runs and recordings of every project (newest few kept, size capped), once
    /// per launch, in the background: a project opening is when the cache is looked at.
    nonisolated(unsafe) private static var didPruneArtifacts = false

    static func pruneArtifactsOnce() {
        guard !didPruneArtifacts else { return }
        didPruneArtifacts = true
        let artifacts = Self.artifacts
        Task.detached(priority: .background) { artifacts.pruneAll() }
    }

    // MARK: - Plans

    struct CoveragePlan {
        var toolchain: JavaCoverageToolchain
        var run: JavaRunArtifacts.Run
        var executionDirectory: URL
        var scope: JavaCoverageScope
        var label: String
        var java: URL
        var projectRoot: URL?
        var tasks: [String]
    }

    struct ProfilePlan {
        var run: JavaRunArtifacts.Run
        var recordingDirectory: URL
        var label: String
        var jdkFeatureVersion: Int
        var projectRoot: URL?
        var tasks: [String]
        /// What the preferences said when the run started, which is what the recording holds.
        var options = JavaFlightRecorderOptions()
        var startedAt = Date()
        /// What the live view talks to the running JVM with.
        var jcmd: URL?
        var jps: URL?
    }

    enum InstrumentationPlan {
        case coverage(CoveragePlan)
        case profile(ProfilePlan)
    }

    /// The plan for `configuration` on `jdk`, or the sentence that says why it cannot run.
    func makeInstrumentationPlan(
        for configuration: JavaRunConfiguration, jdk: JDKInstallation, tasks: [String] = []
    ) async -> Result<InstrumentationPlan, IDEInstrumentationFailure> {
        let hash = JavaRunArtifacts.projectHash(for: host?.projectRootURL ?? URL(fileURLWithPath: "/"))
        switch configuration.instrumentation {
        case .none:
            return .failure(IDEInstrumentationFailure(message: "There is nothing to measure."))
        case .coverage:
            let toolchain: JavaCoverageToolchain
            do { toolchain = try Self.coverageToolchain() } catch {
                return .failure(IDEInstrumentationFailure(message: error.localizedDescription))
            }
            // The class files a run reports on are compiled for the project's own level; a JDK newer
            // than the pinned JaCoCo reads them fine, so what is checked is the level they were built for.
            let level = java.projectModel?.maxLanguageLevel
            if let message = JavaCoverageToolchain.unsupportedLanguageLevel(level ?? jdk.featureVersion) {
                return .failure(IDEInstrumentationFailure(message: message))
            }
            guard let run = try? Self.artifacts.allocate(kind: .coverage, projectHash: hash) else {
                return .failure(IDEInstrumentationFailure(message: "Could not create a folder for the coverage run."))
            }
            let execution = run.directory.appendingPathComponent("exec", isDirectory: true)
            try? FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
            // Reading the packages walks the source folders, which is not for the main actor.
            let model = java.projectModel
            let includeTests = IDEPreferences.shared.javaCoverageIncludesTests
            let scope: JavaCoverageScope = await Task.detached(priority: .userInitiated) {
                model.map { JavaCoverageScope.make(model: $0, includeTests: includeTests) } ?? JavaCoverageScope()
            }.value
            if IDEPreferences.shared.javaCoverageClearsOnRun, let host {
                host.coverage.clear()
                host.refreshCoverageBands()
            }
            return .success(.coverage(CoveragePlan(
                toolchain: toolchain, run: run, executionDirectory: execution, scope: scope,
                label: configuration.displayName, java: jdk.home.appendingPathComponent("bin/java"),
                projectRoot: host?.projectRootURL, tasks: tasks
            )))
        case .profile:
            if let message = JavaFlightRecorder.unsupportedReason(featureVersion: jdk.featureVersion) {
                return .failure(IDEInstrumentationFailure(message: message))
            }
            guard jdk.jfr != nil else {
                return .failure(IDEInstrumentationFailure(
                    message: "This JDK has no `jfr` tool, which reads recordings. Choose a full JDK under Java ▸ Project JDK."
                ))
            }
            guard let run = try? Self.artifacts.allocate(kind: .profile, projectHash: hash) else {
                return .failure(IDEInstrumentationFailure(message: "Could not create a folder for the recording."))
            }
            let options = IDEPreferences.shared.currentFlightRecorderOptions()
            if case .custom(let path) = options.template, !FileManager.default.fileExists(atPath: path) {
                return .failure(IDEInstrumentationFailure(
                    message: "The recording settings file is missing: \(path). Choose another under Settings ▸ Java ▸ Profiling."
                ))
            }
            let plan = ProfilePlan(
                run: run, recordingDirectory: run.directory, label: configuration.displayName,
                jdkFeatureVersion: jdk.featureVersion, projectRoot: host?.projectRootURL, tasks: tasks,
                options: options, startedAt: Date(), jcmd: jdk.jcmd, jps: jdk.jps
            )
            // A record of what the run was, so a list of recent profiles can say.
            try? JavaProfileRunInfo(
                label: plan.label, startedAt: plan.startedAt, jdkFeatureVersion: plan.jdkFeatureVersion,
                settings: options.summary, tasks: tasks
            ).write(to: run.directory)
            return .success(.profile(plan))
        }
    }

    // MARK: - A program Umbra starts itself

    /// The VM arguments an instrumented plain launch carries, and what to do when it ends.
    func vmArguments(for plan: InstrumentationPlan) -> Result<[String], IDEInstrumentationFailure> {
        switch plan {
        case .coverage(let plan):
            let execution = plan.executionDirectory.appendingPathComponent("main.exec")
            guard let argument = JavaCoverageCommand.agentArgument(
                agentJar: plan.toolchain.agentJar, execFile: execution, includes: plan.scope.includes
            ) else {
                return .failure(IDEInstrumentationFailure(
                    message: "The coverage agent cannot be given a path with a comma in it (\(plan.toolchain.agentJar.path))."
                ))
            }
            return .success([argument])
        case .profile(let plan):
            let file = plan.recordingDirectory.appendingPathComponent("recording.jfr")
            guard let arguments = JavaFlightRecorder.vmArguments(
                file: file.path, options: plan.options, jdkFeatureVersion: plan.jdkFeatureVersion
            ) else {
                return .failure(IDEInstrumentationFailure(
                    message: "The recording path or settings file cannot hold a comma: \(file.path)."
                ))
            }
            // The marker lets the live view find this JVM among the machine's.
            return .success(arguments + [JavaLiveCommands.runArgument(runID: plan.run.id)])
        }
    }

    /// Opens the profiler tab on a profiled run that has just started, with live charts.
    func beginLiveProfile(_ plan: ProfilePlan, processID: (@MainActor () -> Int32?)?) {
        host?.beginLiveProfile(
            title: plan.label, runID: plan.run.id, snapshotDirectory: plan.run.directory,
            jcmd: plan.jcmd, jps: plan.jps, processID: processID
        )
    }

    /// Hooks the end of a Run-tab session: a plain `main` measured by `plan` was started.
    func finishWhenSessionEnds(_ session: IDERunSession, plan: InstrumentationPlan) {
        session.onFinished = { [weak self] session in
            if case .failed = session.state { return }
            switch plan {
            case .coverage(let plan):
                let execution = plan.executionDirectory.appendingPathComponent("main.exec")
                self?.finishCoverage(plan, executionFiles: [execution], note: { session.appendNote($0) })
            case .profile(let plan):
                self?.finishProfile(plan, note: { session.appendNote($0) })
            }
        }
    }

    // MARK: - Gradle

    /// The Gradle arguments an instrumented task run adds, with the init script written next to the run.
    func gradleArguments(for plan: InstrumentationPlan) -> Result<[String], IDEInstrumentationFailure> {
        do {
            switch plan {
            case .coverage(let plan):
                let script = plan.run.directory.appendingPathComponent("coverage.init.gradle")
                try JavaCoverageGradleScript.source.write(to: script, atomically: true, encoding: .utf8)
                guard JavaCoverageCommand.isSafeForAgent(plan.toolchain.agentJar.path),
                      JavaCoverageCommand.isSafeForAgent(plan.executionDirectory.path) else {
                    return .failure(IDEInstrumentationFailure(message: "The coverage agent cannot be given a path with a comma in it."))
                }
                return .success(JavaCoverageGradleScript.arguments(
                    scriptURL: script, agentJar: plan.toolchain.agentJar,
                    executionDirectory: plan.executionDirectory, includes: plan.scope.includes
                ))
            case .profile(let plan):
                let script = plan.run.directory.appendingPathComponent("profile.init.gradle")
                try JavaProfileGradleScript.source.write(to: script, atomically: true, encoding: .utf8)
                guard JavaFlightRecorder.isSafe(plan.recordingDirectory.path), plan.options.isSafe else {
                    return .failure(IDEInstrumentationFailure(
                        message: "The recording folder and settings file cannot hold a comma in their paths."
                    ))
                }
                return .success(JavaProfileGradleScript.arguments(
                    scriptURL: script, recordingDirectory: plan.recordingDirectory,
                    options: plan.options, jdkFeatureVersion: plan.jdkFeatureVersion, runID: plan.run.id
                ))
            }
        } catch {
            return .failure(IDEInstrumentationFailure(message: "Could not write the Gradle script: \(error.localizedDescription)"))
        }
    }

    /// Maven test-run arguments for `plan`. A module that already runs JaCoCo's prepare-agent keeps
    /// that agent. A Surefire `argLine` that drops `@{argLine}` blocks an injected agent.
    func mavenTestArguments(for plan: InstrumentationPlan, scope: JavaTestRunScope) -> Result<[String], IDEInstrumentationFailure> {
        guard let model = maven.model else {
            return .failure(IDEInstrumentationFailure(message: "Read the Maven project before measuring tests."))
        }
        let taskPath = mavenTaskPath(scope)
        let modules = taskPath == "test" ? model.modules : model.modules.filter { $0.path == mavenModulePath(forTask: taskPath) }
        guard !modules.isEmpty else {
            return .failure(IDEInstrumentationFailure(message: "There is no Maven module for these tests."))
        }
        switch plan {
        case .coverage(let coverage):
            let exec = coverage.executionDirectory.appendingPathComponent("tests.exec")
            return injectedMavenArguments(modules, honorPrepareAgent: true) { module in
                MavenCoverageArguments.coverage(
                    module: module, agentJar: coverage.toolchain.agentJar, execFile: exec, includes: coverage.scope.includes
                )
            }
        case .profile(let profile):
            let file = profile.recordingDirectory.appendingPathComponent("recording.jfr")
            return injectedMavenArguments(modules, honorPrepareAgent: false) { module in
                MavenCoverageArguments.profiling(
                    module: module, recordingFile: file.path, jdkFeatureVersion: profile.jdkFeatureVersion
                )
            }
        }
    }

    /// `honorPrepareAgent` leaves a JaCoCo prepare-agent module alone (coverage). Profiling still
    /// asks for an agent on a module that does not already own the test JVM that way.
    private func injectedMavenArguments(
        _ modules: [MavenModule],
        honorPrepareAgent: Bool,
        make: (MavenModule) -> MavenCoverageArguments.Result
    ) -> Result<[String], IDEInstrumentationFailure> {
        let candidates = honorPrepareAgent ? modules.filter { !$0.usesJacocoPrepareAgent } : modules
        guard let module = candidates.first else { return .success([]) }
        let result = make(module)
        if let explanation = result.explanation {
            return .failure(IDEInstrumentationFailure(message: explanation))
        }
        for other in candidates.dropFirst() {
            if let explanation = make(other).explanation {
                return .failure(IDEInstrumentationFailure(message: explanation))
            }
        }
        return .success(result.arguments)
    }

    /// A Gradle or Maven task run measured by `plan` ended.
    func finishGradleRun(plan: InstrumentationPlan, report: IDEProjectTaskReport) {
        switch plan {
        case .coverage(let plan):
            var files = JavaCoverageGradleScript.execFiles(inOutput: report.output)
            if files.isEmpty {
                files = (try? FileManager.default.contentsOfDirectory(at: plan.executionDirectory, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "exec" } ?? []
            }
            if let modules = maven.model?.modules {
                for module in modules where module.usesJacocoPrepareAgent {
                    let exec = module.directory.appendingPathComponent("target/jacoco.exec")
                    if FileManager.default.fileExists(atPath: exec.path),
                       !files.contains(where: { $0.standardizedFileURL == exec.standardizedFileURL }) {
                        files.append(exec)
                    }
                }
            }
            finishCoverage(plan, executionFiles: files, note: { [weak self] in self?.host?.reportInstrumentationNote($0) })
        case .profile(let plan):
            finishProfile(plan, note: { [weak self] in self?.host?.reportInstrumentationNote($0) })
        }
    }

    // MARK: - After the run

    /// Reads `executionFiles` into a report and publishes it. Failures go to the Coverage tab and
    /// the notification bell, never silently.
    func finishCoverage(_ plan: CoveragePlan, executionFiles: [URL], note: @escaping @MainActor (String) -> Void) {
        guard let host else { return }
        host.coverage.beginReport(message: "Building the coverage report for “\(plan.label)”…")
        host.showCoverageTabIfWanted()
        let sourceRoots = plan.scope.sourceDirectories
        let prefixes = IDEPreferences.shared.javaCoveragePackagePrefixes
        let runDirectory = plan.run.directory
        let startedAt = Date()
        Task { @MainActor [weak self] in
            do {
                let report = try await JavaCoverageReportRunner.report(
                    java: plan.java, toolchain: plan.toolchain, executionFiles: executionFiles,
                    classDirectories: plan.scope.classDirectories,
                    xmlOutput: runDirectory.appendingPathComponent("report.xml"),
                    name: plan.label,
                    sourceLookup: { relative in
                        for root in sourceRoots {
                            let candidate = root.appendingPathComponent(relative)
                            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
                        }
                        return nil
                    }
                )
                guard let self, let host = self.host else { return }
                let shown = report.filtered(toPackagePrefixes: prefixes)
                var stale = Set<String>()
                // A buffer with unsaved edits is not the text that was compiled and run.
                for file in shown.sourceFiles {
                    guard let url = file.url, let buffer = host.openBufferText(for: url) else { continue }
                    if (try? String(contentsOf: url, encoding: .utf8)) != buffer { stale.insert(url.standardizedFileURL.path) }
                }
                host.coverage.publish(IDECoverageSnapshot(
                    report: shown, runID: plan.run.id, label: plan.label, date: startedAt, tasks: plan.tasks,
                    runDirectory: runDirectory, executionFiles: executionFiles,
                    classDirectories: plan.scope.classDirectories, sourceDirectories: sourceRoots,
                    java: plan.java, cliJar: plan.toolchain.cliJar
                ), staleFiles: stale)
                host.refreshCoverageBands()
                host.showCoverageTabIfWanted()
                let percent = shown.totals.lines.percent.map { "\($0)% of lines" } ?? "no executable lines"
                host.notifications.post(
                    "Coverage for “\(plan.label)”", detail: percent, category: .general, severity: .success, action: .showCoverage
                )
                Self.pruneArtifacts(kind: .coverage, root: plan.projectRoot, keeping: plan.run.id)
            } catch {
                guard let self, let host = self.host else { return }
                let message = error.localizedDescription
                host.coverage.fail(message)
                note(message)
                host.showCoverageTabIfWanted()
                host.notifications.post(
                    "Coverage failed", detail: message, category: .general, severity: .error, action: .showCoverage
                )
            }
        }
    }

    /// Opens the recording a run wrote, or says that none was written.
    func finishProfile(_ plan: ProfilePlan, note: @escaping @MainActor (String) -> Void) {
        guard let host else { return }
        let recordings = JavaProfileGradleScript.recordings(in: plan.recordingDirectory)
        guard !recordings.isEmpty else {
            let message = "No recording was written. A program that is killed (SIGKILL) or that exits through Runtime.halt leaves none; Stop sends SIGTERM first."
            host.endLiveProfile(runID: plan.run.id, failure: message)
            note(message)
            host.notifications.post("Profile of “\(plan.label)”", detail: message, category: .general, severity: .error, action: nil)
            return
        }
        // Complete the record: when it ended and how much was written.
        let bytes = recordings.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        try? JavaProfileRunInfo(
            label: plan.label, startedAt: plan.startedAt, jdkFeatureVersion: plan.jdkFeatureVersion,
            settings: plan.options.summary, tasks: plan.tasks, finishedAt: Date(),
            recordingCount: recordings.count, recordingBytes: bytes
        ).write(to: plan.run.directory)
        Self.pruneArtifacts(kind: .profile, root: plan.projectRoot, keeping: plan.run.id)
        // A tab already waiting on this run (the live charts) reads the recording whatever the setting.
        if IDEPreferences.shared.javaProfileOpensRecording || host.hasLiveProfile(runID: plan.run.id) {
            host.openProfile(
                recordings: recordings, title: "Profile: \(plan.label)", runID: plan.run.id,
                project: host.projectRootURL
            )
        } else {
            host.notifications.post(
                "Profile of “\(plan.label)” is ready", detail: recordings.first?.lastPathComponent,
                category: .general, severity: .success, action: .openFile(recordings[0].path)
            )
        }
    }

    private static func pruneArtifacts(kind: JavaRunArtifacts.Kind, root: URL?, keeping runID: String) {
        guard let root else { return }
        let hash = JavaRunArtifacts.projectHash(for: root)
        artifacts.prune(kind: kind, projectHash: hash, protecting: [runID])
    }
}

/// Why an instrumented run could not start: one sentence for the user.
struct IDEInstrumentationFailure: Error, Equatable {
    var message: String
}
