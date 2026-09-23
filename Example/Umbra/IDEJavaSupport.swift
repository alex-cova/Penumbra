import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation

/// Owns Java code intelligence for the workspace: the shared `JavaIndex` (JDK + open project's
/// source tree + Gradle-resolved dependencies), the `JavaOverlayService` keeping it in sync with
/// open/edited documents, the background indexing that populates it, and -- when the opened folder
/// is a Gradle project -- syncing the module/dependency model via `GradleCommandRunner`.
/// `IDEIntelligenceServices` holds one instance and feeds its index into `JavaCompletionProvider`;
/// `IDEWorkspace` drives it (connect on bootstrap, retarget on `applyProjectRoot`, wire
/// `requestTrust` to a trust sheet).
///
/// Indexing runs in three independent, recombined pieces so opening/closing a project folder never
/// has to touch the (potentially large, slow-to-rebuild) JDK shard: the JDK is indexed once at
/// bootstrap (and re-indexed only if a Gradle sync reveals a language level that needs a different
/// installation) and its reader kept for the app's lifetime; a project's whole `.java` tree is
/// indexed whenever the project root changes (the fallback -- works for any folder, Gradle or not,
/// and stays in place while the very first Gradle sync is still running); and, for a trusted Gradle
/// project, a Gradle sync replaces the whole-tree source reader with one per module's real source
/// dirs and populates JAR readers from resolved dependencies.
@MainActor
@Observable
final class IDEJavaSupport {
    /// The state of Gradle project-model sync for the current project root, surfaced in the status
    /// bar and used to gate the "Reload"/"Show Output" commands.
    enum GradleSyncState: Equatable {
        /// No project open, or the open folder isn't a Gradle project.
        case notGradle
        /// A Gradle project was detected but hasn't synced yet (auto-sync is off, or the user
        /// hasn't answered the trust prompt).
        case awaitingTrust
        /// The user declined to trust this project's build scripts.
        case untrusted
        case syncing
        case synced(subprojects: Int, jars: Int)
        case failed(summary: String)
    }

    let javaIndex = JavaIndex()
    let overlayService: JavaOverlayService
    let completionProvider: JavaCompletionProvider
    let navigationProvider: JavaGoToDefinitionProvider

    private let paths = JavaIndexPaths.default()
    private let scheduler = JavaIndexScheduler()
    @ObservationIgnored private var jdkReader: JavaIndexShardReader?
    /// Project and jar shards carry `shardPath` so a Gradle source-set scope can hide the ones that
    /// are not on the file's compile classpath. The JDK shard does not: it is always visible.
    @ObservationIgnored private var projectSources: [JavaIndex.Source] = []
    @ObservationIgnored private var jarSources: [JavaIndex.Source] = []
    @ObservationIgnored private var jdkIndexingTask: Task<Void, Never>?
    @ObservationIgnored private var projectIndexingTask: Task<Void, Never>?
    @ObservationIgnored private var gradleSyncTask: Task<Void, Never>?
    /// Bumped on every `setProjectRoot` so an in-flight index or sync for the previous folder
    /// cannot publish over the new one. Distinct from `Task.isCancelled`: a reload of the *same*
    /// root cancels the previous task without changing the generation.
    @ObservationIgnored private var projectGeneration = 0
    /// Home of the JDK currently being indexed, if a select has already happened and the shard
    /// write hasn't finished. Compared so a repeat sync doesn't cancel an in-flight index of the
    /// same installation.
    @ObservationIgnored private var pendingJDKHomePath: String?
    /// Home of the JDK whose reader is installed.
    @ObservationIgnored private var indexedJDKHomePath: String?
    @ObservationIgnored private var projectRootURL: URL?
    /// True from the moment a sync task is scheduled until it finishes, including the trust prompt.
    /// Build-file events in that window are dropped so the save that triggered a reload doesn't
    /// immediately raise the banner again.
    @ObservationIgnored private var gradleSyncInFlight = false

    @ObservationIgnored private let gradleTrustStore: GradleTrustStore
    @ObservationIgnored private let gradleExtractor: GradleProjectModelExtractor

    @ObservationIgnored private var buildFileWatcher: FSEventsFileSystemWatcher?
    @ObservationIgnored private var buildFileWatchTask: Task<Void, Never>?

