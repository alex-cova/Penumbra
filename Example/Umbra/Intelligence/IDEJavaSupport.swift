import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation

/// Why open files get live `javac` errors right now, or nothing when they do not.
enum JavaCompilerState: Sendable {
    /// The compiler service is pointed at the project and checks open files.
    case ready
    /// The user turned compiler diagnostics off in Settings.
    case disabled
    /// A Gradle or Maven project with no model yet: the first sync has not finished.
    case waitingForModel
    /// No installed JDK ships a `javac`.
    case noJDK
}

/// Owns Java code intelligence for the workspace: the shared `JavaIndex` (JDK + open project's
/// source tree + Gradle-resolved dependencies), the `JavaOverlayService` keeping it in sync with
/// open/edited documents, and the background indexing that populates it.
/// `IDEIntelligenceServices` holds one instance and feeds its index into `JavaCompletionProvider`;
/// `IDEWorkspace` drives it (connect on bootstrap, retarget through the language registry's
/// `projectDidChange`).
///
/// The Java build model is not here: `IDEGradleProjectSystem` or `IDEMavenProjectSystem` produces it
/// and hands every model to this class (`IDEJavaModelConsumer`), which indexes it. Gradle wins when
/// both markers are present. The JDK choice is `IDEJDKSelection`, shared with both.
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
    /// Callers and callees for the Call Hierarchy tab.
    let callHierarchyProvider: JavaCallHierarchyProvider
    /// Static inspections (unused imports, missing @Override, unresolved types).
    let inspectionService: JavaInspectionService
    /// Classifies Java identifiers for semantic highlighting.
    let semanticTokenProvider: JavaSemanticTokenProvider
    /// Parameter-name hints at call sites (the Parameter Name Hints preference).
    let inlayHintProvider: JavaInlayHintProvider
    let codeVisionProvider: JavaCodeVisionProvider
    /// Override, implementation and recursion icons in the gutter (the Gutter Icons preferences).
    let lineMarkerProvider: JavaLineMarkerProvider
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
    /// Structure tool window: the type at the caret and its members.
    let structureProvider = JavaStructureProvider()
    /// `javac`-backed diagnostics for open Java files. Idle until ``refreshCompilerDiagnostics()``
    /// finds a project state it may check: a plain folder, or a Gradle project that has synced.
    let compilerDiagnostics = JavaCompilerDiagnosticsService()
    /// Last-build diagnostics for open Java files. A finished Gradle or Maven run publishes here
    /// (the same rows it lists in Problems), so a compile also paints squiggles and the error
    /// stripe instead of leaving the editor clean.
    let buildDiagnostics = JavaBuildDiagnosticsService()
    /// Why open files get live `javac` errors right now, or nothing when they do not. The
    /// inspection widget reads this instead of showing a clean check mark for a file `javac`
    /// never checked.
    var compilerState: JavaCompilerState = .waitingForModel

    /// Which JDK the project uses (its own choice, the default, or Automatic) and the list to choose
    /// from. Everything that needs a JDK asks it.
    let jdk: IDEJDKSelection
    /// The Gradle project whose model this indexes. When it is active, it wins over Maven.
    let gradle: IDEGradleProjectSystem
    /// The Maven project whose model this indexes when the folder is not a Gradle project.
    let maven: IDEMavenProjectSystem

    /// The Java build that owns the open folder: Gradle when it is one, otherwise Maven.
    var buildSystem: (any IDEProjectSystem)? {
        if gradle.isActive { return gradle }
        if maven.isActive { return maven }
        return nil
    }

    /// The model indexing, completion and `javac` read. Gradle's own model when Gradle is active,
    /// otherwise Maven's projection of the same shape.
    var projectModel: JavaGradleProjectModel? {
        if gradle.isActive { return gradle.model }
        if maven.isActive { return maven.model?.javaProjectModel }
        return nil
    }

    var isJavaBuildActive: Bool { gradle.isActive || maven.isActive }

    /// A model is about to replace the whole-tree index, so that index can wait.
    var isLoadingJavaModel: Bool { gradle.isLoadingCachedModel || maven.isLoadingModel }

    /// A synced Gradle or Maven model has already replaced the whole-tree readers.
    var hasSyncedJavaModel: Bool {
        if case .synced = gradle.syncState { return true }
        if case .synced = maven.syncState { return true }
        return false
    }

    private let status: IDEProjectStatus
    /// Which indexes are building, for the agent. The toast above is not an index signal.
    let activity: IDEIndexActivity
    private let paths = JavaIndexPaths.default()
    /// Where extracted sources and library resources are copied so the editor can open them.
    var indexCacheRoot: URL { paths.root }
    private let scheduler = JavaIndexScheduler()
    /// One indexing run and one parsed shard per JDK for the whole app; see `JavaSharedShardHub`.
    private let shardHub: JavaSharedShardHub
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
    /// Bumped on every `projectDidChange` so an in-flight index for the previous folder cannot
    /// publish over the new one. Distinct from `Task.isCancelled`: a reload of the *same* root
    /// cancels the previous task without changing the generation.
    @ObservationIgnored private var projectGeneration = 0
    /// Home of the JDK currently being indexed, if a select has already happened and the shard
    /// write hasn't finished. Compared so a repeat sync doesn't cancel an in-flight index of the
    /// same installation.
    @ObservationIgnored private var pendingJDKHomePath: String?
    /// Home of the JDK whose reader is installed.
    @ObservationIgnored private var indexedJDKHomePath: String?
    @ObservationIgnored private var projectRootURL: URL?

    /// Called with each finished compile's diagnostics for one file (empty when it is clean).
    @ObservationIgnored var onCompilerDiagnostics: (@MainActor (URL, [Diagnostic]) -> Void)?
    @ObservationIgnored var onInspectionDiagnostics: (@MainActor (URL, [Diagnostic]) -> Void)?
    /// Called once the compiler is (re)configured, so the host can check the files already open.
    @ObservationIgnored var onCompilerConfigured: (@MainActor () -> Void)?
    /// Called after the index's sources change (project indexed, sync finished, files re-indexed
    /// after changing on disk), so results that depend on other files can be refreshed.
    @ObservationIgnored var onIndexSourcesPublished: (@MainActor () -> Void)?
    /// Called once the inspection service has taken a changed rule set or severity, so the open
    /// files can be analysed again without waiting for an edit.
    @ObservationIgnored var onInspectionConfigurationChanged: (@MainActor () -> Void)?
    private var appliedInspectionConfiguration: InspectionConfiguration?
    /// The Java language level of a file: its Gradle module's, else the selected JDK's. Handed to
    /// the inspection service and to batch runs so the rules that suggest newer syntax know what
    /// the project may use.
    @ObservationIgnored private(set) var inspectionLanguageLevel: @Sendable (URL) -> Int? = { _ in nil }
    @ObservationIgnored private var languageLevelKey = ""

    private struct InspectionConfiguration: Equatable {
        let profile: JavaInspectionProfile
        let projectRoot: URL?
        let testRoots: [URL]
    }
    @ObservationIgnored private var compilerConfigurationTask: Task<Void, Never>?

    /// The JDK shard hub is the app's shared one by default, so every window indexes the JDK once.
    init(
        jdk: IDEJDKSelection,
        gradle: IDEGradleProjectSystem,
        maven: IDEMavenProjectSystem,
        status: IDEProjectStatus,
        activity: IDEIndexActivity = IDEIndexActivity(),
        shardHub: JavaSharedShardHub = IDESharedServices.shared.shards
    ) {
        self.activity = activity
        self.shardHub = shardHub
        self.jdk = jdk
        self.gradle = gradle
        self.maven = maven
        self.status = status
        let sharedParseCache = JavaDocumentParseCache()
        overlayService = JavaOverlayService(index: javaIndex, parseCache: sharedParseCache)
        let completionProvider = JavaCompletionProvider(index: javaIndex)
        self.completionProvider = completionProvider
        let initialPostfix = IDEPreferences.shared.javaPostfix
        Task { await completionProvider.setPostfixConfiguration(initialPostfix) }
        navigationProvider = JavaGoToDefinitionProvider(index: javaIndex, indexPaths: paths)
        findUsagesProvider = JavaFindUsagesProvider(index: javaIndex, indexPaths: paths, nameIndex: nameIndex)
        codeActionProvider = JavaCodeActionProvider(index: javaIndex)
        let intentionsCache = sharedParseCache
        Task { [codeActionProvider] in
            await codeActionProvider.setParseCache(intentionsCache)
            await codeActionProvider.setIntentionOptionsSource { IDEPreferences.currentJavaIntentionOptions() }
        }
        hoverProvider = JavaHoverProvider(index: javaIndex, indexPaths: paths)
        hierarchyProvider = JavaTypeHierarchyProvider(index: javaIndex, indexPaths: paths)
        callHierarchyProvider = JavaCallHierarchyProvider(index: javaIndex, indexPaths: paths, findUsages: findUsagesProvider)
        inspectionService = JavaInspectionService(index: javaIndex, parseCache: sharedParseCache, usageProvider: findUsagesProvider)
        semanticTokenProvider = JavaSemanticTokenProvider(index: javaIndex)
        let inlayHintProvider = JavaInlayHintProvider(index: javaIndex, indexPaths: paths)
        self.inlayHintProvider = inlayHintProvider
        Task { await inlayHintProvider.setOptionsSource { IDEPreferences.currentJavaInlayHintOptions() } }
        let codeVisionProvider = JavaCodeVisionProvider(index: javaIndex, indexPaths: paths, findUsages: findUsagesProvider)
        self.codeVisionProvider = codeVisionProvider
        Task { await codeVisionProvider.setOptionsSource { IDEPreferences.currentJavaCodeVisionOptions() } }
        lineMarkerProvider = JavaLineMarkerProvider(index: javaIndex, indexPaths: paths)
        let renameCandidates = JavaIndexedOrScanningCandidates(nameIndex: nameIndex, scan: JavaTextScanCandidateSource())
        renameProvider = JavaRenameProvider(index: javaIndex, indexPaths: paths, candidates: renameCandidates)
        refactoringProvider = JavaRefactoringProvider(index: javaIndex, indexPaths: paths, candidates: renameCandidates)
        gradle.consumer = self
        maven.consumer = self
        maven.onNeedsWholeTreeIndex = { [weak self] in
            guard let self, let root = self.projectRootURL else { return }
            self.indexWholeTree(at: root, generation: self.projectGeneration)
        }
        jdk.languageLevel = { [weak self] in self?.projectModel?.maxLanguageLevel }
        jdk.onSelectionChanged = { [weak self] in self?.jdkSelectionChanged() }
        Task { [weak self] in await self?.installCompilerResultHandler() }
        Task { [weak self] in await self?.installInspectionResultHandler() }
        Task { [overlayService, testIndex] in
            await overlayService.setOnDocumentIndexed { _, url, text in
                await testIndex.scheduleRescan(file: url, source: text)
            }
        }
    }

    /// Java as one language service for the router (`LanguageServiceRegistry`): these providers, in
    /// the order each engine asks them, and Java's opt-outs from the generic name-based features. It
    /// also receives the window's project and file changes (`IDEJavaLanguageService`).
    var languageService: IDEJavaLanguageService {
        IDEJavaLanguageService(
            base: JavaLanguageService(
                completion: completionProvider,
                hover: hoverProvider,
                compilerDiagnostics: compilerDiagnostics,
                inspections: inspectionService,
                buildDiagnostics: buildDiagnostics,
                navigation: navigationProvider,
                findUsages: findUsagesProvider,
                formatting: formattingProvider,
                codeActions: codeActionProvider,
                rename: renameProvider,
                refactoring: refactoringProvider,
                breadcrumbs: breadcrumbProvider,
                inlayHints: inlayHintProvider,
                codeVision: codeVisionProvider,
                semanticTokens: semanticTokenProvider,
                lineMarkers: lineMarkerProvider,
                structure: structureProvider,
                typeHierarchy: hierarchyProvider,
                callHierarchy: callHierarchyProvider,
                symbolReference: JavaSymbolReferenceProvider(index: javaIndex)
            ),
            support: self
        )
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

    private func installInspectionResultHandler() async {
        await inspectionService.setResultHandler { [weak self] url, diagnostics in
            Task { @MainActor in self?.onInspectionDiagnostics?(url, diagnostics) }
        }
    }

    /// Scratch space for `javac` buffer copies, under the app's Caches directory.
    static var compilerWorkDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("javac", isDirectory: true)
    }

    /// Applies the code-insight settings the Java services own: which inspection profile applies
    /// (with the project root and test source directories its per-scope exceptions are judged
    /// against), the `javac` idle wait, and what a Suppress quick fix writes. Inspections
    /// run on every refreshed document with no extra wait: the adapter's content debounce
    /// (`autoreparseDelay`, applied to `contentRefreshDebounce` by the workspace) is the only
    /// Autoreparse Delay. The cold CLI `javac` keeps `autoreparseDelay` as its wait because a
    /// cold compile costs seconds.
    func applyCodeInsightPreferences(
        autoreparseDelay: Duration,
        suppressionStyle: JavaSuppressionStyle,
        inspectionProfile: JavaInspectionProfile,
        projectRoot: URL?,
        testRoots: [URL],
        importPolicy: JavaImportPolicy,
        postfix: JavaPostfixConfiguration
    ) {
        let configuration = InspectionConfiguration(profile: inspectionProfile, projectRoot: projectRoot, testRoots: testRoots)
        let previous = appliedInspectionConfiguration
        appliedInspectionConfiguration = configuration
        let changed = previous != configuration
        Task { [inspectionService, compilerDiagnostics, codeActionProvider, completionProvider] in
            await inspectionService.setIdleDelay(.zero)
            await compilerDiagnostics.setIdleDelay(autoreparseDelay)
            await codeActionProvider.setSuppressionStyle(suppressionStyle)
            await codeActionProvider.setImportPolicy(importPolicy)
            await completionProvider.setImportPolicy(importPolicy)
            await completionProvider.setPostfixConfiguration(postfix)
            await codeActionProvider.setQuietFindingsSource { url in await inspectionService.quietFindings(for: url) }
            guard changed else { return }
            await inspectionService.setProfile(inspectionProfile, projectRoot: projectRoot, testRoots: testRoots)
            // The first application only installs the saved settings; there is nothing to refresh.
            if previous != nil { onInspectionConfigurationChanged?() }
        }
    }

    /// Import edits for unresolved types in `source`. `caretUTF16` skips the name the caret is still in.
    func importEdits(in source: String, caretUTF16: Int?, file: URL?, policy: JavaImportPolicy) async -> [TextEdit] {
        await withImportScope(for: file) {
            await JavaAutoImport.edits(in: source, index: self.javaIndex, policy: policy, caretUTF16: caretUTF16)
        }
    }

    /// Import edits for unresolved types that occur in `pasted`, and only those.
    func importEdits(forPastedText pasted: String, in source: String, file: URL?, policy: JavaImportPolicy) async -> [TextEdit] {
        await withImportScope(for: file) {
            await JavaAutoImport.edits(forPastedText: pasted, in: source, index: self.javaIndex, policy: policy)
        }
    }

    private func withImportScope<T: Sendable>(for file: URL?, _ body: () async -> T) async -> T {
        guard let file, let model = projectModel else { return await body() }
        let scope = model.visibleShardPaths(forFile: file, paths: paths)
        return await JavaIndex.$queryScope.withValue(scope) {
            await body()
        }
    }

    /// Reads the project's language levels and the JDK's feature version again (a sync finished or
    /// the JDK changed) and tells the inspections; open files are analysed again when it changed.
    func refreshInspectionLanguageLevel() {
        let model = projectModel
        Task { [weak self] in
            guard let self else { return }
            let fallback = await self.jdk.resolve(minimumFeatureVersion: nil)?.installation.featureVersion
            let levels = (model?.subprojects ?? []).map { "\($0.path)=\($0.languageLevel ?? 0)" }.joined(separator: ",")
            let key = "\(fallback ?? 0)|\(levels)"
            let resolver: @Sendable (URL) -> Int? = { url in model?.languageLevel(forFile: url) ?? fallback }
            self.inspectionLanguageLevel = resolver
            await self.inspectionService.setLanguageLevelResolver(resolver)
            guard key != self.languageLevelKey else { return }
            let isFirst = self.languageLevelKey.isEmpty
            self.languageLevelKey = key
            if !isFirst { self.onInspectionConfigurationChanged?() }
        }
    }

    /// A batch runner (Inspect Code, Run Inspection by Name, the commit check) over this window's
    /// index, with each file seeing the shards of its Gradle source set.
    func makeBatchInspector() -> JavaBatchInspector {
        let model = projectModel
        let paths = paths
        return JavaBatchInspector(
            index: javaIndex, usageProvider: findUsagesProvider,
            queryScope: { url in
                guard let model else { return nil }
                return model.visibleShardPaths(forFile: url, paths: paths)
            },
            languageLevel: inspectionLanguageLevel
        )
    }

    /// Analyses `documents` again with the current inspection settings.
    func reanalyzeInspections(_ documents: [EditorIntelligence.Document]) {
        Task { [inspectionService] in
            for document in documents {
                await inspectionService.analyzeNow(document, force: true)
                await inspectionService.runProjectInspections(for: document)
            }
        }
    }

    /// Points the compiler at the current project, or turns it off. Nothing is checked in a Gradle
    /// project until its sync has produced a model (which needs the trust prompt), nor when the
    /// user has turned the preference off, nor when no installed JDK ships a `javac`.
    func refreshCompilerDiagnostics() {
        refreshInspectionLanguageLevel()
        compilerConfigurationTask?.cancel()
        let generation = projectGeneration
        let root = projectRootURL
        let model = projectModel
        let waitingOnGradle = isJavaBuildActive && model == nil
        let enabled = IDEPreferences.shared.javaCompilerDiagnostics
        compilerConfigurationTask = Task { [compilerDiagnostics, self] in
            // Every open Java buffer shadows the disk in a server check; the checked file itself
            // is never duplicated into the overlays. Same file in two panes is one overlay.
            // The provider outlives this task, so it holds the window weakly.
            await compilerDiagnostics.setOpenBufferProvider { [weak self] in
                await MainActor.run {
                    guard let documents = self?.openJavaDocuments?() else { return [:] }
                    return Dictionary(documents.compactMap { document in
                        guard let url = document.url, document.languageIdentifier == "java" else { return nil }
                        return (url, document.text)
                    }, uniquingKeysWith: { first, _ in first })
                }
            }
            guard enabled else {
                await compilerDiagnostics.configure(nil)
                await compilerDiagnostics.setServerBackend(nil)
                guard isCurrent(generation), !Task.isCancelled else { return }
                compilerState = .disabled
                onCompilerConfigured?()
                return
            }
            guard !waitingOnGradle else {
                await compilerDiagnostics.configure(nil)
                await compilerDiagnostics.setServerBackend(nil)
                guard isCurrent(generation), !Task.isCancelled else { return }
                compilerState = .waitingForModel
                onCompilerConfigured?()
                return
            }
            let jdk = await self.jdk.resolve(minimumFeatureVersion: model?.maxLanguageLevel)?.installation
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard let jdk, jdk.javac != nil else {
                await compilerDiagnostics.configure(nil)
                await compilerDiagnostics.setServerBackend(nil)
                compilerState = .noJDK
                return
            }
            await compilerDiagnostics.configure(.init(
                kind: model.map { .gradle($0) } ?? .plainFolder,
                jdk: jdk,
                projectRoot: root ?? FileManager.default.temporaryDirectory,
                workDirectory: Self.compilerWorkDirectory
            ))
            // The warm path, when the project JDK can run the server (class version 61): one
            // server per JDK home, shared across windows. Older JDKs stay on the cold CLI.
            if jdk.featureVersion >= 17, let jar = Self.analysisServerJarURL() {
                let client = await JavaAnalysisServerHub.shared.client(jarURL: jar, javaHome: jdk.home)
                await compilerDiagnostics.setServerBackend(.init(client: client))
            } else {
                await compilerDiagnostics.setServerBackend(nil)
            }
            guard isCurrent(generation), !Task.isCancelled else { return }
            compilerState = .ready
            onCompilerConfigured?()
        }
    }

    /// The bundled `java-analysis-server.jar`, falling back to the repo-built one in development.
    static func analysisServerJarURL() -> URL? {
        let bundled = Bundle.main.url(forResource: "java-analysis-server", withExtension: "jar")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let dev = IDEDevelopmentPaths.sourceRoot.appendingPathComponent("Tools/JavaAnalysisServer/build/java-analysis-server.jar")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// The window's open Java documents, read when a save asks for a fresh compile. The closure
    /// does not retain the window.
    var openJavaDocuments: (@MainActor () -> [EditorIntelligence.Document])?

    /// Checks `documents` now instead of waiting for the editor to go idle -- after a save, or once
    /// the compiler is configured. `force` rechecks files whose own text did not change.
    func compileNow(_ documents: [EditorIntelligence.Document], force: Bool = false) {
        Task { [compilerDiagnostics, inspectionService] in
            for document in documents {
                await compilerDiagnostics.compileNow(document, force: force)
                await inspectionService.analyzeNow(document, force: force)
                await inspectionService.runProjectInspections(for: document)
            }
        }
    }

    /// Connects the overlay service to the shared workspace (mirrors
    /// `IndexingService.connect(to:)`) and kicks off JDK indexing in the background, unless a
    /// Gradle sync has already selected one. Call once, from `IDEWorkspace.bootstrap()`.
    @discardableResult
    func connect(to workspace: Workspace) async -> Task<Void, Never> {
        let task = await overlayService.connect(to: workspace)
        Task {
            await jdk.refreshDetected()
            await jdk.refreshCurrent()
        }
        if jdkIndexingTask == nil && indexedJDKHomePath == nil {
            indexJDK(minimumFeatureVersion: nil)
        }
        return task
    }

    /// Re-targets project-source indexing at a new folder (or clears it when `url` is `nil`, e.g.
    /// the user closes the folder). Safe to call repeatedly; a new call cancels any indexing still
    /// in flight for the previous root. Runs after the project systems have seen the folder: in a
    /// Gradle project the whole-tree index below is only the stand-in until its sync has produced
    /// per-module sources (and is skipped when a cached model is applied straight away).
    func projectDidChange(root url: URL?) {
        projectGeneration += 1
        let generation = projectGeneration
        jdk.setProjectRoot(url)
        Task {
            await jdk.refreshCurrent()
            guard isCurrent(generation) else { return }
            await adoptResolvedJDKIfNeeded(minimumFeatureVersion: nil, generation: generation)
        }
        projectIndexingTask?.cancel()
        stubRefreshTask?.cancel()
        stubRefreshTask = nil
        pendingStubRefresh = []
        projectRootURL = url
        clearTestIndex()
        let hadJars = !jarSources.isEmpty
        jarSources = []
        clearSourceSetClasspath()

        guard let url else {
            buildNameIndex(roots: [], generation: generation)
            projectSources = []
            Task { await publishSources() }
            refreshCompilerDiagnostics()
            return
        }

        guard isJavaBuildActive else {
            indexWholeTree(at: url, generation: generation)
            if hadJars {
                Task { await publishSources() }
            }
            refreshCompilerDiagnostics()
            return
        }

        // Off until a sync produces a model: a failed or declined sync must not flood files with
        // false "cannot find symbol" errors. Maven's read is free and arrives within moments, so
        // the whole tree waits for it; a read that never produces a model indexes the tree then.
        refreshCompilerDiagnostics()
        if hadJars {
            Task { await publishSources() }
        }
        if gradle.isActive {
            if !gradle.isLoadingCachedModel {
                indexWholeTree(at: url, generation: generation)
            }
        } else if !maven.isLoadingModel && maven.model == nil {
            indexWholeTree(at: url, generation: generation)
        }
    }

    /// The window is closing: stop everything this project started, so a closed project leaves no
    /// indexing or `javac` configuration behind. Work still in flight sees a newer generation and
    /// does not publish. The shared stores and the shared JDK shard stay: other windows use them.
    func teardown() {
        projectGeneration += 1
        jdkIndexingTask?.cancel()
        jdkIndexingTask = nil
        projectIndexingTask?.cancel()
        projectIndexingTask = nil
        nameIndexTask?.cancel()
        nameIndexTask = nil
        stubRefreshTask?.cancel()
        stubRefreshTask = nil
        projectRootURL = nil
        // Turns `javac` off for this window and drops its configuration.
        refreshCompilerDiagnostics()
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
        Task { [findUsagesProvider, callHierarchyProvider] in
            await findUsagesProvider.setProjectRoots(searchRoots)
            await callHierarchyProvider.setProjectRoots(searchRoots)
        }
        let renameRoots = nameIndexRoots
        Task { [renameProvider, refactoringProvider] in
            await renameProvider.setRoots(renameRoots)
            await refactoringProvider.setRoots(renameRoots)
        }
        let token = activity.begin(.javaUsages)
        nameIndexTask = Task { [nameIndex, activity] in
            defer { activity.end(token) }
            for await _ in await nameIndex.build(roots: roots) {
                guard isCurrent(generation) else { return }
            }
        }
    }

    /// Applies a root delta to the name index: unchanged roots keep their loaded shards.
    private func updateNameIndex(plan: JavaGradleProjectModel.ApplyPlan, generation: Int) {
        nameIndexTask?.cancel()
        nameIndexRoots = plan.nameRoots.map(\.standardizedFileURL)
        let searchRoots = nameIndexRoots
        Task { [findUsagesProvider, callHierarchyProvider] in
            await findUsagesProvider.setProjectRoots(searchRoots)
            await callHierarchyProvider.setProjectRoots(searchRoots)
        }
        let renameRoots = nameIndexRoots
        Task { [renameProvider, refactoringProvider] in
            await renameProvider.setRoots(renameRoots)
            await refactoringProvider.setRoots(renameRoots)
        }
        let adding = plan.addedNameRoots
        let removing = plan.removedNameRoots
        let token = activity.begin(.javaUsages)
        nameIndexTask = Task { [nameIndex, activity] in
            defer { activity.end(token) }
            for await _ in await nameIndex.updateRoots(adding: adding, removing: removing) {
                guard isCurrent(generation) else { return }
            }
        }
    }

    /// `.java` files changed on disk (from `IDEProjectWatcher`): update the identifier index for
    /// them and rebuild the stub shard of every source root that changed, bypassing the
    /// directory-mtime stamp (which does not move when a file is merely edited).
    func filesDidChange(_ changed: [URL]) {
        guard projectRootURL != nil, !nameIndexRoots.isEmpty else { return }
        // Extension-less paths may be directories that were added, removed or renamed.
        let urls = changed.filter { $0.pathExtension == "java" || $0.pathExtension.isEmpty }
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
                let isSynced = hasSyncedJavaModel
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

    private static let indexingSourcesMessage = "Indexing project sources…"

    private func indexWholeTree(at url: URL, generation: Int) {
        buildNameIndex(roots: [url], generation: generation)
        let token = activity.begin(.javaSources)
        projectIndexingTask = Task { [paths, scheduler, activity] in
            defer { activity.end(token) }
            let root = SourceRoot(directory: url)
            let shardURL = paths.projectSourcesShard(for: url)
            if isCurrent(generation), status.message == nil {
                status.set(Self.indexingSourcesMessage)
            }
            for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
            guard isCurrent(generation) else { return }
            // A finished Gradle sync has already replaced these readers with per-module sources.
            if hasSyncedJavaModel {
                status.clear(Self.indexingSourcesMessage)
                return
            }
            if let reader = try? JavaIndexShardReader(url: shardURL) {
                // No shard path: this whole-tree fallback is only published while completion is
                // unscoped. A finished sync replaces it with per-source-set readers.
                projectSources = [.init(precedence: 1, reader: reader)]
            }
            status.clear(Self.indexingSourcesMessage)
            await publishSources()
        }
    }

    // MARK: - The Gradle model

    private func applyGradleModel(
        _ model: JavaGradleProjectModel,
        previousModel: JavaGradleProjectModel?,
        generation: Int,
        logToConsole: Bool
    ) async {
        // Sources and dependencies count as building until this model's readers are published.
        let sourcesToken = activity.begin(.javaSources)
        var dependenciesToken: IDEIndexActivity.Token?
        defer {
            activity.end(sourcesToken)
            if let dependenciesToken { activity.end(dependenciesToken) }
        }
        await adoptLanguageLevelIfNeeded(model.maxLanguageLevel, generation: generation)
        guard isCurrent(generation) else { return }

        let diff = JavaGradleProjectModel.diff(old: previousModel, new: model)
        let sourceTargets = model.sourceIndexTargets(paths: paths)
        let jarTargets = model.jarIndexTargets(paths: paths)
        if !jarTargets.isEmpty { dependenciesToken = activity.begin(.javaDependencies) }
        let shouldFullRebuild = previousModel == nil
            || diff.shouldForceFullRebuild(totalSourceRoots: sourceTargets.count, totalJars: jarTargets.count)

        let nameIndexPlan = JavaGradleProjectModel.applyPlan(
            for: model,
            paths: paths,
            loadedShardPaths: shouldFullRebuild ? [] : Set((projectSources + jarSources).map(\.shardPath).filter { !$0.isEmpty }),
            loadedNameRoots: shouldFullRebuild ? [] : Set(nameIndexRoots.map(\.path))
        )
        if shouldFullRebuild {
            buildNameIndex(roots: nameIndexPlan.nameRoots, generation: generation)
            await indexAllTargets(sourceTargets + jarTargets, model: model, generation: generation, logToConsole: logToConsole)
        } else if !diff.isEmpty {
            updateNameIndex(plan: nameIndexPlan, generation: generation)
            for directory in diff.removedSourceDirectories {
                try? FileManager.default.removeItem(at: paths.projectSourcesShard(for: directory))
            }
            for jar in diff.removedJars {
                try? FileManager.default.removeItem(at: paths.jarShard(jar))
                await shardHub.invalidate(paths.jarShard(jar))
            }
            let reindexDirs = diff.addedSourceDirectories + diff.changedSourceDirectories
            let reindexSources = reindexDirs.map { directory in
                (SourceRoot(directory: directory) as any JavaIndexableRoot, paths.projectSourcesShard(for: directory))
            }
            let reindexJars = diff.addedJars.map { jar in
                (JarRoot(jarURL: jar, languageLevel: model.maxLanguageLevel ?? Int.max) as any JavaIndexableRoot, paths.jarShard(jar))
            }
            // `indexAllTargets` publishes readers for every model target, not just the reindexed ones.
            await indexAllTargets(reindexSources + reindexJars, model: model, generation: generation, logToConsole: logToConsole)
        } else {
            updateNameIndex(plan: nameIndexPlan, generation: generation)
        }

        guard isCurrent(generation) else { return }
        if status.message?.hasPrefix("Indexing dependencies…") == true {
            status.message = nil
        }
        await publishSources()
        await completionProvider.setSourceSetClasspath(model, indexPaths: paths)
        await navigationProvider.setSourceSetClasspath(model, indexPaths: paths)
        await findUsagesProvider.setSourceSetClasspath(model, indexPaths: paths)
        await codeActionProvider.setSourceSetClasspath(model, indexPaths: paths)
        await hoverProvider.setSourceSetClasspath(model, indexPaths: paths)
        await hierarchyProvider.setSourceSetClasspath(model, indexPaths: paths)
        await callHierarchyProvider.setSourceSetClasspath(model, indexPaths: paths)
        await inlayHintProvider.setSourceSetClasspath(model, indexPaths: paths)
        await codeVisionProvider.setSourceSetClasspath(model, indexPaths: paths)
        await lineMarkerProvider.setSourceSetClasspath(model, indexPaths: paths)
        await inspectionService.setSourceSetClasspath(model, indexPaths: paths)
        reindexTests(model: model)
        refreshCompilerDiagnostics()
    }

    private func indexAllTargets(
        _ targets: [(root: any JavaIndexableRoot, shardURL: URL)],
        model: JavaGradleProjectModel,
        generation: Int,
        logToConsole: Bool
    ) async {
        let totalTargets = targets.count
        if logToConsole {
            appendBuildNote("Indexing \(model.classpathJars.count) dependencies…")
        }
        var completedTargets = 0
        // A dependency-heavy project reports two events per JAR, sometimes hundreds a second.
        // Every write to the Gradle console / status message re-renders their views, so collect
        // them and publish at most every 100 ms.
        var pendingNotes: [String] = []
        var pendingStatus: String?
        var lastFlush = ContinuousClock.now
        func flush() {
            appendBuildNotes(pendingNotes)
            pendingNotes.removeAll(keepingCapacity: true)
            if let message = pendingStatus {
                status.message = message
                pendingStatus = nil
            }
            lastFlush = .now
        }
        func handle(_ progress: JavaIndexScheduler.Progress) {
            switch progress {
            case .allFinished:
                return
            case .rootStarted(let id):
                if logToConsole {
                    pendingNotes.append("Indexing \(Self.shortRootName(id))…")
                }
                if logToConsole, totalTargets > 0 {
                    pendingStatus = "Indexing dependencies… (\(completedTargets)/\(totalTargets)): \(Self.shortRootName(id))"
                }
            case .rootSkipped(let id, let reason):
                completedTargets += 1
                if logToConsole {
                    pendingNotes.append("Skipped \(Self.shortRootName(id)) (\(reason))")
                }
            case .rootFinished(let id, let classCount):
                completedTargets += 1
                if logToConsole {
                    pendingNotes.append("Indexed \(Self.shortRootName(id)) (\(classCount) classes)")
                }
            case .rootFailed(let id, let message):
                completedTargets += 1
                if logToConsole {
                    pendingNotes.append("Failed to index \(Self.shortRootName(id)): \(message)")
                }
            }
            if logToConsole, totalTargets > 0, !progress.isRootStarted {
                pendingStatus = "Indexing dependencies… (\(completedTargets)/\(totalTargets))"
            }
            if ContinuousClock.now - lastFlush >= .milliseconds(100) {
                flush()
            }
        }
        // Project sources are this window's own. Dependency jars go through the shared hub: one
        // indexing run per jar across windows, and the same parsed reader for all of them.
        let projectTargets = targets.filter { !($0.root is JarRoot) }
        let jarTargets = targets.filter { $0.root is JarRoot }
        for await progress in await scheduler.index(projectTargets) {
            guard isCurrent(generation) else { return }
            handle(progress)
        }
        for await progress in await shardHub.indexJars(jarTargets) {
            guard isCurrent(generation) else { return }
            handle(progress)
        }
        guard isCurrent(generation) else { return }
        flush()

        // Opening a shard decodes its whole string table. Project shards are opened here, off the
        // main actor; jar readers come from the hub, which parses only the ones no window (or
        // earlier sync) already holds.
        let paths = paths
        let modelJarTargets = model.jarIndexTargets(paths: paths)
        async let projectReaders = Task.detached(priority: .userInitiated) {
            model.sourceIndexTargets(paths: paths).compactMap { target -> JavaIndex.Source? in
                guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
            }
        }.value
        let jarReaders = await shardHub.readers(for: modelJarTargets)
        let loaded = (
            await projectReaders,
            modelJarTargets.compactMap { target -> JavaIndex.Source? in
                jarReaders[target.shardURL].map {
                    JavaIndex.Source(precedence: 2, reader: $0, shardPath: target.shardURL.path)
                }
            }
        )
        guard isCurrent(generation) else { return }
        projectSources = loaded.0
        jarSources = loaded.1
    }

    /// After a build, annotation processors may have written (or rewritten) sources under the
    /// model's generated directories. A root's stamp is its directory's own mtime, which misses
    /// nested changes, so the generated shards are dropped and rebuilt.
    func reindexGeneratedSources() {
        guard let model = projectModel else { return }
        let generation = projectGeneration
        Task { [paths, scheduler] in
            let all = model.sourceIndexTargets(paths: paths)
            let generated = all.filter { ($0.root as? SourceRoot)?.isGenerated == true }
            guard !generated.isEmpty else { return }
            for target in generated { try? FileManager.default.removeItem(at: target.shardURL) }
            for await _ in await scheduler.index(generated) {}
            let sources = await Task.detached(priority: .userInitiated) {
                all.compactMap { target -> JavaIndex.Source? in
                    guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { return nil }
                    return JavaIndex.Source(precedence: 1, reader: reader, shardPath: target.shardURL.path)
                }
            }.value
            guard isCurrent(generation) else { return }
            projectSources = sources
            await publishSources()
        }
    }

    /// Re-indexes the JDK only when the JDK now in effect (the project's choice, or the one its
    /// language level selects) is a different installation than the one already indexed (or in
    /// flight).
    private func adoptLanguageLevelIfNeeded(_ maxLevel: Int?, generation: Int) async {
        await jdk.refreshCurrent()
        guard isCurrent(generation) else { return }
        guard maxLevel != nil || jdk.current?.source != .automatic else { return }
        await adoptResolvedJDKIfNeeded(minimumFeatureVersion: maxLevel, generation: generation)
    }

    private func adoptResolvedJDKIfNeeded(minimumFeatureVersion: Int?, generation: Int) async {
        let resolution = await jdk.resolve(minimumFeatureVersion: minimumFeatureVersion)
        guard isCurrent(generation) else { return }
        guard let selectedPath = resolution?.installation.home.resolvingSymlinksInPath().path,
              selectedPath != (pendingJDKHomePath ?? indexedJDKHomePath) else { return }
        indexJDK(minimumFeatureVersion: minimumFeatureVersion)
    }

    /// The user chose another JDK (or removed the one in use): re-index against it, re-check open
    /// files with its `javac`, and let the Gradle project re-sync when Gradle would launch on a
    /// different JDK.
    private func jdkSelectionChanged() {
        let generation = projectGeneration
        let level = projectModel?.maxLanguageLevel
        Task {
            await jdk.refreshCurrent()
            guard isCurrent(generation) else { return }
            await adoptResolvedJDKIfNeeded(minimumFeatureVersion: level, generation: generation)
            guard isCurrent(generation) else { return }
            refreshCompilerDiagnostics()
            await gradle.jdkSelectionChanged()
            await maven.jdkSelectionChanged()
        }
    }

    private func appendBuildNote(_ text: String) {
        if gradle.isActive { gradle.appendConsoleNote(text) }
        else if maven.isActive { maven.appendConsoleNote(text) }
    }

    private func appendBuildNotes(_ notes: [String]) {
        if gradle.isActive { gradle.appendConsoleNotes(notes) }
        else if maven.isActive { maven.appendConsoleNotes(notes) }
    }

    private func indexJDK(minimumFeatureVersion: Int?) {
        jdkIndexingTask?.cancel()
        pendingJDKHomePath = nil
        // Only when JDK indexing is triggered mid-sync (a Gradle project's language level needing a
        // different installation than the one already indexed) is it meaningful to narrate into
        // *this* sync's console; the independent bootstrap-time index has no sync to narrate into.
        let noteToConsole = gradle.syncState.isSyncing || maven.syncState.isSyncing
        jdkIndexingTask = Task { [paths, shardHub] in
            // Resolving does synchronous filesystem/process work (java_home -X, walking
            // ~/Library/Java/JavaVirtualMachines); `IDEJDKSelection` hops it off the main actor so
            // it can't stall the UI during app launch.
            let installation = await jdk.resolve(minimumFeatureVersion: minimumFeatureVersion)?.installation
            guard !Task.isCancelled else { return }
            guard let installation else {
                return
            }
            let homePath = installation.home.resolvingSymlinksInPath().path
            pendingJDKHomePath = homePath
            // Opens ct.sym's directory, so off the main actor.
            let (root, kind) = await Task.detached(priority: .utility) { JDKIndexRoot.make(for: installation) }.value
            guard !Task.isCancelled else { return }
            let shardURL = paths.jdkShard(installation, kind: kind)
            let message = "Indexing JDK \(installation.featureVersion)…"
            if status.message == nil {
                status.set(message)
            }
            if noteToConsole {
                appendBuildNote(message)
            }
            // Shared with every other window: one indexing run and one parsed shard per JDK. Only
            // the window that starts the run hears its progress.
            let reader = await shardHub.shard(for: root, at: shardURL) { [weak self = self] progress in
                guard let self, noteToConsole, !Task.isCancelled else { return }
                switch progress {
                case .rootFinished(let id, let classCount):
                    self.appendBuildNote("Indexed \(Self.shortRootName(id)) (\(classCount) classes)")
                case .rootSkipped(let id, let reason):
                    self.appendBuildNote("Skipped \(Self.shortRootName(id)) (\(reason))")
                case .rootFailed(let id, let failureMessage):
                    self.appendBuildNote("Failed to index \(Self.shortRootName(id)): \(failureMessage)")
                case .rootStarted, .allFinished:
                    break
                }
            }
            guard !Task.isCancelled else { return }
            pendingJDKHomePath = nil
            status.clear(message)
            // A JDK that yields no classes must not replace one that works: with no `java.lang`
            // every `String` is unresolved.
            guard let reader, !reader.allQualifiedNames.isEmpty || jdkReader == nil else {
                if noteToConsole {
                    appendBuildNote("JDK \(installation.featureVersion) produced no classes; keeping the JDK already indexed")
                }
                return
            }
            let isReplacement = jdkReader != nil
            jdkReader = reader
            indexedJDKHomePath = homePath
            await publishSources()
            if isReplacement {
                // Results computed against the previous JDK are stale.
                onInspectionConfigurationChanged?()
                refreshCompilerDiagnostics()
            }
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
            await codeVisionProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await hoverProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await hierarchyProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await callHierarchyProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await renameProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
            await refactoringProvider.setJDKHome(URL(fileURLWithPath: indexedJDKHomePath))
        }
        onIndexSourcesPublished?()
    }

    private func clearSourceSetClasspath() {
        Task {
            await completionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await navigationProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await findUsagesProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await codeActionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await hoverProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await hierarchyProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await callHierarchyProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await inlayHintProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await codeVisionProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await lineMarkerProvider.setSourceSetClasspath(nil, indexPaths: paths)
            await inspectionService.setSourceSetClasspath(nil, indexPaths: paths)
        }
    }
}

// MARK: - Gradle model consumer

extension IDEJavaSupport: IDEJavaModelConsumer {
    func javaModelDidChange(_: JavaGradleProjectModel?) {
        // The active build's model, not the argument: a Maven clear while Gradle owns the folder
        // must not wipe Gradle's model.
        let published = projectModel
        Task { [renameProvider, refactoringProvider, testIndex] in
            await renameProvider.setGradleModel(published)
            await refactoringProvider.setGradleModel(published)
            await testIndex.setGradleModel(published)
        }
    }

    func javaModelApplied(_ model: JavaGradleProjectModel, previous: JavaGradleProjectModel?, logToConsole: Bool) async {
        await applyGradleModel(model, previousModel: previous, generation: projectGeneration, logToConsole: logToConsole)
    }

    func javaModelRemoved() {
        clearSourceSetClasspath()
    }

    func buildSucceeded() {
        reindexGeneratedSources()
    }
}

private extension JavaIndexScheduler.Progress {
    var isRootStarted: Bool {
        if case .rootStarted = self {
            return true
        }
        return false
    }
}
