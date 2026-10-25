import Foundation
import JavaIntelligence
import Observation
import SwiftUI

/// How a Maven goal run ended. Every path of ``IDEMavenProjectSystem/runGoals(_:module:extraArguments:completion:)``
/// reports exactly one.
enum IDEMavenRunOutcome: Sendable {
    case finished(GradleCommandResult)
    case timedOut(partial: GradleCommandResult)
    case cancelled(partial: GradleCommandResult?)
    /// Nothing ran: not a Maven project, busy, or the user declined to trust it.
    case notStarted(String)
    case failed(String)
}

extension IDEBottomPanelTab {
    /// The Maven read and goal console.
    static let maven = IDEBottomPanelTab("maven")
}

/// Maven as a project system. Reading `pom.xml` is native and does not run Maven. Goals, tests and
/// dependency downloads run Maven only after the user trusts the folder. A folder that is also a
/// Gradle project is left to Gradle.
@MainActor
@Observable
final class IDEMavenProjectSystem: IDEProjectSystem {
    let id = "maven"
    let displayName = "Maven"
    var consoleTab: IDEBottomPanelTab? { .maven }
    @ObservationIgnored var environment = IDEProjectEnvironment()

    private(set) var syncState: IDEProjectSyncState = .notDetected
    /// The last successful read. A parse error keeps this and reports the line.
    private(set) var model: MavenProjectModel? {
        didSet {
            if oldValue == nil, model == nil { return }
            onModelChanged?(model)
            consumer?.javaModelDidChange(model?.javaProjectModel)
        }
    }
    /// Called whenever a read sets or clears ``model``.
    @ObservationIgnored var onModelChanged: (@MainActor (MavenProjectModel?) -> Void)?
    /// A read failed and left no model, so Java should index the whole tree.
    @ObservationIgnored var onNeedsWholeTreeIndex: (@MainActor () -> Void)?
    /// Maven's own trust question. `environment.requestTrust` is worded for Gradle and is not used.
    @ObservationIgnored var trustPrompt: (@MainActor (URL) async -> Bool)?

    private(set) var console = IDEProjectConsoleLog()
    private(set) var isRunningGoals = false
    private(set) var runningGoals: [String] = []
    /// True while the first read of a folder is in flight and no model has been published.
    @ObservationIgnored private(set) var isLoadingModel = false
    /// How many times a read of the POM succeeded. A same-bytes save does not move it.
    private(set) var readCount = 0

    /// Sidebar toggle. Appends `-DskipTests` to the next goal.
    var skipTests = false
    /// Sidebar toggle. Passes `-o` to the next Maven process.
    var offline = false

    /// Test seams. `nil` reads the preference.
    @ObservationIgnored var autoReadOverride: Bool?
    @ObservationIgnored var downloadDependenciesOverride: Bool?
    /// When false, a goal does not pass the Settings path for `settings.xml`.
    @ObservationIgnored var usesPreferenceSettings = true

    @ObservationIgnored weak var consumer: (any IDEJavaModelConsumer)?

    private let jdk: IDEJDKSelection
    private let status: IDEProjectStatus
    @ObservationIgnored private let trustStore: ProjectTrustStore
    @ObservationIgnored private let runner: MavenCommandRunner
    @ObservationIgnored private let pomStore: MavenPOMStore
    @ObservationIgnored private let userHome: URL?
    @ObservationIgnored private let environmentVariables: [String: String]?
    @ObservationIgnored private let profileStore: MavenProfileStore
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let reread = Debouncer()
    @ObservationIgnored private var projectRootURL: URL?
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private var javaHomePath: String?
    @ObservationIgnored private var buildFileBaseline: GradleBuildFileSnapshot?

    init(
        jdk: IDEJDKSelection,
        status: IDEProjectStatus,
        trustStore: ProjectTrustStore = IDESharedServices.shared.mavenTrust,
        runner: MavenCommandRunner? = nil,
        pomStore: MavenPOMStore = .shared,
        userHome: URL? = nil,
        environment: [String: String]? = nil,
        profileStoreURL: URL? = nil
    ) {
        self.jdk = jdk
        self.status = status
        self.trustStore = trustStore
        self.runner = runner ?? MavenCommandRunner(trustStore: trustStore)
        self.pomStore = pomStore
        self.userHome = userHome
        self.environmentVariables = environment
        profileStore = MavenProfileStore(fileURL: profileStoreURL ?? Self.defaultProfileStoreURL)
    }