    /// A short, human-readable status for the status bar ("Indexing JDK 24…", "Resolving Gradle
    /// project…", "Indexing N dependencies…", or nil once idle).
    private(set) var statusMessage: String?
    private(set) var gradleSync: GradleSyncState = .notGradle
    /// Last successful project model. Used to pick `:app:run` versus `run` for the play button.
    private(set) var gradleModel: JavaGradleProjectModel?
    /// The last Gradle invocation's full result (stdout/stderr/exit code), whether it succeeded or
    /// failed -- backs "Java: Show Gradle Output".
    private(set) var lastGradleResult: GradleCommandResult?
    /// Dependencies the lenient model resolution could not resolve. Shown with the Gradle output,
    /// not as a failed sync.
    private(set) var lastUnresolved: [String] = []
    /// A human-readable description of the last project-model invocation (the real executable path
    /// is chosen inside `GradleCommandRunner` and isn't part of `GradleCommandResult`).
    private(set) var lastGradleCommandLine: String?
    /// Set when a watched Gradle build file changes outside of a sync. Bursts collapse to one
    /// banner; cleared by Reload or Dismiss.
    private(set) var gradleBuildFilesChanged = false

    /// Asks the user whether to trust `url` to run Gradle build scripts; set by `IDEWorkspace` to a
    /// sheet-presenting closure. `nil` means never prompt automatically -- a sync for an
    /// undecided root just settles on `.awaitingTrust` instead of running anything.
    var requestTrust: (@MainActor (URL) async -> Bool)?

    init(gradleTrustStoreURL: URL = IDEJavaSupport.defaultGradleTrustStoreURL) {
        overlayService = JavaOverlayService(index: javaIndex)
        completionProvider = JavaCompletionProvider(index: javaIndex)
        navigationProvider = JavaGoToDefinitionProvider(index: javaIndex, indexPaths: paths)
        gradleTrustStore = GradleTrustStore(storeURL: gradleTrustStoreURL)
        gradleExtractor = GradleProjectModelExtractor(runner: GradleCommandRunner(trustStore: gradleTrustStore))
    }

