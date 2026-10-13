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
    /// The bundle is `Penumbra_Umbra.bundle` (the package's name leads) and keeps the jars flat in
    /// `Contents/Resources` under Swift Build and under `Tools/JaCoCo/build` under the native build
    /// system. `Bundle.module` is not used: its accessor traps when the bundle is not where it looks.
    static func coverageToolchainDirectories(
        resources: URL? = Bundle.main.resourceURL,
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent(),
        sourceDirectory: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
            let level = gradle.model?.maxLanguageLevel
            if let message = JavaCoverageToolchain.unsupportedLanguageLevel(level ?? jdk.featureVersion) {
                return .failure(IDEInstrumentationFailure(message: message))
            }
            guard let run = try? Self.artifacts.allocate(kind: .coverage, projectHash: hash) else {
                return .failure(IDEInstrumentationFailure(message: "Could not create a folder for the coverage run."))
            }
            let execution = run.directory.appendingPathComponent("exec", isDirectory: true)
            try? FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
            // Reading the packages walks the source folders, which is not for the main actor.
            let model = gradle.model
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
            return .success(.profile(ProfilePlan(
                run: run, recordingDirectory: run.directory, label: configuration.displayName,
                jdkFeatureVersion: jdk.featureVersion, projectRoot: host?.projectRootURL, tasks: tasks
            )))
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
            let period = IDEPreferences.shared.javaProfileSamplePeriod
            guard let argument = JavaFlightRecorder.vmArgument(
                file: file.path, samplePeriodMilliseconds: period > 0 ? period : nil, jdkFeatureVersion: plan.jdkFeatureVersion
            ) else {
                return .failure(IDEInstrumentationFailure(message: "The recording path cannot hold a comma: \(file.path)."))
            }
            return .success([argument])
        }
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
                guard JavaFlightRecorder.isSafe(plan.recordingDirectory.path) else {
                    return .failure(IDEInstrumentationFailure(message: "The recording folder cannot hold a comma in its path."))
                }
                let period = IDEPreferences.shared.javaProfileSamplePeriod
                return .success(JavaProfileGradleScript.arguments(
                    scriptURL: script, recordingDirectory: plan.recordingDirectory,
                    samplePeriodMilliseconds: period > 0 ? period : nil, jdkFeatureVersion: plan.jdkFeatureVersion
                ))
            }
        } catch {
            return .failure(IDEInstrumentationFailure(message: "Could not write the Gradle script: \(error.localizedDescription)"))
        }
    }

    /// A Gradle task run measured by `plan` ended.
    func finishGradleRun(plan: InstrumentationPlan, report: IDEProjectTaskReport) {
        switch plan {
        case .coverage(let plan):
            var files = JavaCoverageGradleScript.execFiles(inOutput: report.output)
            if files.isEmpty {
                files = (try? FileManager.default.contentsOfDirectory(at: plan.executionDirectory, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "exec" } ?? []
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
            note(message)
            host.notifications.post("Profile of “\(plan.label)”", detail: message, category: .general, severity: .error, action: nil)
            return
        }
        Self.pruneArtifacts(kind: .profile, root: plan.projectRoot, keeping: plan.run.id)
        if IDEPreferences.shared.javaProfileOpensRecording {
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
