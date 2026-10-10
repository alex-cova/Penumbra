import Foundation
import JavaIntelligence
import Observation
import SwiftUI

/// What the Gradle project system tells the code that indexes the project's Java when the model
/// changes. `IDEJavaSupport` implements it; the Gradle system holds it weakly. It is the one place the
/// two know each other: Gradle produces the module and dependency model, Java indexes it.
@MainActor
protocol IDEGradleModelConsumer: AnyObject {
    /// The model was set or cleared (a new folder, a sync, a failed sync).
    func gradleModelDidChange(_ model: JavaGradleProjectModel?)
    /// A sync (or the cached model) produced `model`: index its source sets and dependencies. Called
    /// before the sync state becomes `.synced`.
    func gradleModelApplied(_ model: JavaGradleProjectModel, previous: JavaGradleProjectModel?, logToConsole: Bool) async
    /// A sync failed or the folder changed: drop what was derived from the model.
    func gradleModelRemoved()
    /// A task run ended with exit code 0; annotation processors may have written generated sources.
    func gradleTasksSucceeded()
}

/// How a Gradle task run ended, for a caller that awaits it. Every path of
/// `IDEGradleProjectSystem.runGradleTasks` reports exactly one.
enum IDEGradleRunOutcome: Sendable {
    case finished(GradleCommandResult)
    case timedOut(partial: GradleCommandResult)
    case cancelled(partial: GradleCommandResult?)
    /// Nothing ran: not a Gradle project, busy, or the user declined to trust it.
    case notStarted(String)
    case failed(String)
}

extension IDEBottomPanelTab {
    /// The Gradle sync and task console.
    static let gradle = IDEBottomPanelTab("gradle")
}

extension IDEProjectConsoleLog {
    mutating func appendProcessLine(_ line: GradleOutputLine) {
        appendProcessLine(IDEProjectOutputLine(
            stream: line.stream == .stderr ? .stderr : .stdout,
            text: line.text
        ))
    }
}

/// Gradle as a project system: detects a Gradle folder, syncs its module and dependency model through
/// `GradleCommandRunner` (after the trust prompt), keeps the Gradle console, runs tasks, watches the
/// build files and shows the Gradle tool window. Split out of `IDEJavaSupport`, which indexes the
/// model it produces (`IDEGradleModelConsumer`).
///
/// A sync is silent when it only refreshes a cached model (nothing is announced, the console says so),
/// and every other sync tells the host how it ended (`environment.syncFinished`). A reload of the same
/// root cancels the previous task without changing the generation; a new root bumps it, so an
/// in-flight sync for the previous folder cannot publish over the new one.
@MainActor
@Observable
final class IDEGradleProjectSystem: IDEProjectSystem {
    let id = "gradle"
    let displayName = "Gradle"
    var consoleTab: IDEBottomPanelTab? { .gradle }
    @ObservationIgnored var environment = IDEProjectEnvironment()

    private(set) var syncState: IDEProjectSyncState = .notDetected
    /// Last successful project model. Used to pick `:app:run` versus `run` for the play button.
    private(set) var model: JavaGradleProjectModel? {
        didSet {
            if oldValue == nil, model == nil { return }
            onModelChanged?(model)
            consumer?.gradleModelDidChange(model)
        }
    }
    /// Called whenever a sync sets or clears ``model`` (the Go to File index labels files with their module).
    @ObservationIgnored var onModelChanged: (@MainActor (JavaGradleProjectModel?) -> Void)?
    /// Live output of the most recent (or in-progress) sync or task run -- backs the "Gradle" console
    /// tab in the bottom panel. Reset at the start of every sync.
    private(set) var console = IDEProjectConsoleLog()
    /// Set when a watched Gradle build file changes outside of a sync. Bursts collapse to one banner;
    /// cleared by Reload or Dismiss.
    private(set) var hasConfigurationChanges = false
    /// True while a user-triggered Gradle task (from the sidebar or elsewhere) is running.
    private(set) var isRunningTasks = false
    private(set) var runningTasks: [String] = []
    /// The cached model is being applied instead of the whole-tree index: the project is trusted and
    /// auto-sync is on, so the sources come from its modules.
    @ObservationIgnored private(set) var isLoadingCachedModel = false