    /// `~/Library/Application Support/com.umbra.editor/gradle-trust.json`, alongside
    /// `IDESessionStore`'s `session.json`. Deliberately not under `JavaIndexPaths.default().root`
    /// (Caches, versioned by shard format) -- trust decisions shouldn't reset on a format bump.
    static var defaultGradleTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("gradle-trust.json")
    }

    var isGradleProject: Bool {
        if case .notGradle = gradleSync { return false }
        return projectRootURL != nil
    }

    /// Text for the Gradle output panel: command, exit code, unresolved dependencies, stdout, stderr.
    func gradleOutputText() -> String {
        guard let result = lastGradleResult else {
            var lines = ["No Gradle process output was captured."]
            if let lastGradleCommandLine {
                lines.insert("Command: \(lastGradleCommandLine)", at: 0)
            }
            if case .failed(let summary) = gradleSync {
                lines.append(summary)
            }
            return lines.joined(separator: "\n")
        }
        var parts: [String] = []
        if let projectRootURL {
            parts.append("Project: \(projectRootURL.path)")
        }
        if let lastGradleCommandLine {
            parts.append("Command: \(lastGradleCommandLine)")
        }
        parts.append("Exit code: \(result.exitCode)")
        if !lastUnresolved.isEmpty {
            parts.append("")
            parts.append("Unresolved dependencies:")
            parts.append(contentsOf: lastUnresolved.map { "  \($0)" })
        }
        parts.append("")
        parts.append("----- stdout -----")
        parts.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
        parts.append("")
        parts.append("----- stderr -----")
        parts.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
        return parts.joined(separator: "\n")
    }

    /// Connects the overlay service to the shared workspace (mirrors
    /// `IndexingService.connect(to:)`) and kicks off JDK indexing in the background, unless a
    /// Gradle sync has already selected one. Call once, from `IDEWorkspace.bootstrap()`.
    @discardableResult
    func connect(to workspace: Workspace) async -> Task<Void, Never> {
        let task = await overlayService.connect(to: workspace)
        if jdkIndexingTask == nil && indexedJDKHomePath == nil {
            indexJDK(minimumFeatureVersion: nil)
        }
        return task
    }

    /// Re-targets project-source indexing at a new folder (or clears it when `url` is `nil`, e.g.
    /// the user closes the folder). Safe to call repeatedly; a new call cancels any indexing still
    /// in flight for the previous root. If `url` looks like a Gradle project, also kicks off a
    /// Gradle sync (gated by trust and `javaGradleAutoSync`) that -- once it succeeds -- replaces
    /// the whole-tree fallback below with per-module sources and resolved dependency JARs.
    func setProjectRoot(_ url: URL?) {
        projectGeneration += 1
        let generation = projectGeneration
        projectIndexingTask?.cancel()
        gradleSyncTask?.cancel()
        stopBuildFileWatcher()
        gradleSyncInFlight = false
        gradleBuildFilesChanged = false
        projectRootURL = url
        gradleModel = nil
        let hadJars = !jarSources.isEmpty
        jarSources = []
        lastUnresolved = []
        clearSourceSetClasspath()

        guard let url else {
            projectSources = []
            gradleSync = .notGradle
            lastGradleResult = nil
            lastGradleCommandLine = nil
            Task { await publishSources() }
            return
        }

        indexWholeTree(at: url, generation: generation)

        guard GradleProjectModelExtractor.isGradleProject(url) else {
            gradleSync = .notGradle
            lastGradleResult = nil
            lastGradleCommandLine = nil
            if hadJars {
                Task { await publishSources() }
            }
            return
        }

        lastGradleResult = nil
        lastGradleCommandLine = nil
        gradleSync = .awaitingTrust
        startBuildFileWatcher(root: url)
        if hadJars {
            Task { await publishSources() }
        }
        if IDEPreferences.shared.javaGradleAutoSync {
            syncGradleProject(url, forcePrompt: false, generation: generation)
        }
    }

    /// Re-runs Gradle extraction for the current project root -- backs "Java: Reload Gradle
    /// Project". Re-asks for trust even if the user previously declined.
    func reloadGradleProject() {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else { return }
        syncGradleProject(url, forcePrompt: true, generation: projectGeneration)
    }

    func dismissGradleBuildFileChanges() {
        gradleBuildFilesChanged = false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == projectGeneration && !Task.isCancelled
    }

    private func indexWholeTree(at url: URL, generation: Int) {
        projectIndexingTask = Task { [paths, scheduler] in
            let root = SourceRoot(directory: url)
            let shardURL = paths.projectSourcesShard(for: url)
            if isCurrent(generation), statusMessage == nil {
                statusMessage = "Indexing project sources…"
            }
            for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
            guard isCurrent(generation) else { return }
            // A finished Gradle sync has already replaced these readers with per-module sources.
            if case .synced = gradleSync {
                if statusMessage == "Indexing project sources…" {
                    statusMessage = nil
                }
                return
            }
            if let reader = try? JavaIndexShardReader(url: shardURL) {
                // No shard path: this whole-tree fallback is only published while completion is
                // unscoped. A finished sync replaces it with per-source-set readers.
                projectSources = [.init(precedence: 1, reader: reader)]
            }
            if statusMessage == "Indexing project sources…" {
                statusMessage = nil
            }
            await publishSources()
        }
    }

    private func syncGradleProject(_ url: URL, forcePrompt: Bool, generation: Int) {
        gradleSyncTask?.cancel()
        gradleBuildFilesChanged = false
        gradleSyncInFlight = true
        gradleSyncTask = Task { [gradleTrustStore, gradleExtractor, paths, scheduler] in
            defer {
                if generation == projectGeneration && !Task.isCancelled {
                    gradleSyncInFlight = false
                }
            }
            if !gradleTrustStore.isTrusted(url) {
                let previouslyDeclined = gradleTrustStore.decision(for: url) == false
                if previouslyDeclined && !forcePrompt {
                    guard isCurrent(generation) else { return }
                    gradleSync = .untrusted
                    return
                }
                guard let requestTrust else {
                    guard isCurrent(generation) else { return }
                    gradleSync = .awaitingTrust
                    return
                }
                let trusted = await requestTrust(url)
                gradleTrustStore.setTrusted(trusted, for: url)
                guard isCurrent(generation) else { return }
                guard trusted else {
                    gradleSync = .untrusted
                    return
                }
            }
            guard isCurrent(generation) else { return }

            gradleSync = .syncing
            statusMessage = "Resolving Gradle project…"
            // Gradle itself (9.x) needs a modern JDK to launch, independent of the project's
            // source level, so this is the newest installation rather than the one selected for
            // `maxLanguageLevel`.
            let javaHome = await Task.detached(priority: .utility) {
                JDKLocator().select()?.home
            }.value
            guard isCurrent(generation) else { return }
            lastGradleCommandLine = Self.projectModelCommandLine(project: url, javaHome: javaHome)

            do {
                let timeout = Duration.seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds))
                let (model, result) = try await gradleExtractor.extract(
                    projectDirectory: url,
                    javaHome: javaHome,
                    timeout: timeout
                )
                guard isCurrent(generation) else { return }
                lastGradleResult = result
                lastUnresolved = model.unresolved
                gradleModel = model
                await adoptLanguageLevelIfNeeded(model.maxLanguageLevel, generation: generation)
                guard isCurrent(generation) else { return }

                let dependencyMessage = "Indexing \(model.classpathJars.count) dependencies…"
                statusMessage = dependencyMessage
                let sourceTargets = model.sourceIndexTargets(paths: paths)
                let jarTargets = model.jarIndexTargets(paths: paths)
                for await _ in await scheduler.index(sourceTargets + jarTargets) {}
                guard isCurrent(generation) else { return }

                projectSources = sourceTargets.compactMap { target in
                    guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                    return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
                }
                jarSources = jarTargets.compactMap { target in
                    guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                    return JavaIndex.Source(precedence: 2, reader: reader, shardPath: target.shardURL.path)
                }
                if statusMessage == dependencyMessage {
                    statusMessage = nil
                }
                gradleSync = .synced(subprojects: model.subprojects.count, jars: model.classpathJars.count)
                // Publish first so a scoped query never runs against shards that are not installed yet.
                await publishSources()
                await completionProvider.setSourceSetClasspath(model, indexPaths: paths)
                await navigationProvider.setSourceSetClasspath(model, indexPaths: paths)
            } catch {
                guard isCurrent(generation) else { return }
                clearSourceSetClasspath()
                gradleModel = nil
                // Only clear the message this task set. JDK indexing and the whole-tree fallback
                // publish their own status and must not be blanked by a Gradle failure.
                if statusMessage == "Resolving Gradle project…" {
                    statusMessage = nil
                }
                gradleSync = .failed(summary: Self.summarize(error))
                rememberGradleFailure(error)
            }
        }
    }

    /// Re-indexes the JDK only when the project's language level would select a different
    /// installation than the one already indexed (or in flight).
    private func adoptLanguageLevelIfNeeded(_ maxLevel: Int?, generation: Int) async {
        guard let maxLevel else { return }
        let selectedPath = await Task.detached(priority: .utility) {
            JDKLocator().select(minimumFeatureVersion: maxLevel)?.home.resolvingSymlinksInPath().path
        }.value
        guard isCurrent(generation) else { return }
        guard let selectedPath, selectedPath != (pendingJDKHomePath ?? indexedJDKHomePath) else { return }
        indexJDK(minimumFeatureVersion: maxLevel)
    }

    private func rememberGradleFailure(_ error: Error) {
        switch error {
        case let GradleProjectModelExtractionError.syncFailed(result),
             let GradleProjectModelExtractionError.missingOutput(result):
            lastGradleResult = result
        case let GradleProjectModelExtractionError.decodingFailed(_, result):
            lastGradleResult = result
        case let GradleCommandError.timedOut(partial),
             let GradleCommandError.cancelled(partial):
            lastGradleResult = partial
        default:
            break
        }
    }

    private static func projectModelCommandLine(project: URL, javaHome: URL?) -> String {
        let java = javaHome.map { "JAVA_HOME=\($0.path) " } ?? ""
        return "\(java)cd \(project.path) && gradle --console=plain --init-script umbra-project-model.init.gradle --no-configuration-cache -PumbraModelOutput=model.json :umbraProjectModel"
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

    private func indexJDK(minimumFeatureVersion: Int?) {
        jdkIndexingTask?.cancel()
        pendingJDKHomePath = nil
        jdkIndexingTask = Task { [paths, scheduler] in
            // JDKLocator.select() does synchronous filesystem/process work (java_home -X, walking
            // ~/Library/Java/JavaVirtualMachines); hopped off the main actor so it can't stall the
            // UI during app launch.
            let installation = await Task.detached(priority: .utility) {
                JDKLocator().select(minimumFeatureVersion: minimumFeatureVersion)
            }.value
            guard !Task.isCancelled else { return }
            guard let installation else {
                return
            }
            let homePath = installation.home.resolvingSymlinksInPath().path
            pendingJDKHomePath = homePath
            let root = JDKCtSymRoot(installation: installation)
            let shardURL = paths.jdkShard(installation, kind: "ctsym")
            let message = "Indexing JDK \(installation.featureVersion)…"
            if statusMessage == nil {
                statusMessage = message
            }
            for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
            guard !Task.isCancelled else { return }
            jdkReader = try? JavaIndexShardReader(url: shardURL)
            indexedJDKHomePath = homePath
            pendingJDKHomePath = nil
            if statusMessage == message {
                statusMessage = nil
            }
            await publishSources()
        }
    }

    private func publishSources() async {
        var sources: [JavaIndex.Source] = []
        if let jdkReader { sources.append(.init(precedence: 3, reader: jdkReader)) }
        sources.append(contentsOf: projectSources)
        sources.append(contentsOf: jarSources)
        await javaIndex.setSources(sources)
        if let indexedJDKHomePath {
            await navigationProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
        }
    }

    private func clearSourceSetClasspath() {
        Task {
            await completionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await navigationProvider.setSourceSetClasspath(nil, indexPaths: paths)
        }
    }

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
                if self.gradleSyncInFlight { continue }
                if case .syncing = self.gradleSync { continue }
                self.gradleBuildFilesChanged = true
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
}