    /// `~/Library/Application Support/com.umbra.editor/maven-trust.json`.
    static var defaultTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("maven-trust.json")
    }

    static var defaultProfileStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("maven-profiles.json")
    }

    static func isMavenProject(_ root: URL) -> Bool {
        let pom = root.appendingPathComponent("pom.xml")
        guard FileManager.default.fileExists(atPath: pom.path) else { return false }
        return !GradleProjectModelExtractor.isGradleProject(root)
    }

    // MARK: - State

    var isActive: Bool {
        if case .notDetected = syncState { return false }
        return projectRootURL != nil
    }

    var isBusy: Bool { syncState.isSyncing || isRunningGoals || syncInFlight }

    var runningTasks: [String] { runningGoals }

    var rootURL: URL? { projectRootURL }

    var isTrusted: Bool { projectRootURL.map { trustStore.isTrusted($0) } ?? false }

    var hasConfigurationChanges: Bool { false }

    var tasks: [IDEProjectTask] {
        (model?.javaProjectModel.subprojects ?? []).flatMap { subproject in
            subproject.tasks.map {
                IDEProjectTask(path: $0.path, name: $0.name, module: subproject.path, group: $0.group, summary: $0.description)
            }
        }
    }

    var sourceRootPaths: Set<String> {
        var paths = Set<String>()
        for module in model?.modules ?? [] {
            for url in module.sourceDirectories + module.testSourceDirectories {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    func appendConsoleNote(_ text: String) {
        console.appendNote(text)
    }

    func appendConsoleNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        var console = console
        for note in notes { console.appendNote(note) }
        self.console = console
    }

    func claim(root: URL) -> IDEProjectClaim? {
        guard isActive else { return nil }
        let directories = model?.modules.map(\.directory) ?? [root]
        return IDEProjectClaim(strength: .rootBuildFile, packageRoots: directories)
    }

    // MARK: - Lifecycle

    func projectDidChange(root url: URL?) {
        projectGeneration += 1
        let generation = projectGeneration
        cancelWork()
        projectRootURL = url
        buildFileBaseline = nil
        javaHomePath = nil

        guard let url, Self.isMavenProject(url) else {
            syncState = .notDetected
            isLoadingModel = false
            model = nil
            return
        }

        if !autoReadEnabled {
            syncState = .awaitingTrust
            isLoadingModel = false
            model = nil
            console = IDEProjectConsoleLog()
            console.appendNote("Maven project detected. Reload to read it.")
            return
        }
        model = nil
        readProject(announce: true, allowDownload: true, generation: generation)
    }

    func stop() {
        projectGeneration += 1
        cancelWork()
        projectRootURL = nil
        syncState = .notDetected
        isLoadingModel = false
        model = nil
    }

    func dismissConfigurationChanges() {}

    func reload() {
        guard let url = projectRootURL, Self.isMavenProject(url) else { return }
        readProject(announce: true, allowDownload: true, generation: projectGeneration)
    }

    func cancelSync() {
        guard syncInFlight || syncState.isSyncing else { return }
        let announced = syncState.isSyncing
        syncTask?.cancel()
        syncTask = nil
        readGeneration += 1
        syncInFlight = false
        isLoadingModel = false
        status.clear(Self.readingMessage)
        if model == nil {
            syncState = .failed(summary: "Maven read was cancelled")
        }
        console.appendNote("Read cancelled")
        console.markFinished()
        if announced { environment.syncFinished(.cancelled) }
    }

    func jdkSelectionChanged() async {
        let generation = projectGeneration
        guard let url = projectRootURL, isActive, autoReadEnabled, !isBusy else { return }
        let home = await jdk.resolve(minimumFeatureVersion: nil)?.installation.home.resolvingSymlinksInPath().path
        guard isCurrent(generation), home != javaHomePath else { return }
        readProject(
            announce: true,
            allowDownload: trustStore.isTrusted(url) && downloadsDependencies,
            generation: generation
        )
    }

    /// Turns a profile on or off for this folder and reads the POM again. Only the user's overrides
    /// are stored, so a JDK-activated profile is not frozen on.
    func setProfile(id: String, enabled: Bool) {
        guard let root = projectRootURL, !id.isEmpty else { return }
        var choice = profileStore.choice(for: root)
        if enabled {
            if !choice.enabled.contains(id) { choice.enabled.append(id) }
            choice.disabled.removeAll { $0 == id }
        } else {
            if !choice.disabled.contains(id) { choice.disabled.append(id) }
            choice.enabled.removeAll { $0 == id }
        }
        profileStore.save(choice, for: root)
        guard !isRunningGoals else { return }
        readProject(announce: false, allowDownload: trustStore.isTrusted(root) && downloadsDependencies, generation: projectGeneration)
    }

    // MARK: - Read

    private static let readingMessage = "Reading pom.xml"

    private var autoReadEnabled: Bool { autoReadOverride ?? IDEPreferences.shared.javaMavenAutoRead }

    private var downloadsDependencies: Bool {
        downloadDependenciesOverride ?? IDEPreferences.shared.javaMavenDownloadDependencies
    }

    private func readProject(announce: Bool, allowDownload: Bool, generation: Int) {
        guard let root = projectRootURL else { return }
        syncTask?.cancel()
        readGeneration += 1
        let readToken = readGeneration
        syncInFlight = true
        isLoadingModel = model == nil
        if announce {
            syncState = .syncing
            status.set(Self.readingMessage)
            console = IDEProjectConsoleLog()
            console.appendNote("Project: \(root.path)")
            console.appendNote("Reading pom.xml")
        }
        let store = pomStore
        let trustedDownload = allowDownload && trustStore.isTrusted(root) && downloadsDependencies
        syncTask = Task {
            defer {
                if readToken == self.readGeneration, generation == self.projectGeneration {
                    self.syncInFlight = false
                    self.isLoadingModel = false
                    self.status.clear(Self.readingMessage)
                }
            }
            let options = await self.readOptions()
            let javaHome = await self.jdk.resolve(minimumFeatureVersion: options.jdkFeatureVersion)?.installation.home
            guard self.isCurrent(generation), readToken == self.readGeneration else { return }
            self.javaHomePath = javaHome?.resolvingSymlinksInPath().path
            do {
                store.invalidateProjectPOMs()
                var current = try await MavenProjectReader.read(root: root, options: options, store: store)
                guard self.isCurrent(generation), readToken == self.readGeneration else { return }
                self.readCount += 1
                if trustedDownload, !current.missing.isEmpty {
                    current = try await self.downloadMissing(
                        in: current, root: root, options: options, store: store, javaHome: javaHome, rounds: 3
                    )
                    guard self.isCurrent(generation), readToken == self.readGeneration else { return }
                }
                let snapshot = await Task.detached(priority: .utility) {
                    GradleBuildFileSnapshot.capture(projectRoot: root, inputPaths: MavenBuildFiles.inputPaths(under:))
                }.value
                guard self.isCurrent(generation), readToken == self.readGeneration else { return }
                self.buildFileBaseline = snapshot
                let previous = self.model?.javaProjectModel
                self.model = current
                let projected = current.javaProjectModel
                await self.consumer?.javaModelApplied(projected, previous: previous, logToConsole: announce)
                guard self.isCurrent(generation), readToken == self.readGeneration else { return }
                let dependencies = projected.classpathJars.count
                self.syncState = .synced(modules: current.modules.count, dependencies: dependencies)
                self.noteMissing(current)
                if announce {
                    self.console.appendNote("Read finished")
                    self.console.markFinished()
                    self.environment.syncFinished(.synced(modules: current.modules.count, dependencies: dependencies))
                }
            } catch {
                guard self.isCurrent(generation), readToken == self.readGeneration else { return }
                await self.handleReadError(error, root: root, announce: announce)
            }
        }
    }

    private func downloadMissing(
        in model: MavenProjectModel,
        root: URL,
        options: MavenReadOptions,
        store: MavenPOMStore,
        javaHome: URL?,
        rounds: Int
    ) async throws -> MavenProjectModel {
        var current = model
        var round = 0
        while round < rounds, !current.missing.isEmpty {
            round += 1
            let result = try await MavenDependencyDownload.resolve(
                model: current,
                projectRoot: root,
                sources: false,
                runner: runner,
                javaHome: javaHome,
                executableOverride: executableOverride,
                settingsFile: settingsFile,
                offline: offline,
                timeout: goalTimeout(for: ["dependency:resolve"]),
                output: consoleOutput(generation: projectGeneration)
            )
            store.invalidateProjectPOMs()
            current = try await MavenProjectReader.read(root: root, options: options, store: store)
            readCount += 1
            if result.exitCode != 0 { break }
        }
        return current
    }

    private func handleReadError(_ error: Error, root: URL, announce: Bool) async {
        let summary = Self.summarize(error)
        console.appendNote(summary)
        status.set(summary)
        let snapshot = await Task.detached(priority: .utility) {
            GradleBuildFileSnapshot.capture(projectRoot: root, inputPaths: MavenBuildFiles.inputPaths(under:))
        }.value
        guard projectRootURL == root else { return }
        buildFileBaseline = snapshot
        if let model {
            // An announced re-read set `.syncing`. A parse error keeps the model that is already shown.
            if case .syncing = syncState {
                let dependencies = model.javaProjectModel.classpathJars.count
                syncState = .synced(modules: model.modules.count, dependencies: dependencies)
            }
        } else {
            syncState = .failed(summary: summary)
            onNeedsWholeTreeIndex?()
        }
        if announce {
            console.markFinished()
            environment.syncFinished(.failed(summary: summary))
            environment.syncFailed()
        }
    }

    private func noteMissing(_ model: MavenProjectModel) {
        let count = model.missing.count
        guard count > 0 else { return }
        let noun = count == 1 ? "dependency isn't" : "dependencies aren't"
        console.appendNote("\(count) \(noun) in your local repository — Download")
    }

    private func readOptions() async -> MavenReadOptions {
        let feature = await jdk.resolve(minimumFeatureVersion: nil)?.installation.featureVersion
        let choice = projectRootURL.map { profileStore.choice(for: $0) } ?? MavenProfileStore.Choice()
        return MavenReadOptions(
            activeProfiles: choice.enabled,
            disabledProfiles: choice.disabled,
            jdkFeatureVersion: feature,
            userHome: userHome,
            environment: environmentVariables ?? ProcessInfo.processInfo.environment
        )
    }

    func filesDidChange(_ paths: Set<String>) {
        guard let root = projectRootURL, isActive, autoReadEnabled, !syncInFlight, !isRunningGoals else { return }
        if case .syncing = syncState { return }
        guard let baseline = buildFileBaseline else { return }
        let rootPath = root.path
        let relevant = paths.filter { MavenBuildFiles.matches(path: $0, root: rootPath) }
        guard !relevant.isEmpty else { return }
        let generation = projectGeneration
        reread.schedule(after: .milliseconds(500)) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            var changed = false
            for path in relevant {
                let relative = String(path.dropFirst(prefix.count))
                let differs = await Task.detached(priority: .utility) {
                    baseline.differs(relativePath: relative, projectRoot: root)
                }.value
                if differs { changed = true; break }
            }
            guard changed, self.isCurrent(generation), !self.syncInFlight, !self.isRunningGoals else { return }
            self.readProject(
                announce: false,
                allowDownload: self.trustStore.isTrusted(root) && self.downloadsDependencies,
                generation: generation
            )
        }
    }

    // MARK: - Goals

    func runTasks(_ tasks: [String]) {
        let goals = tasks.map(Self.goalName)
        let selector = Self.sharedSelector(tasks, model: model)
        runGoals(goals, module: selector, extraArguments: [])
    }

    /// `test-compile` for the reactor, so Build Project compiles main and test sources.
    func build() {
        runGoals(["test-compile"], module: nil, extraArguments: [])
    }

    func cancelTasks() {
        guard isRunningGoals else { return }
        runTask?.cancel()
        runTask = nil
        isRunningGoals = false
        runningGoals = []
        console.appendNote("Goal run cancelled")
        console.markFinished()
    }

    /// Runs `goals`. `module` is `groupId:artifactId` and becomes `-pl` / `-am`. `nil` is the reactor.
    /// `completion` is called exactly once.
    func runGoals(
        _ goals: [String],
        module: String?,
        extraArguments: [String] = [],
        timeout customTimeout: Duration? = nil,
        completion: (@MainActor (IDEMavenRunOutcome) -> Void)? = nil
    ) {
        guard let root = projectRootURL, Self.isMavenProject(root) else {
            completion?(.notStarted("This project is not a Maven project."))
            return
        }
        let names = goals.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            completion?(.notStarted("No Maven goal was given."))
            return
        }
        guard !isBusy else {
            completion?(.notStarted("Maven is already busy in this window. Try again when it finishes."))
            return
        }
        var arguments = extraArguments
        if let module, !module.isEmpty {
            arguments = ["-pl", module, "-am"] + arguments
        }
        if skipTests, !arguments.contains(where: { $0 == "-DskipTests" || $0.hasPrefix("-DskipTests=") }) {
            arguments.append("-DskipTests")
        }
        runTask?.cancel()
        let reported = names
        runTask = Task { [runner] in
            isRunningGoals = true
            runningGoals = reported
            await environment.prepareToRun()
            console = IDEProjectConsoleLog()
            console.appendNote("Project: \(root.path)")
            console.appendNote("Goals: \(reported.joined(separator: " "))")
            let javaHome = await jdk.resolve(minimumFeatureVersion: model?.javaProjectModel.maxLanguageLevel)?.installation.home
            if let javaHome { console.appendNote("JAVA_HOME: \(javaHome.path)") }
            defer {
                isRunningGoals = false
                runningGoals = []
            }
            guard await confirmTrust(for: root) else {
                console.appendNote("Not run: the project is not trusted")
                console.markFinished()
                completion?(.notStarted("The project is not trusted, so Maven was not run."))
                return
            }
            do {
                let startedAt = Date()
                let result = try await runner.run(
                    projectDirectory: root,
                    goals: reported,
                    arguments: arguments,
                    javaHome: javaHome,
                    executableOverride: executableOverride,
                    settingsFile: settingsFile,
                    offline: offline,
                    timeout: customTimeout ?? goalTimeout(for: reported),
                    output: consoleOutput(generation: projectGeneration)
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                console.appendNote(String(format: "Maven exited %d in %.1fs", result.exitCode, elapsed))
                console.markFinished()
                if result.exitCode == 0 { consumer?.buildSucceeded() }
                environment.tasksFinished(IDEProjectTaskReport(
                    tasks: reported, root: root, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
                ))
                completion?(.finished(result))
            } catch is CancellationError {
                console.appendNote("Goal run cancelled")
                console.markFinished()
                completion?(.cancelled(partial: nil))
            } catch {
                console.appendNote(Self.summarize(error))
                console.markFinished()
                switch error {
                case GradleCommandError.timedOut(let partial):
                    finishTasks(reported, root, partial)
                    completion?(.timedOut(partial: partial))
                case GradleCommandError.cancelled(let partial):
                    finishTasks(reported, root, partial)
                    completion?(.cancelled(partial: partial))
                default:
                    completion?(.failed(Self.summarize(error)))
                }
            }
        }
    }

    /// Downloads artifacts that are not in the local repository, then reads the POM again.
    /// Asks for trust. `sources` asks for the `sources` classifier.
    func downloadDependencies(sources: Bool, completion: (@MainActor (IDEMavenRunOutcome) -> Void)? = nil) {
        guard let root = projectRootURL, isActive else {
            completion?(.notStarted("This project is not a Maven project."))
            return
        }
        guard let model else {
            completion?(.notStarted("Read the Maven project before downloading."))
            return
        }
        guard !isBusy else {
            completion?(.notStarted("Maven is already busy in this window. Try again when it finishes."))
            return
        }
        let goal = sources ? "dependency:sources" : "dependency:resolve"
        runTask = Task { [runner, pomStore] in
            isRunningGoals = true
            runningGoals = [goal]
            await environment.prepareToRun()
            console = IDEProjectConsoleLog()
            console.appendNote("Project: \(root.path)")
            console.appendNote(sources ? "Downloading sources" : "Downloading missing dependencies")
            defer {
                isRunningGoals = false
                runningGoals = []
            }
            guard await confirmTrust(for: root) else {
                console.appendNote("Not downloaded: the project is not trusted")
                console.markFinished()
                completion?(.notStarted("The project is not trusted, so Maven was not run."))
                return
            }
            let javaHome = await jdk.resolve(minimumFeatureVersion: model.javaProjectModel.maxLanguageLevel)?.installation.home
            do {
                let result = try await MavenDependencyDownload.resolve(
                    model: model,
                    projectRoot: root,
                    sources: sources,
                    runner: runner,
                    javaHome: javaHome,
                    executableOverride: executableOverride,
                    settingsFile: settingsFile,
                    offline: offline,
                    timeout: goalTimeout(for: [goal]),
                    output: consoleOutput(generation: projectGeneration)
                )
                console.appendNote("Maven exited \(result.exitCode)")
                pomStore.invalidateProjectPOMs()
                guard isCurrent(projectGeneration) else {
                    completion?(.cancelled(partial: result))
                    return
                }
                readProject(announce: false, allowDownload: false, generation: projectGeneration)
                completion?(.finished(result))
            } catch is CancellationError {
                console.appendNote("Download cancelled")
                console.markFinished()
                completion?(.cancelled(partial: nil))
            } catch {
                console.appendNote(Self.summarize(error))
                console.markFinished()
                completion?(.failed(Self.summarize(error)))
            }
        }
    }

    // MARK: - Diagrams

    func loadDiagram(_ request: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace _: IDEWorkspace) async -> IDEDiagramLoad? {
        if request.id == IDEDiagramRequest.mavenModules.id {
            guard let model else {
                return IDEDiagramLoad(
                    document: .empty(title: request.title),
                    emptyMessage: "Read the Maven project to see its modules."
                )
            }
            let graph = GradleDependencyGraph.moduleGraph(from: model.javaProjectModel)
                .limited(to: GradleDependencyGraph.componentLimit)
            return IDEDiagramDocumentBuilder.load(
                from: graph, title: request.title, emptyMessage: "This project has no modules."
            )
        }
        if let path = request.mavenModulePath {
            guard let model else {
                return IDEDiagramLoad(
                    document: .empty(title: request.title),
                    emptyMessage: "Read the Maven project to see its libraries."
                )
            }
            return IDEDiagramDocumentBuilder.load(
                from: model.dependencyGraph(modulePath: path),
                title: request.title,
                emptyMessage: "This module has no libraries."
            )
        }
        return nil
    }

    // MARK: - Chrome

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if isActive {
            windows.append(IDEToolWindow(
                id: "maven", systemImage: "shippingbox", title: "Maven", shortcut: nil, tint: .orange,
                placement: .trailingTop, isOpen: workspace.showsProjectSidebar,
                toggle: { [weak workspace] in workspace?.toggleProjectSidebar() },
                order: IDEToolWindow.Order.mavenSidebar
            ))
        }
        if workspace.showsMavenConsoleTab {
            windows.append(workspace.bottomToolWindow(
                .maven, "text.alignleft", "Maven Console", nil, .orange, .trailingBottom,
                order: IDEToolWindow.Order.mavenConsole
            ))
        }
        return windows
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard isActive else { return [] }
        return [.button(
            id: "maven.build", order: IDEToolbarItem.Order.build, systemImage: "hammer", help: "Build Project",
            action: { [weak workspace] in workspace?.buildGradleProject() }
        )]
    }

    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard workspace.showsMavenConsoleTab else { return [] }
        return [IDEBottomTabContribution(
            tab: .maven, order: IDEBottomPanelTab.Order.maven,
            item: { workspace in
                AnyView(IDEProjectTabItem(
                    title: "Maven", symbol: "shippingbox",
                    isSelected: workspace.isBottomTabSelected(.maven),
                    isBusy: workspace.maven.isBusy,
                    isFailed: workspace.maven.syncState.isFailed,
                    busyDescription: "reading", failedDescription: "read failed",
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.maven) }
                ))
            },
            content: { workspace in
                AnyView(IDEProjectConsoleView(
                    log: workspace.maven.console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { workspace in AnyView(IDEProjectConsoleControls(system: workspace.maven)) },
            staysWhenLastShellCloses: true
        )]
    }

    func makeSidebar() -> AnyView {
        AnyView(IDEMavenSidebarPanel())
    }

    // MARK: - Helpers

    private func confirmTrust(for root: URL) async -> Bool {
        await IDEProjectTrustGate(store: trustStore, prompt: trustPrompt).confirmTrust(for: root)
    }

    private var executableOverride: String? {
        let value = IDEPreferences.shared.javaMavenExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var settingsFile: URL? {
        guard usesPreferenceSettings else { return nil }
        let value = IDEPreferences.shared.javaMavenSettingsFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    private func goalTimeout(for goals: [String]) -> Duration {
        let long = goals.contains { goal in
            let name = goal.split(separator: ":").last.map(String.init) ?? goal
            return name == "run"
        }
        if long { return Duration.seconds(365 * 24 * 60 * 60) }
        return .seconds(max(30, IDEPreferences.shared.javaMavenGoalTimeoutSeconds))
    }

    private func consoleOutput(generation: Int) -> GradleOutputHandler {
        { [weak self] line in
            Task { @MainActor in
                guard let self, generation == self.projectGeneration else { return }
                self.console.appendProcessLine(line)
            }
        }
    }

    private func finishTasks(_ tasks: [String], _ root: URL, _ result: GradleCommandResult) {
        environment.tasksFinished(IDEProjectTaskReport(
            tasks: tasks, root: root, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
        ))
    }

    private func cancelWork() {
        syncTask?.cancel()
        syncTask = nil
        runTask?.cancel()
        runTask = nil
        reread.cancel()
        readGeneration += 1
        syncInFlight = false
        isRunningGoals = false
        runningGoals = []
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == projectGeneration && !Task.isCancelled
    }

    private static func goalName(_ taskPath: String) -> String {
        guard let colon = taskPath.lastIndex(of: ":"), taskPath != ":" else { return taskPath }
        let name = String(taskPath[taskPath.index(after: colon)...])
        return name.isEmpty ? taskPath : name
    }

    /// The `group:artifact` shared by every task path, or nil when they name more than one module
    /// or no module (an unqualified goal runs the reactor).
    private static func sharedSelector(_ tasks: [String], model: MavenProjectModel?) -> String? {
        guard let model else { return nil }
        let paths = Set(tasks.map(modulePath(ofTask:)))
        guard paths.count == 1, let path = paths.first, let path else { return nil }
        return model.modules.first { $0.path == path }?.selector
    }

    private static func modulePath(ofTask taskPath: String) -> String? {
        guard taskPath.contains(":") else { return nil }
        guard let range = taskPath.range(of: ":", options: .backwards) else { return nil }
        let head = String(taskPath[..<range.lowerBound])
        return head.isEmpty ? ":" : head
    }

    private static func summarize(_ error: Error) -> String {
        if let read = error as? MavenReadError {
            return read.errorDescription ?? read.message
        }
        switch error {
        case GradleCommandError.untrusted:
            return "Project isn't trusted"
        case GradleCommandError.executableNotFound:
            return "No mvn found (checked ./mvnw and PATH)"
        case GradleCommandError.timedOut:
            return "Maven timed out"
        case GradleCommandError.cancelled:
            return "Maven was cancelled"
        default:
            return error.localizedDescription
        }
    }
}

/// User overrides for Maven profiles, keyed by the project root. Enabled and disabled are stored
/// separately so a profile activated by the JDK is not written down as a permanent choice.
struct MavenProfileStore: Sendable {
    struct Choice: Codable, Equatable, Sendable {
        var enabled: [String] = []
        var disabled: [String] = []
    }

    private struct FileContents: Codable {
        var projects: [String: Choice] = [:]
    }

    let fileURL: URL

    func choice(for root: URL) -> Choice {
        load().projects[key(root)] ?? Choice()
    }

    func save(_ choice: Choice, for root: URL) {
        var file = load()
        file.projects[key(root)] = choice
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() -> FileContents {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(FileContents.self, from: data) else { return FileContents() }
        return file
    }

    private func key(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