    @ObservationIgnored weak var consumer: (any IDEGradleModelConsumer)?

    private let jdk: IDEJDKSelection
    private let status: IDEProjectStatus
    @ObservationIgnored private let trustStore: GradleTrustStore
    @ObservationIgnored private let modelCache: GradleProjectModelCache
    @ObservationIgnored private let runner: GradleCommandRunner
    @ObservationIgnored private let extractor: GradleProjectModelExtractor
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var projectRootURL: URL?
    /// Bumped on every `projectDidChange` so an in-flight sync for the previous folder cannot publish
    /// over the new one. Distinct from `Task.isCancelled`: a reload of the *same* root cancels the
    /// previous task without changing the generation.
    @ObservationIgnored private var projectGeneration = 0
    /// Home of the JDK the last Gradle sync launched on, so a JDK change only re-syncs when Gradle
    /// would launch on a different one.
    @ObservationIgnored private var javaHomePath: String?
    /// True from the moment a sync task is scheduled until it finishes, including the trust prompt.
    /// Build-file events in that window are dropped so the save that triggered a reload doesn't
    /// immediately raise the banner again.
    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private var buildFileWatcher: FSEventsFileSystemWatcher?
    @ObservationIgnored private var buildFileWatchTask: Task<Void, Never>?
    @ObservationIgnored private var dependencyGraphCache: [String: (fingerprint: GradleBuildFingerprint, graph: GradleDependencyGraph)] = [:]

    /// The trust store is the app's shared one by default, so every window sees the same Gradle trust
    /// decisions.
    init(
        jdk: IDEJDKSelection,
        status: IDEProjectStatus,
        trustStore: GradleTrustStore = IDESharedServices.shared.gradleTrust,
        modelCacheRoot: URL = IDEGradleProjectSystem.defaultModelCacheRoot
    ) {
        self.jdk = jdk
        self.status = status
        self.trustStore = trustStore
        modelCache = GradleProjectModelCache(cacheRoot: modelCacheRoot)
        let runner = GradleCommandRunner(trustStore: trustStore)
        self.runner = runner
        extractor = GradleProjectModelExtractor(runner: runner)
    }

