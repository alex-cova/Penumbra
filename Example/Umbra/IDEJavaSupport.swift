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

        var isSyncing: Bool {
            if case .syncing = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let javaIndex = JavaIndex()
    let overlayService: JavaOverlayService
    let completionProvider: JavaCompletionProvider
    let navigationProvider: JavaGoToDefinitionProvider
    /// Semantic Find Usages (`.references`); candidates come from ``nameIndex``.
    let findUsagesProvider: JavaFindUsagesProvider
    /// Quick fixes (import a class, remove unused imports) behind Show Context Actions and Optimize Imports.
    let codeActionProvider: JavaCodeActionProvider
    /// Signature and Javadoc on hover and for Quick Documentation.
    let hoverProvider: JavaHoverProvider
    /// Supertype and subtype trees for the Type Hierarchy tab.
    let hierarchyProvider: JavaTypeHierarchyProvider
    /// Classifies Java identifiers for semantic highlighting.
    let semanticTokenProvider: JavaSemanticTokenProvider
    /// Parameter-name hints at call sites (the Parameter Name Hints preference).
    let inlayHintProvider: JavaInlayHintProvider
    /// Rename for classes, interfaces, enums, records, annotations, locals and parameters.
    let renameProvider: JavaRenameProvider
    /// Selection-based refactorings (extract variable, …).
    let refactoringProvider: JavaRefactoringProvider
    /// Discovered JUnit tests in test source roots.
    let testIndex = JavaTestIndex()
    /// Reformats Java files (⌥⌘L) with the built-in formatter.
    let formattingProvider = JavaFormattingProvider()
    /// Breadcrumbs like `Outer › Inner<T> › put(String, int)` for Java files.
    let breadcrumbProvider = JavaBreadcrumbProvider()
    /// `javac`-backed diagnostics for open Java files. Idle until ``refreshCompilerDiagnostics()``
    /// finds a project state it may check: a plain folder, or a Gradle project that has synced.
    let compilerDiagnostics = JavaCompilerDiagnosticsService()

    private let paths = JavaIndexPaths.default()
    private let scheduler = JavaIndexScheduler()
    /// Identifier index (`refs.idx`) of the project's source roots; the candidate source for
    /// semantic Find Usages and rename.
    let nameIndex = JavaNameIndex()
    @ObservationIgnored private var jdkReader: JavaIndexShardReader?
    /// Project and jar shards carry `shardPath` so a Gradle source-set scope can hide the ones that
    /// are not on the file's compile classpath. The JDK shard does not: it is always visible.
    @ObservationIgnored private var projectSources: [JavaIndex.Source] = []
    @ObservationIgnored private var jarSources: [JavaIndex.Source] = []
    @ObservationIgnored private var jdkIndexingTask: Task<Void, Never>?
    @ObservationIgnored private var projectIndexingTask: Task<Void, Never>?
    @ObservationIgnored private var nameIndexTask: Task<Void, Never>?
    /// Source roots whose stub shard must be rebuilt after `.java` files changed on disk, and the
    /// task draining them (one refresh at a time).
    @ObservationIgnored private var nameIndexRoots: [URL] = []
    @ObservationIgnored private var pendingStubRefresh: Set<URL> = []
    @ObservationIgnored private var stubRefreshTask: Task<Void, Never>?
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
    @ObservationIgnored private let gradleModelCache: GradleProjectModelCache
    @ObservationIgnored private let gradleRunner: GradleCommandRunner
    @ObservationIgnored private let gradleExtractor: GradleProjectModelExtractor
    @ObservationIgnored private var gradleRunTask: Task<Void, Never>?

    @ObservationIgnored private var buildFileWatcher: FSEventsFileSystemWatcher?
    @ObservationIgnored private var buildFileWatchTask: Task<Void, Never>?

    /// A short, human-readable status for the status bar ("Indexing JDK 24…", "Resolving Gradle
    /// project…", "Indexing N dependencies…", or nil once idle).
    private(set) var statusMessage: String?
    private(set) var gradleSync: GradleSyncState = .notGradle
    /// Last successful project model. Used to pick `:app:run` versus `run` for the play button.
    private(set) var gradleModel: JavaGradleProjectModel? {
        didSet {
            if oldValue == nil, gradleModel == nil { return }
            onGradleModelChanged?(gradleModel)
            let model = gradleModel
            Task { [renameProvider, refactoringProvider] in
                await renameProvider.setGradleModel(model)
                await refactoringProvider.setGradleModel(model)
            }
        }
    }
    /// Called whenever a sync sets or clears ``gradleModel`` (the Go to File index labels files
    /// with their module).
    @ObservationIgnored var onGradleModelChanged: (@MainActor (JavaGradleProjectModel?) -> Void)?
    /// Called with each finished compile's diagnostics for one file (empty when it is clean).
    @ObservationIgnored var onCompilerDiagnostics: (@MainActor (URL, [Diagnostic]) -> Void)?
    /// Called once the compiler is (re)configured, so the host can check the files already open.
    @ObservationIgnored var onCompilerConfigured: (@MainActor () -> Void)?
    @ObservationIgnored private var compilerConfigurationTask: Task<Void, Never>?
    /// Live output of the most recent (or in-progress) Gradle sync -- backs the "Gradle" console
    /// tab in the bottom panel. Reset at the start of every sync.
    private(set) var gradleConsole = IDEGradleConsoleLog()
    /// Set when a watched Gradle build file changes outside of a sync. Bursts collapse to one
    /// banner; cleared by Reload or Dismiss.
    private(set) var gradleBuildFilesChanged = false
    /// True while a user-triggered Gradle task (from the sidebar or elsewhere) is running.
    private(set) var isRunningGradleTasks = false
    private(set) var runningGradleTaskPaths: [String] = []

    var isGradleBusy: Bool { gradleSync.isSyncing || isRunningGradleTasks }

    /// Asks the user whether to trust `url` to run Gradle build scripts; set by `IDEWorkspace` to a
    /// sheet-presenting closure. `nil` means never prompt automatically -- a sync for an
    /// undecided root just settles on `.awaitingTrust` instead of running anything.
    var requestTrust: (@MainActor (URL) async -> Bool)?
    /// Called when a sync ends in `.failed` (not on a user-initiated cancel) so `IDEWorkspace` can
    /// surface the Gradle console automatically.
    var onGradleSyncFailed: (@MainActor () -> Void)?
    /// A Gradle task run ended (finished, timed out or cancelled), with whatever output it
    /// produced, so the host can pull compiler errors out of it.
    @ObservationIgnored var onGradleTasksFinished: (@MainActor (_ tasks: [String], _ projectRoot: URL, _ result: GradleCommandResult) -> Void)?
    /// When set, the finished Gradle run's XML reports are parsed into test results.
    private(set) var pendingTestRunRequest: JavaTestRunRequest?

    init(
        gradleTrustStoreURL: URL = IDEJavaSupport.defaultGradleTrustStoreURL,
        gradleModelCacheRoot: URL = IDEJavaSupport.defaultGradleModelCacheRoot
    ) {
        overlayService = JavaOverlayService(index: javaIndex)
        completionProvider = JavaCompletionProvider(index: javaIndex)
        navigationProvider = JavaGoToDefinitionProvider(index: javaIndex, indexPaths: paths)
        findUsagesProvider = JavaFindUsagesProvider(index: javaIndex, indexPaths: paths, nameIndex: nameIndex)
        codeActionProvider = JavaCodeActionProvider(index: javaIndex)
        hoverProvider = JavaHoverProvider(index: javaIndex, indexPaths: paths)
        hierarchyProvider = JavaTypeHierarchyProvider(index: javaIndex, indexPaths: paths)
        semanticTokenProvider = JavaSemanticTokenProvider(index: javaIndex)
        inlayHintProvider = JavaInlayHintProvider(index: javaIndex, indexPaths: paths)
        let renameCandidates = JavaIndexedOrScanningCandidates(nameIndex: nameIndex, scan: JavaTextScanCandidateSource())
        renameProvider = JavaRenameProvider(index: javaIndex, indexPaths: paths, candidates: renameCandidates)
        refactoringProvider = JavaRefactoringProvider(index: javaIndex, indexPaths: paths, candidates: renameCandidates)
        gradleTrustStore = GradleTrustStore(storeURL: gradleTrustStoreURL)
        gradleModelCache = GradleProjectModelCache(cacheRoot: gradleModelCacheRoot)
        let runner = GradleCommandRunner(trustStore: gradleTrustStore)
        gradleRunner = runner
        gradleExtractor = GradleProjectModelExtractor(runner: runner)
        Task { [weak self] in await self?.installCompilerResultHandler() }
        Task { [overlayService, testIndex] in
            await overlayService.setOnDocumentIndexed { _, url, text in
                await testIndex.scheduleRescan(file: url, source: text)
            }
        }
    }

    func tests(for file: URL) async -> JavaTestClass? {
        await testIndex.testClass(for: file)
    }

    func allTestClasses() async -> [JavaTestClass] {
        await testIndex.allTestClasses()
    }

    func isTestSource(file: URL) async -> Bool {
        await testIndex.isTestSource(file: file)
    }

    func runTests(scope: JavaTestRunScope) {
        guard let url = projectRootURL else { return }
        guard let request = JavaTestRunner.request(scope: scope, projectRoot: url, model: gradleModel) else { return }
        pendingTestRunRequest = request
        let args = JavaTestRunner.gradleArguments(for: request)
        runGradleTasks([request.gradleTaskPath], extraArguments: args)
    }

    func takePendingTestRunRequest() -> JavaTestRunRequest? {
        defer { pendingTestRunRequest = nil }
        return pendingTestRunRequest
    }

    var hasPendingTestRun: Bool { pendingTestRunRequest != nil }

    private func reindexTests(model: JavaGradleProjectModel) {
        Task {
            await testIndex.setGradleModel(model)
            await testIndex.reindexAll(in: model.existingTestSourceDirectories)
        }
    }

    private func clearTestIndex() {
        Task { await testIndex.setGradleModel(nil) }
    }

    private func installCompilerResultHandler() async {
        await compilerDiagnostics.setResultHandler { [weak self] url, diagnostics in
            Task { @MainActor in self?.onCompilerDiagnostics?(url, diagnostics) }
        }
    }

    /// Scratch space for `javac` buffer copies, under the app's Caches directory.
    static var compilerWorkDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("javac", isDirectory: true)
    }

    /// Points the compiler at the current project, or turns it off. Nothing is checked in a Gradle
    /// project until its sync has produced a model (which needs the trust prompt), nor when the
    /// user has turned the preference off, nor when no installed JDK ships a `javac`.
    func refreshCompilerDiagnostics() {
        compilerConfigurationTask?.cancel()
        let generation = projectGeneration
        let root = projectRootURL
        let model = gradleModel
        let waitingOnGradle = isGradleProject && model == nil
        let enabled = IDEPreferences.shared.javaCompilerDiagnostics
        compilerConfigurationTask = Task { [compilerDiagnostics] in
            guard enabled, !waitingOnGradle else {
                await compilerDiagnostics.configure(nil)
                guard isCurrent(generation), !Task.isCancelled else { return }
                onCompilerConfigured?()
                return
            }
            // `JDKLocator.select()` does synchronous filesystem and process work.
            let jdk = await Task.detached(priority: .utility) {
                JDKLocator().select(minimumFeatureVersion: model?.maxLanguageLevel)
            }.value
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard let jdk, jdk.javac != nil else {
                await compilerDiagnostics.configure(nil)
                return
            }
            await compilerDiagnostics.configure(.init(
                kind: model.map { .gradle($0) } ?? .plainFolder,
                jdk: jdk,
                projectRoot: root ?? FileManager.default.temporaryDirectory,
                workDirectory: Self.compilerWorkDirectory
            ))
            guard isCurrent(generation), !Task.isCancelled else { return }
            onCompilerConfigured?()
        }
    }

    /// Checks `documents` now instead of waiting for the editor to go idle -- after a save, or once
    /// the compiler is configured. `force` rechecks files whose own text did not change.
    func compileNow(_ documents: [EditorIntelligence.Document], force: Bool = false) {
        Task { [compilerDiagnostics] in
            for document in documents {
                await compilerDiagnostics.compileNow(document, force: force)
            }
        }
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

    static var defaultGradleModelCacheRoot: URL {
        GradleProjectModelCache.defaultCacheRoot(bundleIdentifier: "com.umbra.editor")
    }

    /// Standardized paths of every Gradle source directory from the last successful sync. Empty
    /// before a sync; the Explorer also recognizes the `src/<set>/java` convention on its own.
    var javaSourceRootPaths: Set<String> {
        guard let gradleModel else { return [] }
        var paths: Set<String> = []
        for subproject in gradleModel.subprojects {
            for sourceSet in subproject.sourceSets {
                for directory in sourceSet.sourceDirs {
                    paths.insert(directory.standardizedFileURL.path)
                }
            }
        }
        return paths
    }

    var isGradleProject: Bool {
        if case .notGradle = gradleSync { return false }
        return projectRootURL != nil
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
        stubRefreshTask?.cancel()
        stubRefreshTask = nil
        pendingStubRefresh = []
        gradleSyncTask?.cancel()
        gradleRunTask?.cancel()
        stopBuildFileWatcher()
        gradleSyncInFlight = false
        gradleBuildFilesChanged = false
        projectRootURL = url
        gradleModel = nil
        clearTestIndex()
        let hadJars = !jarSources.isEmpty
        jarSources = []
        gradleConsole = IDEGradleConsoleLog()
        clearSourceSetClasspath()

        guard let url else {
            buildNameIndex(roots: [], generation: generation)
            projectSources = []
            gradleSync = .notGradle
            Task { await publishSources() }
            refreshCompilerDiagnostics()
            return
        }

        guard GradleProjectModelExtractor.isGradleProject(url) else {
            indexWholeTree(at: url, generation: generation)
            gradleSync = .notGradle
            if hadJars {
                Task { await publishSources() }
            }
            refreshCompilerDiagnostics()
            return
        }

        gradleSync = .awaitingTrust
        // Off until a sync produces a model: a failed or declined sync must not flood files with
        // false "cannot find symbol" errors.
        refreshCompilerDiagnostics()
        startBuildFileWatcher(root: url)
        if hadJars {
            Task { await publishSources() }
        }

        let canUseCache = IDEPreferences.shared.javaGradleAutoSync && gradleTrustStore.isTrusted(url)
        if canUseCache, let cachedModel = gradleModelCache.loadIfValid(projectRoot: url) {
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

        indexWholeTree(at: url, generation: generation)
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

    /// Re-runs Gradle extraction for the current project root -- backs "Java: Reload Gradle
    /// Project". Re-asks for trust even if the user previously declined.
    /// Adds a line to the Gradle console, for messages from the host (why a launch did not start).
    func appendGradleConsoleNote(_ text: String) {
        gradleConsole.appendNote(text)
    }

    func reloadGradleProject() {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else { return }
        gradleModelCache.invalidate(projectRoot: url)
        syncGradleProject(
            url,
            forcePrompt: true,
            generation: projectGeneration,
            silent: false,
            invalidateCacheBeforeSync: false,
            bootstrapModel: nil
        )
    }

    /// Runs one or more Gradle tasks for the current project, streaming output into the Gradle
    /// console tab. No-op while a sync or another task run is already in progress. Asks for trust
    /// first when the project has not been trusted yet.
    func runGradleTasks(_ taskPaths: [String], extraArguments: [String] = []) {
        guard let url = projectRootURL, GradleProjectModelExtractor.isGradleProject(url) else { return }
        guard !taskPaths.isEmpty else { return }
        guard !gradleSync.isSyncing, !isRunningGradleTasks else { return }

        gradleRunTask?.cancel()
        let arguments = extraArguments.isEmpty ? ["--no-configuration-cache"] : extraArguments
        gradleRunTask = Task { [gradleRunner] in
            isRunningGradleTasks = true
            runningGradleTaskPaths = taskPaths
            gradleConsole.reset()
            gradleConsole.appendNote("Project: \(url.path)")
            gradleConsole.appendNote("Tasks: \(taskPaths.joined(separator: " "))")

            let javaHome = await Task.detached(priority: .utility) {
                JDKLocator().select()?.home
            }.value
            if let javaHome {
                gradleConsole.appendNote("JAVA_HOME: \(javaHome.path)")
            }

            defer {
                isRunningGradleTasks = false
                runningGradleTaskPaths = []
            }

            // Build scripts run arbitrary code, so an untrusted project is asked first, as a sync
            // would. On a "no" nothing runs, and it is asked again next time.
            if !gradleTrustStore.isTrusted(url) {
                guard let requestTrust, await requestTrust(url) else {
                    gradleConsole.appendNote("Not run: the project is not trusted")
                    gradleConsole.markFinished()
                    return
                }
                gradleTrustStore.setTrusted(true, for: url)
            }

            do {
                let timeout = Duration.seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds))
                let startedAt = Date()
                let result = try await gradleRunner.run(
                    projectDirectory: url,
                    tasks: taskPaths,
                    arguments: arguments,
                    javaHome: javaHome,
                    timeout: timeout,
                    output: { line in
                        Task { @MainActor in
                            guard !Task.isCancelled else { return }
                            self.gradleConsole.appendProcessLine(line)
                        }
                    }
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                gradleConsole.appendNote(String(format: "Gradle exited %d in %.1fs", result.exitCode, elapsed))
                gradleConsole.markFinished()
                if result.exitCode == 0 { reindexGeneratedSources() }
                onGradleTasksFinished?(taskPaths, url, result)
            } catch is CancellationError {
                gradleConsole.appendNote("Task run cancelled")
                gradleConsole.markFinished()
            } catch {
                gradleConsole.appendNote(Self.summarizeTaskRun(error))
                gradleConsole.markFinished()
                switch error {
                case GradleCommandError.timedOut(let partial), GradleCommandError.cancelled(let partial):
                    onGradleTasksFinished?(taskPaths, url, partial)
                default:
                    break
                }
                if case GradleCommandError.untrusted = error {
                    gradleSync = .untrusted
                }
            }
        }
    }

    func cancelGradleTasks() {
        guard isRunningGradleTasks else { return }
        gradleRunTask?.cancel()
        gradleRunTask = nil
        isRunningGradleTasks = false
        runningGradleTaskPaths = []
        gradleConsole.appendNote("Task run cancelled")
        gradleConsole.markFinished()
    }

    func dismissGradleBuildFileChanges() {
        gradleBuildFilesChanged = false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == projectGeneration && !Task.isCancelled
    }

    /// Builds the identifier index for `roots` beside the stub pass. Replaces the previous set of
    /// roots; only files whose stamp changed are re-tokenized.
    private func buildNameIndex(roots: [URL], generation: Int) {
        nameIndexTask?.cancel()
        nameIndexRoots = roots.map(\.standardizedFileURL)
        let searchRoots = nameIndexRoots
        Task { [findUsagesProvider] in await findUsagesProvider.setProjectRoots(searchRoots) }
        let renameRoots = nameIndexRoots
        Task { [renameProvider, refactoringProvider] in
            await renameProvider.setRoots(renameRoots)
            await refactoringProvider.setRoots(renameRoots)
        }
        nameIndexTask = Task { [nameIndex] in
            for await _ in await nameIndex.build(roots: roots) {
                guard isCurrent(generation) else { return }
            }
        }
    }

    /// `.java` files changed on disk (from `IDEProjectWatcher`): update the identifier index for
    /// them and rebuild the stub shard of every source root that changed, bypassing the
    /// directory-mtime stamp (which does not move when a file is merely edited).
    func projectFilesChanged(_ changedPaths: Set<String>) {
        guard projectRootURL != nil, !nameIndexRoots.isEmpty else { return }
        // Extension-less paths may be directories that were added, removed or renamed.
        let urls = changedPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension == "java" || $0.pathExtension.isEmpty }
        guard !urls.isEmpty else { return }
        let generation = projectGeneration
        Task { [nameIndex] in
            let affected = await nameIndex.filesChanged(urls)
            guard isCurrent(generation), !affected.isEmpty else { return }
            pendingStubRefresh.formUnion(affected)
            refreshStubs(generation: generation)
        }
    }

    private func refreshStubs(generation: Int) {
        guard stubRefreshTask == nil else { return }
        stubRefreshTask = Task { [paths, scheduler] in
            while isCurrent(generation), !pendingStubRefresh.isEmpty {
                let directories = pendingStubRefresh
                pendingStubRefresh = []
                let targets: [(root: any JavaIndexableRoot, shardURL: URL)] = directories.map {
                    (SourceRoot(directory: $0), paths.projectSourcesShard(for: $0))
                }
                for await _ in await scheduler.index(targets, force: true) {}
                guard isCurrent(generation) else { break }
                let refreshed = Set(targets.map(\.shardURL.path))
                let wholeTreeShard = projectRootURL.map { paths.projectSourcesShard(for: $0).path }
                var isSynced = false
                if case .synced = gradleSync { isSynced = true }
                projectSources = projectSources.map { source in
                    let shardPath = source.shardPath.isEmpty && !isSynced ? wholeTreeShard : source.shardPath
                    guard let shardPath, refreshed.contains(shardPath),
                          let reader = try? JavaIndexShardReader(url: URL(fileURLWithPath: shardPath)) else { return source }
                    return JavaIndex.Source(precedence: source.precedence, reader: reader, shardPath: source.shardPath)
                }
                await publishSources()
            }
            stubRefreshTask = nil
        }
    }

    private func indexWholeTree(at url: URL, generation: Int) {
        buildNameIndex(roots: [url], generation: generation)
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

    private func syncGradleProject(
        _ url: URL,
        forcePrompt: Bool,
        generation: Int,
        silent: Bool,
        invalidateCacheBeforeSync: Bool,
        bootstrapModel: JavaGradleProjectModel?
    ) {
        gradleSyncTask?.cancel()
        if !silent {
            gradleBuildFilesChanged = false
        }
        gradleSyncInFlight = true
        gradleSyncTask = Task { [gradleTrustStore, gradleExtractor, gradleModelCache, paths, scheduler] in
            defer {
                if generation == projectGeneration && !Task.isCancelled {
                    gradleSyncInFlight = false
                }
            }
            if invalidateCacheBeforeSync {
                gradleModelCache.invalidate(projectRoot: url)
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

            if let bootstrapModel {
                gradleModel = bootstrapModel
                gradleSync = .synced(
                    subprojects: bootstrapModel.subprojects.count,
                    jars: bootstrapModel.classpathJars.count
                )
                await applyGradleModel(
                    bootstrapModel,
                    previousModel: nil,
                    generation: generation,
                    logToConsole: false,
                    paths: paths,
                    scheduler: scheduler
                )
                guard isCurrent(generation) else { return }
            }

            let previousModel = gradleModel
            if !silent {
                gradleSync = .syncing
                statusMessage = "Resolving Gradle project…"
            }
            // Gradle itself (9.x) needs a modern JDK to launch, independent of the project's
            // source level, so this is the newest installation rather than the one selected for
            // `maxLanguageLevel`.
            let javaHome = await Task.detached(priority: .utility) {
                JDKLocator().select()?.home
            }.value
            guard isCurrent(generation) else { return }

            if silent {
                gradleConsole.appendNote("Refreshing Gradle project model in the background…")
            } else {
                gradleConsole.reset()
            }
            gradleConsole.appendNote("Project: \(url.path)")
            gradleConsole.appendNote("Command: \(Self.projectModelCommandLine(project: url, javaHome: javaHome))")
            if let javaHome {
                gradleConsole.appendNote("JAVA_HOME: \(javaHome.path)")
            }

            do {
                let timeout = Duration.seconds(max(30, IDEPreferences.shared.javaGradleSyncTimeoutSeconds))
                let startedAt = Date()
                let (model, result) = try await gradleExtractor.extract(
                    projectDirectory: url,
                    javaHome: javaHome,
                    timeout: timeout,
                    output: { line in
                        Task { @MainActor in
                            guard generation == self.projectGeneration else { return }
                            self.gradleConsole.appendProcessLine(line)
                        }
                    }
                )
                guard isCurrent(generation) else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                gradleConsole.appendNote(String(format: "Gradle exited %d in %.1fs", result.exitCode, elapsed))
                if !model.unresolved.isEmpty {
                    gradleConsole.appendNote("Unresolved dependencies:")
                    for dependency in model.unresolved {
                        gradleConsole.appendNote("  \(dependency)")
                    }
                }

                gradleModelCache.store(projectRoot: url, model: model)

                if silent, let previousModel, Self.modelsAreEqual(previousModel, model) {
                    gradleConsole.appendNote("Background refresh: project model unchanged")
                    gradleConsole.markFinished()
                    return
                }

                gradleModel = model
                await applyGradleModel(
                    model,
                    previousModel: previousModel,
                    generation: generation,
                    logToConsole: !silent,
                    paths: paths,
                    scheduler: scheduler
                )
                guard isCurrent(generation) else { return }

                gradleSync = .synced(subprojects: model.subprojects.count, jars: model.classpathJars.count)
                if silent {
                    gradleConsole.appendNote("Background refresh finished")
                } else {
                    gradleConsole.appendNote("Sync finished")
                }
                gradleConsole.markFinished()
            } catch {
                guard isCurrent(generation) else { return }
                if silent {
                    gradleConsole.appendNote("Background refresh failed: \(Self.summarize(error))")
                    gradleConsole.markFinished()
                    return
                }
                clearSourceSetClasspath()
                gradleModel = nil
                // Only clear the message this task set. JDK indexing and the whole-tree fallback
                // publish their own status and must not be blanked by a Gradle failure.
                if statusMessage == "Resolving Gradle project…" {
                    statusMessage = nil
                }
                let summary = Self.summarize(error)
                gradleSync = .failed(summary: summary)
                gradleConsole.appendNote(summary)
                gradleConsole.markFinished()
                onGradleSyncFailed?()
            }
        }
    }

    private func applyGradleModel(
        _ model: JavaGradleProjectModel,
        previousModel: JavaGradleProjectModel?,
        generation: Int,
        logToConsole: Bool,
        paths: JavaIndexPaths,
        scheduler: JavaIndexScheduler
    ) async {
        await adoptLanguageLevelIfNeeded(model.maxLanguageLevel, generation: generation)
        guard isCurrent(generation) else { return }

        let diff = JavaGradleProjectModel.diff(old: previousModel, new: model)
        let sourceTargets = model.sourceIndexTargets(paths: paths)
        let jarTargets = model.jarIndexTargets(paths: paths)
        let shouldFullRebuild = previousModel == nil
            || diff.shouldForceFullRebuild(totalSourceRoots: sourceTargets.count, totalJars: jarTargets.count)

        if shouldFullRebuild {
            buildNameIndex(roots: model.existingSourceDirectories, generation: generation)
            await indexAllTargets(sourceTargets + jarTargets, model: model, generation: generation, logToConsole: logToConsole, paths: paths, scheduler: scheduler)
        } else if !diff.isEmpty {
            buildNameIndex(roots: model.existingSourceDirectories, generation: generation)
            for directory in diff.removedSourceDirectories {
                try? FileManager.default.removeItem(at: paths.projectSourcesShard(for: directory))
            }
            for jar in diff.removedJars {
                try? FileManager.default.removeItem(at: paths.jarShard(jar))
            }
            let reindexDirs = diff.addedSourceDirectories + diff.changedSourceDirectories
            let reindexSources = reindexDirs.map { directory in
                (SourceRoot(directory: directory) as any JavaIndexableRoot, paths.projectSourcesShard(for: directory))
            }
            let reindexJars = diff.addedJars.map { jar in
                (JarRoot(jarURL: jar, languageLevel: model.maxLanguageLevel ?? Int.max) as any JavaIndexableRoot, paths.jarShard(jar))
            }
            await indexAllTargets(reindexSources + reindexJars, model: model, generation: generation, logToConsole: logToConsole, paths: paths, scheduler: scheduler)
            projectSources = sourceTargets.compactMap { target in
                guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
            }
            jarSources = jarTargets.compactMap { target in
                guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                return JavaIndex.Source(precedence: 2, reader: reader, shardPath: target.shardURL.path)
            }
        } else {
            buildNameIndex(roots: model.existingSourceDirectories, generation: generation)
        }

        guard isCurrent(generation) else { return }
        if statusMessage?.hasPrefix("Indexing dependencies…") == true {
            statusMessage = nil
        }
        await publishSources()
        await completionProvider.setSourceSetClasspath(model, indexPaths: paths)
        await navigationProvider.setSourceSetClasspath(model, indexPaths: paths)
        await findUsagesProvider.setSourceSetClasspath(model, indexPaths: paths)
        await codeActionProvider.setSourceSetClasspath(model, indexPaths: paths)
        await hoverProvider.setSourceSetClasspath(model, indexPaths: paths)
        await hierarchyProvider.setSourceSetClasspath(model, indexPaths: paths)
        await inlayHintProvider.setSourceSetClasspath(model, indexPaths: paths)
        reindexTests(model: model)
        refreshCompilerDiagnostics()
    }

    private func indexAllTargets(
        _ targets: [(root: any JavaIndexableRoot, shardURL: URL)],
        model: JavaGradleProjectModel,
        generation: Int,
        logToConsole: Bool,
        paths: JavaIndexPaths,
        scheduler: JavaIndexScheduler
    ) async {
        let totalTargets = targets.count
        if logToConsole {
            gradleConsole.appendNote("Indexing \(model.classpathJars.count) dependencies…")
        }
        var completedTargets = 0
        for await progress in await scheduler.index(targets) {
            guard isCurrent(generation) else { return }
            switch progress {
            case .allFinished:
                continue
            case .rootStarted(let id):
                if logToConsole {
                    gradleConsole.appendNote("Indexing \(Self.shortRootName(id))…")
                }
                if logToConsole, totalTargets > 0 {
                    statusMessage = "Indexing dependencies… (\(completedTargets)/\(totalTargets)): \(Self.shortRootName(id))"
                }
                continue
            case .rootSkipped(let id, let reason):
                completedTargets += 1
                if logToConsole {
                    gradleConsole.appendNote("Skipped \(Self.shortRootName(id)) (\(reason))")
                }
            case .rootFinished(let id, let classCount):
                completedTargets += 1
                if logToConsole {
                    gradleConsole.appendNote("Indexed \(Self.shortRootName(id)) (\(classCount) classes)")
                }
            case .rootFailed(let id, let message):
                completedTargets += 1
                if logToConsole {
                    gradleConsole.appendNote("Failed to index \(Self.shortRootName(id)): \(message)")
                }
            }
            if logToConsole, totalTargets > 0 {
                statusMessage = "Indexing dependencies… (\(completedTargets)/\(totalTargets))"
            }
        }
        guard isCurrent(generation) else { return }

        let sourceTargets = model.sourceIndexTargets(paths: paths)
        let jarTargets = model.jarIndexTargets(paths: paths)
        projectSources = sourceTargets.compactMap { target in
            guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
            return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
        }
        jarSources = jarTargets.compactMap { target in
            guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
            return JavaIndex.Source(precedence: 2, reader: reader, shardPath: target.shardURL.path)
        }
    }

    /// After a build, annotation processors may have written (or rewritten) sources under the
    /// model's generated directories. A root's stamp is its directory's own mtime, which misses
    /// nested changes, so the generated shards are dropped and rebuilt.
    func reindexGeneratedSources() {
        guard let model = gradleModel else { return }
        let generation = projectGeneration
        Task { [paths, scheduler] in
            let all = model.sourceIndexTargets(paths: paths)
            let generated = all.filter { ($0.root as? SourceRoot)?.isGenerated == true }
            guard !generated.isEmpty else { return }
            for target in generated { try? FileManager.default.removeItem(at: target.shardURL) }
            for await _ in await scheduler.index(generated) {}
            guard isCurrent(generation) else { return }
            projectSources = all.compactMap { target in
                guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
            }
            await publishSources()
        }
    }

    private static func modelsAreEqual(_ lhs: JavaGradleProjectModel, _ rhs: JavaGradleProjectModel) -> Bool {
        guard let left = try? JSONEncoder().encode(lhs),
              let right = try? JSONEncoder().encode(rhs) else {
            return false
        }
        return left == right
    }

    /// Cancels an in-progress sync -- backs the Gradle console tab's Cancel button. A no-op unless
    /// a sync is actually running: the task's own `catch` never sees a plain cancellation (it
    /// returns early once `isCurrent` sees `Task.isCancelled`), so the state transition has to
    /// happen here instead.
    func cancelGradleSync() {
        guard case .syncing = gradleSync else { return }
        gradleSyncTask?.cancel()
        gradleSyncTask = nil
        gradleSyncInFlight = false
        if statusMessage == "Resolving Gradle project…" {
            statusMessage = nil
        }
        gradleSync = .failed(summary: "Gradle sync was cancelled")
        gradleConsole.appendNote("Sync cancelled")
        gradleConsole.markFinished()
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

    private func indexJDK(minimumFeatureVersion: Int?) {
        jdkIndexingTask?.cancel()
        pendingJDKHomePath = nil
        // Only when JDK indexing is triggered mid-sync (a Gradle project's language level needing a
        // different installation than the one already indexed) is it meaningful to narrate into
        // *this* sync's console; the independent bootstrap-time index has no sync to narrate into.
        let noteToConsole = gradleSync.isSyncing
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
            if noteToConsole {
                gradleConsole.appendNote(message)
            }
            for await progress in await scheduler.index([(root: root, shardURL: shardURL)]) {
                guard noteToConsole, !Task.isCancelled else { continue }
                switch progress {
                case .rootFinished(let id, let classCount):
                    gradleConsole.appendNote("Indexed \(Self.shortRootName(id)) (\(classCount) classes)")
                case .rootSkipped(let id, let reason):
                    gradleConsole.appendNote("Skipped \(Self.shortRootName(id)) (\(reason))")
                case .rootFailed(let id, let failureMessage):
                    gradleConsole.appendNote("Failed to index \(Self.shortRootName(id)): \(failureMessage)")
                case .rootStarted, .allFinished:
                    break
                }
            }
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

    /// Short, human-readable form of a `JavaIndexableRoot.id` for the console/status bar -- strips
    /// the `"jar-"`/`"source-"` prefix `JarRoot`/`SourceRoot` use for shard-naming and keys, and
    /// collapses the remaining path to its last component instead of showing a full filesystem path.
    private static func shortRootName(_ id: String) -> String {
        for prefix in ["jar-", "source-"] where id.hasPrefix(prefix) {
            return (String(id.dropFirst(prefix.count)) as NSString).lastPathComponent
        }
        return id
    }

    private func publishSources() async {
        var sources: [JavaIndex.Source] = []
        if let jdkReader { sources.append(.init(precedence: 3, reader: jdkReader)) }
        sources.append(contentsOf: projectSources)
        sources.append(contentsOf: jarSources)
        await javaIndex.setSources(sources)
        if let indexedJDKHomePath {
            await navigationProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await findUsagesProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await hoverProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await hierarchyProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await renameProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await refactoringProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
        }
    }

    private func clearSourceSetClasspath() {
        Task {
            await completionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await navigationProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await findUsagesProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await codeActionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await hoverProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await hierarchyProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await inlayHintProvider.setSourceSetClasspath(nil, indexPaths: paths)
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