    /// `~/Library/Application Support/com.umbra.editor/gradle-trust.json`, alongside
    /// `IDESessionStore`'s `session.json`. Deliberately not under `JavaIndexPaths.default().root`
    /// (Caches, versioned by shard format) -- trust decisions shouldn't reset on a format bump.
    static var defaultTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("gradle-trust.json")
    }

    static var defaultModelCacheRoot: URL {
        GradleProjectModelCache.defaultCacheRoot(bundleIdentifier: "com.umbra.editor")
    }

    // MARK: - State

    var isActive: Bool {
        if case .notDetected = syncState { return false }
        return projectRootURL != nil
    }

    var isBusy: Bool { syncState.isSyncing || isRunningTasks }

    /// The windows's Gradle project root, for callers that build a request against it.
    var rootURL: URL? { projectRootURL }

    var isTrusted: Bool {
        projectRootURL.map { trustStore.isTrusted($0) } ?? false
    }

    var tasks: [IDEProjectTask] {
        (model?.subprojects ?? []).flatMap { subproject in
            subproject.tasks.map {
                IDEProjectTask(path: $0.path, name: $0.name, module: subproject.path, group: $0.group, summary: $0.description)
            }
        }
    }

    /// Standardized paths of every Gradle source directory from the last successful sync. Empty
    /// before a sync; the Explorer also recognizes the `src/<set>/java` convention on its own.
    var sourceRootPaths: Set<String> {
        guard let model else { return [] }
        var paths: Set<String> = []
        for subproject in model.subprojects {
            for sourceSet in subproject.sourceSets {
                for directory in sourceSet.sourceDirs {
                    paths.insert(directory.standardizedFileURL.path)
                }
            }
        }
        return paths
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == projectGeneration && !Task.isCancelled
    }

    // MARK: - Console

    /// Adds a line to the console, for messages from the host (why a launch did not start) and the
    /// indexing that follows a sync.
    func appendConsoleNote(_ text: String) {
        console.appendNote(text)
    }

    /// Adds several lines as one change, so a view redraws once.
    func appendConsoleNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        var console = console
        for note in notes { console.appendNote(note) }
        self.console = console
    }

    // MARK: - Lifecycle

    /// Re-targets the Gradle project at a new folder (or clears it when `url` is `nil`, e.g. the user
    /// closes the folder). Safe to call repeatedly; a new call cancels any sync still in flight for
    /// the previous root. If `url` looks like a Gradle project, also kicks off a sync (gated by trust
    /// and `javaGradleAutoSync`) that -- once it succeeds -- hands the model to the consumer, which
    /// replaces the whole-tree index with per-module sources and resolved dependency JARs.
    func projectDidChange(root url: URL?) {
        projectGeneration += 1
        let generation = projectGeneration
        javaHomePath = nil
        syncTask?.cancel()
        runTask?.cancel()
        stopBuildFileWatcher()
        syncInFlight = false
        hasConfigurationChanges = false
        projectRootURL = url
        dependencyGraphCache.removeAll()
        model = nil
        console = IDEProjectConsoleLog()
        isLoadingCachedModel = false

        guard let url, GradleProjectModelExtractor.isGradleProject(url) else {
            syncState = .notDetected
            return
        }

        syncState = .awaitingTrust
        startBuildFileWatcher(root: url)

        let canUseCache = IDEPreferences.shared.javaGradleAutoSync && trustStore.isTrusted(url)
        if canUseCache, let cachedModel = modelCache.loadIfValid(projectRoot: url) {
            isLoadingCachedModel = true
            syncGradleProject(
                url,
                forcePrompt: false,
                generation: generation,
                silent: true,
                invalidateCacheBeforeSync: false,
                bootstrapModel: cachedModel
            )
            return
        }

        if IDEPreferences.shared.javaGradleAutoSync {
            syncGradleProject(
                url,
                forcePrompt: false,
                generation: generation,
                silent: false,
                invalidateCacheBeforeSync: false,
                bootstrapModel: nil
            )
        }
    }

    /// The window is closing: stop everything this project started, so a closed project leaves no
    /// sync, run or build-file watcher behind. Work still in flight sees a newer generation and does
    /// not publish.
    func stop() {
        projectGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        runTask?.cancel()
        runTask = nil
        isRunningTasks = false
        runningTasks = []
        syncInFlight = false
        stopBuildFileWatcher()
        projectRootURL = nil
        model = nil
    }

    func dismissConfigurationChanges() {
        hasConfigurationChanges = false
    }

    // MARK: - Sync

    /// Re-runs Gradle extraction for the current project root -- backs "Java: Reload Gradle
    /// Project". Re-asks for trust even if the user previously declined.
    func reload() {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else { return }
        dependencyGraphCache.removeAll()
        modelCache.invalidate(projectRoot: url)
        syncGradleProject(
            url,
            forcePrompt: true,
            generation: projectGeneration,
            silent: false,
            invalidateCacheBeforeSync: false,
            bootstrapModel: nil
        )
    }

    /// Cancels an in-progress sync -- backs the Gradle console tab's Cancel button. A no-op unless
    /// a sync is actually running: the task's own `catch` never sees a plain cancellation (it
    /// returns early once `isCurrent` sees `Task.isCancelled`), so the state transition has to
    /// happen here instead.
    func cancelSync() {
        guard case .syncing = syncState else { return }
        syncTask?.cancel()
        syncTask = nil
        syncInFlight = false
        status.clear(Self.resolvingMessage)
        syncState = .failed(summary: "Gradle sync was cancelled")
        console.appendNote("Sync cancelled")
        console.markFinished()
        environment.syncFinished(.cancelled)
    }

    /// The user chose another JDK (or removed the one in use): re-sync a trusted project when Gradle
    /// would now launch on a different JDK. A sync never asks for trust again.
    func jdkSelectionChanged() async {
        let generation = projectGeneration
        guard let url = projectRootURL, isActive, IDEPreferences.shared.javaGradleAutoSync,
              trustStore.isTrusted(url), !syncState.isSyncing, !isRunningTasks else { return }
        let gradleHome = await jdk.resolveForGradle()?.installation.home.resolvingSymlinksInPath().path
        guard isCurrent(generation), gradleHome != javaHomePath else { return }
        syncGradleProject(
            url,
            forcePrompt: false,
            generation: generation,
            silent: false,
            invalidateCacheBeforeSync: true,
            bootstrapModel: nil
        )
    }

    private static let resolvingMessage = "Resolving Gradle project…"

    private func syncGradleProject(
        _ url: URL,
        forcePrompt: Bool,
        generation: Int,
        silent: Bool,
        invalidateCacheBeforeSync: Bool,
        bootstrapModel: JavaGradleProjectModel?
    ) {
        syncTask?.cancel()
        if !silent {
            hasConfigurationChanges = false
        }
        syncInFlight = true
        syncTask = Task { [trustStore, extractor, modelCache] in
            defer {
                if generation == projectGeneration && !Task.isCancelled {
                    syncInFlight = false
                }
            }
            if invalidateCacheBeforeSync {
                modelCache.invalidate(projectRoot: url)
            }
            if !trustStore.isTrusted(url) {
                let previouslyDeclined = trustStore.decision(for: url) == false
                if previouslyDeclined && !forcePrompt {
                    guard isCurrent(generation) else { return }
                    syncState = .untrusted
                    return
                }
                guard let requestTrust = environment.requestTrust else {
                    guard isCurrent(generation) else { return }
                    syncState = .awaitingTrust
                    return
                }
                let trusted = await requestTrust(url)
                trustStore.setTrusted(trusted, for: url)
                guard isCurrent(generation) else { return }
                guard trusted else {
                    syncState = .untrusted
                    return
                }
            }
            guard isCurrent(generation) else { return }

            if let bootstrapModel {
                model = bootstrapModel
                syncState = .synced(
                    modules: bootstrapModel.subprojects.count,
                    dependencies: bootstrapModel.classpathJars.count
                )
                await consumer?.gradleModelApplied(bootstrapModel, previous: nil, logToConsole: false)
                guard isCurrent(generation) else { return }
            }

            let previousModel = model
            if !silent {
                syncState = .syncing
                status.set(Self.resolvingMessage)
            }
            // Gradle itself (9.x) needs a modern JDK to launch, independent of the project's
            // source level, so with no explicit choice this is the newest installation rather than
            // the one selected for `maxLanguageLevel`.
            let javaHome = await jdk.resolveForGradle()?.installation.home
            guard isCurrent(generation) else { return }
            javaHomePath = javaHome?.resolvingSymlinksInPath().path

            if silent {
                console.appendNote("Refreshing Gradle project model in the background…")
            } else {
                console.reset()
            }
            console.appendNote("Project: \(url.path)")
            console.appendNote("Command: \(Self.projectModelCommandLine(project: url, javaHome: javaHome))")
            if let javaHome {
                console.appendNote("JAVA_HOME: \(javaHome.path)")
            }

            do {
                let timeout = Duration.seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds))
                let startedAt = Date()
                let (model, result) = try await extractor.extract(
                    projectDirectory: url,
                    javaHome: javaHome,
                    timeout: timeout,
                    output: { line in
                        Task { @MainActor in
                            guard generation == self.projectGeneration else { return }
                            self.console.appendProcessLine(line)
                        }
                    }
                )
                guard isCurrent(generation) else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                console.appendNote(String(format: "Gradle exited %d in %.1fs", result.exitCode, elapsed))
                if !model.unresolved.isEmpty {
                    console.appendNote("Unresolved dependencies:")
                    for dependency in model.unresolved {
                        console.appendNote("  \(dependency)")
                    }
                }

                modelCache.store(projectRoot: url, model: model)

                if silent, let previousModel, Self.modelsAreEqual(previousModel, model) {
                    console.appendNote("Background refresh: project model unchanged")
                    console.markFinished()
                    return
                }

                self.model = model
                await consumer?.gradleModelApplied(model, previous: previousModel, logToConsole: !silent)
                guard isCurrent(generation) else { return }

                syncState = .synced(modules: model.subprojects.count, dependencies: model.classpathJars.count)
                if silent {
                    console.appendNote("Background refresh finished")
                } else {
                    console.appendNote("Sync finished")
                }
                console.markFinished()
                if !silent {
                    environment.syncFinished(.synced(modules: model.subprojects.count, dependencies: model.classpathJars.count))
                }
            } catch {
                guard isCurrent(generation) else { return }
                if silent {
                    console.appendNote("Background refresh failed: \(Self.summarize(error))")
                    console.markFinished()
                    return
                }
                consumer?.gradleModelRemoved()
                model = nil
                // Only clear the message this task set. JDK indexing and the whole-tree fallback
                // publish their own status and must not be blanked by a Gradle failure.
                status.clear(Self.resolvingMessage)
                let summary = Self.summarize(error)
                syncState = .failed(summary: summary)
                console.appendNote(summary)
                console.markFinished()
                environment.syncFailed()
                environment.syncFinished(.failed(summary: summary))
            }
        }
    }

    private static func modelsAreEqual(_ lhs: JavaGradleProjectModel, _ rhs: JavaGradleProjectModel) -> Bool {
        guard let left = try? JSONEncoder().encode(lhs),
              let right = try? JSONEncoder().encode(rhs) else {
            return false
        }
        return left == right
    }

    private static func projectModelCommandLine(project: URL, javaHome: URL?) -> String {
        let java = javaHome.map { "JAVA_HOME=\($0.path) " } ?? ""
        return "\(java)cd \(project.path) && gradle --console=plain --init-script umbra-project-model.init.gradle --no-configuration-cache -PumbraModelOutput=model.json :umbraProjectModel"
    }

    private static func summarizeTaskRun(_ error: Error) -> String {
        switch error {
        case GradleCommandError.timedOut:
            "Gradle task timed out"
        case GradleCommandError.cancelled:
            "Gradle task was cancelled"
        default:
            summarize(error)
        }
    }

    private static func summarize(_ error: Error) -> String {
        switch error {
        case let GradleProjectModelExtractionError.syncFailed(result):
            "Gradle exited \(result.exitCode)"
        case GradleProjectModelExtractionError.missingOutput:
            "Gradle produced no model"
        case GradleProjectModelExtractionError.decodingFailed:
            "Couldn't read Gradle's model"
        case GradleCommandError.untrusted:
            "Project isn't trusted"
        case GradleCommandError.executableNotFound:
            "No gradle found (checked ./gradlew and PATH)"
        case GradleCommandError.timedOut:
            "Gradle sync timed out"
        case GradleCommandError.cancelled:
            "Gradle sync was cancelled"
        default:
            String(describing: error)
        }
    }

    // MARK: - Tasks

    func runTasks(_ tasks: [String]) {
        runGradleTasks(tasks)
    }

    /// `build` for the whole project, every subproject included, so its compiler errors land in Problems.
    func build() {
        runGradleTasks(["build"])
    }

    /// Long enough to mean "until stopped" without overflowing the runner's `Task.sleep`.
    private static let applicationRunTimeout = Duration.seconds(365 * 24 * 60 * 60)

    /// Runs one or more Gradle tasks for the current project, streaming output into the Gradle
    /// console tab. No-op while a sync or another task run is already in progress. Asks for trust
    /// first when the project has not been trusted yet. `runsApplication` is for tasks that start the
    /// program (`run`, `bootRun`): a server runs until it is stopped, so the sync timeout doesn't apply.
    ///
    /// `completion` is called exactly once, whichever way the call ends, so a caller can await it
    /// (the agent does): refused to start, not trusted, finished, timed out, cancelled or failed.
    func runGradleTasks(
        _ taskPaths: [String],
        extraArguments: [String] = [],
        runsApplication: Bool = false,
        timeout customTimeout: Duration? = nil,
        completion: (@MainActor (IDEGradleRunOutcome) -> Void)? = nil
    ) {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else {
            completion?(.notStarted("This project is not a Gradle project."))
            return
        }
        guard !taskPaths.isEmpty else {
            completion?(.notStarted("No Gradle task was given."))
            return
        }
        guard !syncState.isSyncing, !isRunningTasks else {
            completion?(.notStarted("Gradle is already busy with a sync or another task in this window. Try again when it finishes."))
            return
        }

        runTask?.cancel()
        let arguments = extraArguments.isEmpty ? ["--no-configuration-cache"] : extraArguments
        runTask = Task { [runner] in
            isRunningTasks = true
            runningTasks = taskPaths
            console.reset()
            console.appendNote("Project: \(url.path)")
            console.appendNote("Tasks: \(taskPaths.joined(separator: " "))")

            let javaHome = await jdk.resolveForGradle()?.installation.home
            if let javaHome {
                console.appendNote("JAVA_HOME: \(javaHome.path)")
            }

            defer {
                isRunningTasks = false
                runningTasks = []
            }

            // Build scripts run arbitrary code, so an untrusted project is asked first, as a sync
            // would. On a "no" nothing runs, and it is asked again next time.
            if !trustStore.isTrusted(url) {
                guard let requestTrust = environment.requestTrust, await requestTrust(url) else {
                    console.appendNote("Not run: the project is not trusted")
                    console.markFinished()
                    completion?(.notStarted("The project is not trusted, so its Gradle build scripts were not run."))
                    return
                }
                trustStore.setTrusted(true, for: url)
            }

            do {
                let timeout = customTimeout ?? (runsApplication
                    ? Self.applicationRunTimeout
                    : Duration.seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds)))
                let startedAt = Date()
                let result = try await runner.run(
                    projectDirectory: url,
                    tasks: taskPaths,
                    arguments: arguments,
                    javaHome: javaHome,
                    timeout: timeout,
                    output: { line in
                        Task { @MainActor in
                            guard !Task.isCancelled else { return }
                            self.console.appendProcessLine(line)
                        }
                    }
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                console.appendNote(String(format: "Gradle exited %d in %.1fs", result.exitCode, elapsed))
                console.markFinished()
                if result.exitCode == 0 { consumer?.gradleTasksSucceeded() }
                tasksFinished(taskPaths, url, result)
                completion?(.finished(result))
            } catch is CancellationError {
                console.appendNote("Task run cancelled")
                console.markFinished()
                completion?(.cancelled(partial: nil))
            } catch {
                console.appendNote(Self.summarizeTaskRun(error))
                console.markFinished()
                switch error {
                case GradleCommandError.timedOut(let partial):
                    tasksFinished(taskPaths, url, partial)
                    completion?(.timedOut(partial: partial))
                case GradleCommandError.cancelled(let partial):
                    tasksFinished(taskPaths, url, partial)
                    completion?(.cancelled(partial: partial))
                default:
                    completion?(.failed(Self.summarizeTaskRun(error)))
                }
                if case GradleCommandError.untrusted = error {
                    syncState = .untrusted
                }
            }
        }
    }

    private func tasksFinished(_ tasks: [String], _ root: URL, _ result: GradleCommandResult) {
        environment.tasksFinished(IDEProjectTaskReport(
            tasks: tasks, root: root, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
        ))
    }

    func cancelTasks() {
        guard isRunningTasks else { return }
        runTask?.cancel()
        runTask = nil
        isRunningTasks = false
        runningTasks = []
        console.appendNote("Task run cancelled")
        console.markFinished()
    }

    // MARK: - Dependency diagrams

    /// The module graph of the synced model; no Gradle run.
    var moduleDependencyGraph: GradleDependencyGraph? {
        model.map { GradleDependencyGraph.moduleGraph(from: $0) }
    }

    func invalidateDependencyGraphs() {
        dependencyGraphCache.removeAll()
    }

    /// The resolved libraries of one project's configuration, from a Gradle run unless the build files
    /// are unchanged since the last one. Shares the busy flag and the trust prompt with the other Gradle actions.
    func resolveDependencyGraph(projectPath: String, configuration: String) async -> Result<GradleDependencyGraph, IDEDiagramLoadFailure> {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else {
            return .failure(.message("This project is not a Gradle project."))
        }
        let fingerprint = GradleBuildFingerprintCollector.collect(projectRoot: url)
        let cacheKey = projectPath + "|" + configuration
        if let cached = dependencyGraphCache[cacheKey], cached.fingerprint == fingerprint {
            return .success(cached.graph)
        }
        guard !isBusy else {
            return .failure(.message("Gradle is busy with a sync or another task in this window. Reload the diagram when it finishes."))
        }
        if !trustStore.isTrusted(url) {
            guard let requestTrust = environment.requestTrust, await requestTrust(url) else {
                return .failure(.message("The project is not trusted, so its Gradle build scripts were not run."))
            }
            trustStore.setTrusted(true, for: url)
        }

        let taskPath = projectPath == ":" || projectPath.isEmpty ? ":umbraDependencyGraph" : projectPath + ":umbraDependencyGraph"
        isRunningTasks = true
        runningTasks = [taskPath]
        defer {
            isRunningTasks = false
            runningTasks = []
        }
        console.reset()
        console.appendNote("Project: \(url.path)")
        console.appendNote("Dependency diagram: \(projectPath) (\(configuration))")
        let javaHome = await jdk.resolveForGradle()?.installation.home
        do {
            let graph = try await GradleDependencyGraphExtractor(runner: runner).extract(
                projectDirectory: url,
                projectPath: projectPath,
                configuration: configuration,
                javaHome: javaHome,
                timeout: .seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds)),
                output: { line in
                    Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        self.console.appendProcessLine(line)
                    }
                }
            )
            console.markFinished()
            dependencyGraphCache[cacheKey] = (fingerprint, graph)
            return .success(graph)
        } catch {
            console.markFinished()
            return .failure(.message(Self.summarizeDependencyGraph(error)))
        }
    }

    private static func summarizeDependencyGraph(_ error: Error) -> String {
        switch error {
        case let GradleDependencyGraphError.failed(result):
            return "Gradle exited with code \(result.exitCode) while resolving the dependencies. The Gradle console has the output."
        case GradleDependencyGraphError.missingOutput:
            return "Gradle finished without writing the dependency graph."
        case let GradleDependencyGraphError.decodingFailed(underlying, _):
            return "The dependency graph could not be read: \(underlying)"
        case let GradleDependencyGraphError.unavailable(message):
            return message
        default:
            return summarizeTaskRun(error)
        }
    }

    // MARK: - Build files

    private func startBuildFileWatcher(root: URL) {
        stopBuildFileWatcher()
        let watcher = FSEventsFileSystemWatcher(root: root, latency: 0.4) { path in
            GradleBuildFiles.matches(path: path)
        }
        buildFileWatcher = watcher
        buildFileWatchTask = Task { [weak self] in
            await watcher.start()
            for await _ in watcher.events {
                guard let self, !Task.isCancelled else { return }
                guard self.buildFileWatcher === watcher else { return }
                if self.syncInFlight { continue }
                if case .syncing = self.syncState { continue }
                self.hasConfigurationChanges = true
            }
        }
    }

    private func stopBuildFileWatcher() {
        buildFileWatchTask?.cancel()
        buildFileWatchTask = nil
        let watcher = buildFileWatcher
        buildFileWatcher = nil
        if let watcher {
            Task { await watcher.stop() }
        }
    }

    // MARK: - Chrome

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if isActive {
            windows.append(IDEToolWindow(
                id: "gradle", systemImage: "square.stack.3d.up", title: "Gradle", shortcut: nil, tint: .purple,
                placement: .trailingTop, isOpen: workspace.showsProjectSidebar,
                toggle: { [weak workspace] in workspace?.toggleProjectSidebar() },
                order: IDEToolWindow.Order.gradleSidebar
            ))
        }
        if workspace.showsGradleConsoleTab {
            windows.append(workspace.bottomToolWindow(
                .gradle, "text.alignleft", "Gradle Console", nil, .purple, .trailingBottom,
                order: IDEToolWindow.Order.gradleConsole
            ))
        }
        return windows
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        [.button(
            id: "gradle.build", order: IDEToolbarItem.Order.build, systemImage: "hammer", help: "Build Project",
            action: { [weak workspace] in workspace?.buildGradleProject() }
        )]
    }

    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard workspace.showsGradleConsoleTab else { return [] }
        return [IDEBottomTabContribution(
            tab: .gradle, order: IDEBottomPanelTab.Order.gradle,
            item: { workspace in
                AnyView(IDEGradleTabItem(
                    isSelected: workspace.isBottomTabSelected(.gradle),
                    isSyncing: workspace.gradle.isBusy,
                    isFailed: workspace.gradle.syncState.isFailed,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.gradle) }
                ))
            },
            content: { workspace in
                AnyView(IDEProjectConsoleView(
                    log: workspace.gradle.console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { _ in AnyView(IDEGradleConsoleControls()) },
            staysWhenLastShellCloses: true
        )]
    }

    func makeSidebar() -> AnyView {
        AnyView(IDEGradleSidebarPanel())
    }
}
