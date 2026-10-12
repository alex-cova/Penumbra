import Darwin
import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation
import SubprocessKit
import SwiftUI

extension IDEBottomPanelTab {
    static let swiftPM = IDEBottomPanelTab("swiftpm")
}

/// One `swift` command the system runs.
struct IDESwiftPMInvocation: Sendable, Equatable {
    var title: String
    var arguments: [String]
    /// Whether its output is read for compiler problems (build, test and run are; resolve is not).
    var collectsDiagnostics = true
}

struct IDESwiftPMOutcome: Sendable, Equatable {
    var invocation: IDESwiftPMInvocation
    var status: Int32
    var duration: TimeInterval
    var cancelled: Bool
    /// Standard output and error, as the command printed them.
    var output: String

    var succeeded: Bool { status == 0 && !cancelled }
}

/// A SwiftPM package: the root `Package.swift`. Reading it is the sync, and nothing is run to do
/// it. Commands run as `swift <subcommand>` through SubprocessKit after the user trusts the
/// folder; trust is its own file, since evaluating a manifest and building plugins execute code.
/// Compiler problems go to Problems through `onBuildDiagnostics`, not through
/// `environment.tasksFinished`, which Java's Gradle handling would read as a Gradle build.
@MainActor
@Observable
final class IDESwiftPMProjectSystem: IDEProjectSystem {
    static let dependenciesDiagramID = "swiftpm:dependencies"

    let id = "swiftpm"
    let displayName = "SwiftPM"
    var consoleTab: IDEBottomPanelTab? { .swiftPM }

    @ObservationIgnored var environment = IDEProjectEnvironment()
    /// The trust sheet. The window sets it. Nil answers "no" and stores nothing.
    @ObservationIgnored var trustPrompt: (@MainActor (URL) async -> Bool)?
    /// Reveals the console. Called when a command starts, including one that only explains why it did not.
    @ObservationIgnored var onActivity: (@MainActor () -> Void)?
    /// The child's whole environment. Nil inherits. Tests set a PATH that holds only a fake `swift`.
    @ObservationIgnored var launchEnvironment: [String: String]?
    /// Receives the compiler problems of a finished build, test or run, per file, replacing the
    /// previous set (an empty map clears it).
    @ObservationIgnored var onBuildDiagnostics: (@MainActor ([URL: [Diagnostic]]) -> Void)?
    /// The text of an open buffer, so a compiler column lands in what the editor shows.
    @ObservationIgnored var bufferText: (@MainActor (URL) -> String?)?
    /// Told whenever the manifest was read: the targets, so the Swift index can tell modules apart.
    @ObservationIgnored var onModelChanged: (@MainActor (IDESwiftPMManifest?, URL?) -> Void)?

    private(set) var syncState: IDEProjectSyncState = .notDetected
    private(set) var runningTasks: [String] = []
    private(set) var console = IDEProjectConsoleLog()
    private(set) var tasks: [IDEProjectTask] = []
    private(set) var hasConfigurationChanges = false
    private(set) var isRunningTasks = false
    private(set) var manifest: IDESwiftPMManifest?
    private(set) var rootURL: URL?

    @ObservationIgnored private let status: IDEProjectStatus
    @ObservationIgnored private let trustStore: GradleTrustStore
    @ObservationIgnored private var manifestBaseline: Data?
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    /// Whether ``filesDidChange(_:)`` compares the manifest: it existed when the project loaded or reloaded.
    @ObservationIgnored private var watchesManifest = false
    @ObservationIgnored private var statusMessage: String?

    static var defaultTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("swiftpm-trust.json")
    }

    static func dependenciesDiagramRequest() -> IDEDiagramRequest {
        IDEDiagramRequest(
            id: dependenciesDiagramID, title: "Targets", symbolName: "shippingbox", presentation: .dependencies
        )
    }

    init(status: IDEProjectStatus, trustStore: GradleTrustStore = IDESharedServices.shared.swiftPMTrust) {
        self.status = status
        self.trustStore = trustStore
    }

    var isActive: Bool {
        if case .notDetected = syncState { return false }
        return rootURL != nil
    }

    var isBusy: Bool { isRunningTasks }

    var sourceRootPaths: Set<String> {
        guard let manifest, let rootURL else { return [] }
        return Set(manifest.targets.filter(\.kind.isCode).map { manifest.directory(of: $0, root: rootURL).path })
    }

    var isTrusted: Bool {
        guard let rootURL else { return false }
        return trustStore.isTrusted(rootURL)
    }

    /// True when the folder is trusted, asking first when it is not; a yes is remembered. A
    /// SwiftUI preview builds and runs the package's code outside `run(_:)`, so it asks here.
    func ensureTrusted() async -> Bool {
        guard let root = rootURL else { return false }
        if trustStore.isTrusted(root) { return true }
        let token = projectGeneration
        guard let prompt = trustPrompt, await prompt(root), projectGeneration == token else { return false }
        trustStore.setTrusted(true, for: root)
        if case .untrusted = syncState, let manifest {
            syncState = .synced(modules: manifest.targets.count, dependencies: manifest.dependencyCount)
        }
        refineManifest(root: root)
        return true
    }

    // MARK: Lifecycle

    func projectDidChange(root: URL?) {
        clearStatus()
        projectGeneration += 1
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        refineTask?.cancel()
        refineTask = nil
        isRunningTasks = false
        runningTasks = []
        watchesManifest = false
        hasConfigurationChanges = false
        console = IDEProjectConsoleLog()
        let standardized = root?.standardizedFileURL
        rootURL = standardized
        guard let standardized else {
            setManifest(nil, root: nil)
            manifestBaseline = nil
            syncState = .notDetected
            return
        }
        applyManifest(at: standardized)
        if FileManager.default.fileExists(atPath: standardized.appendingPathComponent("Package.swift").path) {
            watchesManifest = true
        }
        // A folder the user trusted before is evaluated for the exact model, as a trusted Gradle project syncs.
        if manifest != nil, trustStore.decision(for: standardized) == true {
            refineManifest(root: standardized)
        }
    }

    func reload() {
        guard let root = rootURL else { return }
        hasConfigurationChanges = false
        applyManifest(at: root)
        if manifest != nil {
            watchesManifest = true
        } else {
            watchesManifest = false
        }
        guard manifest != nil else { return }
        if trustStore.isTrusted(root) {
            refineManifest(root: root)
            return
        }
        let generation = projectGeneration
        Task { [weak self] in
            guard let self else { return }
            let trusted = await self.trustPrompt?(root) ?? false
            guard self.projectGeneration == generation, !Task.isCancelled else { return }
            self.trustStore.setTrusted(trusted, for: root)
            guard let manifest = self.manifest else { return }
            self.syncState = trusted ? .synced(modules: manifest.targets.count, dependencies: manifest.dependencyCount) : .untrusted
            if trusted { self.refineManifest(root: root) }
        }
    }

    func dismissConfigurationChanges() {
        if let root = rootURL {
            manifestBaseline = try? Data(contentsOf: root.appendingPathComponent("Package.swift"))
        }
        hasConfigurationChanges = false
    }

    func cancelSync() {
        refineTask?.cancel()
    }

    func cancelTasks() {
        runTask?.cancel()
    }

    func stop() {
        clearStatus()
        projectGeneration += 1
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        refineTask?.cancel()
        refineTask = nil
        isRunningTasks = false
        runningTasks = []
        watchesManifest = false
        rootURL = nil
        setManifest(nil, root: nil)
        manifestBaseline = nil
        syncState = .notDetected
    }

    // MARK: Tasks

    /// The command a task path stands for: `build`, `test`, `run:<name>`, `resolve`, `update`, `clean`.
    func invocation(forTask path: String) -> IDESwiftPMInvocation? {
        switch path {
        case "build": return IDESwiftPMInvocation(title: "swift build", arguments: ["build"])
        case "test": return IDESwiftPMInvocation(title: "swift test", arguments: ["test"])
        case "resolve":
            return IDESwiftPMInvocation(title: "swift package resolve", arguments: ["package", "resolve"], collectsDiagnostics: false)
        case "update":
            return IDESwiftPMInvocation(title: "swift package update", arguments: ["package", "update"], collectsDiagnostics: false)
        case "clean":
            return IDESwiftPMInvocation(title: "swift package clean", arguments: ["package", "clean"], collectsDiagnostics: false)
        default:
            guard path.hasPrefix("run:") else { return nil }
            let name = String(path.dropFirst(4))
            return IDESwiftPMInvocation(title: "swift run \(name)", arguments: ["run", name])
        }
    }

    func runTasks(_ paths: [String]) {
        let invocations = paths.compactMap { path in
            tasks.contains { $0.path == path } ? invocation(forTask: path) : nil
        }
        guard !invocations.isEmpty else { return }
        run(invocations, completion: nil)
    }

    func build() {
        runTasks(["build"])
    }

    /// Runs the commands in order and stops after the first that fails. `completion` gets what ran
    /// (nothing when the folder was not trusted or the system was busy).
    func run(_ invocations: [IDESwiftPMInvocation], completion: (@MainActor ([IDESwiftPMOutcome]) -> Void)?) {
        guard !isRunningTasks, let root = rootURL, manifest != nil, !invocations.isEmpty else {
            completion?([])
            return
        }
        runGeneration += 1
        let generation = runGeneration
        let projectToken = projectGeneration
        isRunningTasks = true
        runningTasks = invocations.map(\.title)
        onActivity?()
        let prompt = trustPrompt
        let environment = launchEnvironment
        runTask = Task { [weak self] in
            guard let self else { return }
            var outcomes: [IDESwiftPMOutcome] = []
            defer {
                if generation == self.runGeneration {
                    self.clearStatus()
                    self.isRunningTasks = false
                    self.runningTasks = []
                    self.runTask = nil
                }
                if generation == self.runGeneration, self.projectGeneration == projectToken { completion?(outcomes) }
            }
            if !self.trustStore.isTrusted(root) {
                let answer = await prompt?(root) ?? false
                guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
                guard answer else {
                    self.console.reset()
                    self.console.appendNote("Project: \(root.path)")
                    self.console.appendNote("Not run: the project is not trusted")
                    self.console.markFinished()
                    self.onActivity?()
                    return
                }
                self.trustStore.setTrusted(true, for: root)
                if case .untrusted = self.syncState, let manifest = self.manifest {
                    self.syncState = .synced(modules: manifest.targets.count, dependencies: manifest.dependencyCount)
                }
                self.refineManifest(root: root)
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
            self.setStatus("Running \(invocations[0].title)…")
            self.console.reset()
            self.console.appendNote("Project: \(root.path)")
            self.onActivity?()
            guard let executable = Self.resolveSwift(environment: environment) else {
                self.console.appendNote("No swift found on PATH")
                self.console.markFinished()
                return
            }
            for invocation in invocations {
                guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
                self.runningTasks = [invocation.title]
                self.console.appendNote(invocation.title)
                let outcome = await self.launch(invocation, executable: executable, root: root, environment: environment)
                guard generation == self.runGeneration, self.projectGeneration == projectToken else { return }
                outcomes.append(outcome)
                if invocation.collectsDiagnostics { self.publishDiagnostics(from: outcome, root: root) }
                if outcome.cancelled {
                    self.console.appendNote("Cancelled")
                    break
                }
                self.console.appendNote(String(format: "swift exited %d in %.1fs", outcome.status, outcome.duration))
                if outcome.status != 0 { break }
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken else { return }
            self.console.markFinished()
        }
    }

    private func publishDiagnostics(from outcome: IDESwiftPMOutcome, root: URL) {
        let messages = SwiftBuildOutputParser.parse(outcome.output)
        let lookup = bufferText
        let diagnostics = SwiftBuildOutputParser.diagnostics(from: messages, baseDirectory: root) { url in
            lookup?(url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        onBuildDiagnostics?(diagnostics)
    }

    // MARK: Manifest

    private func applyManifest(at root: URL) {
        let file = root.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            setManifest(nil, root: root)
            manifestBaseline = nil
            syncState = .notDetected
            return
        }
        let data = try? Data(contentsOf: file)
        manifestBaseline = data
        guard let data, let source = String(data: data, encoding: .utf8),
              let parsed = IDESwiftPMManifest.parse(source: source, folderName: root.lastPathComponent) else {
            setManifest(nil, root: root)
            syncState = .failed(summary: "Couldn't read Package.swift")
            return
        }
        setManifest(parsed, root: root)
        if trustStore.decision(for: root) == false {
            syncState = .untrusted
        } else {
            syncState = .synced(modules: parsed.targets.count, dependencies: parsed.dependencyCount)
        }
    }

    private func setManifest(_ new: IDESwiftPMManifest?, root: URL?) {
        manifest = new
        tasks = Self.tasks(for: new)
        onModelChanged?(new, root)
    }

    static func tasks(for manifest: IDESwiftPMManifest?) -> [IDEProjectTask] {
        guard let manifest else { return [] }
        var tasks = [IDEProjectTask(path: "build", name: "build", module: ":", group: "build", summary: "swift build")]
        if manifest.hasTests {
            tasks.append(IDEProjectTask(path: "test", name: "test", module: ":", group: "build", summary: "swift test"))
        }
        for name in manifest.executableNames {
            tasks.append(IDEProjectTask(path: "run:\(name)", name: "run \(name)", module: ":", group: "run", summary: "swift run \(name)"))
        }
        tasks.append(IDEProjectTask(path: "resolve", name: "resolve", module: ":", group: "package", summary: "swift package resolve"))
        tasks.append(IDEProjectTask(path: "update", name: "update", module: ":", group: "package", summary: "swift package update"))
        tasks.append(IDEProjectTask(path: "clean", name: "clean", module: ":", group: "package", summary: "swift package clean"))
        return tasks
    }

    /// Replaces the syntactic model with `swift package dump-package`'s. It evaluates the manifest,
    /// so it runs only for a trusted folder.
    private func refineManifest(root: URL) {
        refineTask?.cancel()
        let token = projectGeneration
        let environment = launchEnvironment
        refineTask = Task { [weak self] in
            guard let executable = Self.resolveSwift(environment: environment) else { return }
            var request = SubprocessRequest(executable: executable, arguments: ["package", "dump-package"])
            request.workingDirectory = root
            request.environment = environment
            request.processGroup = true
            request.killGroupOnExit = true
            request.timeout = .seconds(90)
            guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded, !Task.isCancelled else { return }
            let data = result.stdout.data
            await MainActor.run {
                guard let self, self.projectGeneration == token, let exact = IDESwiftPMManifest.parse(
                    dumpPackage: data, folderName: root.lastPathComponent
                ) else { return }
                self.setManifest(exact, root: root)
                self.syncState = .synced(modules: exact.targets.count, dependencies: exact.dependencyCount)
            }
        }
    }

    /// Raises or clears the reload banner from the bytes of Package.swift after the project watcher
    /// reported it. An event says the file was touched, not that it changed: compare the bytes. A
    /// file that is gone differs from one that was there.
    func filesDidChange(_ paths: Set<String>) {
        guard watchesManifest, let root = rootURL else { return }
        let file = root.appendingPathComponent("Package.swift")
        guard paths.contains(file.path) else { return }
        hasConfigurationChanges = (try? Data(contentsOf: file)) != manifestBaseline
    }

    // MARK: Process

    private func launch(
        _ invocation: IDESwiftPMInvocation, executable: String, root: URL, environment: [String: String]?
    ) async -> IDESwiftPMOutcome {
        var request = SubprocessRequest(executable: executable, arguments: invocation.arguments)
        request.workingDirectory = root
        request.environment = environment
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = nil
        let buffer = IDEProjectOutputBuffer()
        let projectToken = projectGeneration
        let onOutput: @Sendable (Data, SubprocessOutputSource) -> Void = { [weak self] data, source in
            let lines = buffer.consume(data, source: source)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.projectGeneration == projectToken else { return }
                for line in lines { self.console.appendProcessLine(line) }
            }
        }
        do {
            let result = try await SubprocessRunner.run(request, onOutput: onOutput)
            await Task.yield()
            let output = result.stdout.text + "\n" + result.stderr.text
            guard projectGeneration == projectToken else {
                return IDESwiftPMOutcome(
                    invocation: invocation, status: result.exit.status, duration: result.duration, cancelled: true, output: output
                )
            }
            for line in buffer.flush() { console.appendProcessLine(line) }
            return IDESwiftPMOutcome(
                invocation: invocation, status: result.exit.status, duration: result.duration,
                cancelled: result.cancelled || Task.isCancelled, output: output
            )
        } catch {
            await Task.yield()
            console.appendNote("swift failed to start")
            return IDESwiftPMOutcome(
                invocation: invocation, status: 1, duration: 0, cancelled: Task.isCancelled || projectGeneration != projectToken,
                output: ""
            )
        }
    }

    /// The first executable named `swift` on PATH, else `/usr/bin/swift` (the toolchain shim).
    /// The lookup uses `launchEnvironment` when tests set it.
    static func resolveSwift(environment: [String: String]?) -> String? {
        let path = environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fileManager = FileManager.default
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("swift").path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        if environment == nil, fileManager.isExecutableFile(atPath: "/usr/bin/swift") { return "/usr/bin/swift" }
        return nil
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        status.set(message)
    }

    private func clearStatus() {
        if let statusMessage {
            status.clear(statusMessage)
            self.statusMessage = nil
        }
    }

    // MARK: Chrome

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if workspace.projectSystems.active?.id == id {
            windows.append(IDEToolWindow(
                id: "swiftpm", systemImage: "swift", title: "SwiftPM", shortcut: nil, tint: .orange,
                placement: .trailingTop, isOpen: workspace.showsProjectSidebar,
                toggle: { [weak workspace] in workspace?.toggleProjectSidebar() },
                order: IDEToolWindow.Order.gradleSidebar
            ))
        }
        if showsConsole {
            windows.append(workspace.bottomToolWindow(
                .swiftPM, "text.alignleft", "SwiftPM", nil, .orange, .trailingBottom,
                order: IDEToolWindow.Order.swiftPMConsole
            ))
        }
        return windows
    }

    func toolbarItems(for _: IDEWorkspace) -> [IDEToolbarItem] {
        guard isActive else { return [] }
        return [.button(
            id: "swiftpm.build", order: IDEToolbarItem.Order.build + 20, systemImage: "hammer", help: "swift build",
            action: { [weak self] in self?.build() }
        )]
    }

    func bottomTabs(for _: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard showsConsole else { return [] }
        return [IDEBottomTabContribution(
            tab: .swiftPM, order: IDEBottomPanelTab.Order.swiftPM,
            item: { workspace in
                AnyView(IDESwiftPMTabItem(
                    isSelected: workspace.isBottomTabSelected(.swiftPM),
                    isRunning: workspace.swiftPM.isBusy,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.swiftPM) }
                ))
            },
            content: { workspace in
                AnyView(IDEProjectConsoleView(
                    log: workspace.swiftPM.console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { _ in AnyView(IDESwiftPMConsoleControls()) },
            staysWhenLastShellCloses: true
        )]
    }

    func makeSidebar() -> AnyView {
        AnyView(IDESwiftPMSidebarPanel())
    }

    func loadDiagram(
        _ request: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace _: IDEWorkspace
    ) async -> IDEDiagramLoad? {
        guard request.id == Self.dependenciesDiagramID else { return nil }
        guard let manifest else {
            return IDEDiagramLoad(document: .empty(title: request.title), failure: "This folder has no Package.swift.")
        }
        return IDEDiagramLoad(document: IDESwiftPMDiagram.document(manifest: manifest, title: request.title))
    }
}

/// Splits live process output into lines. One buffer per stream; a partial line waits for its newline.
/// Shared by the project systems that run a child process.
final class IDEProjectOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func consume(_ data: Data, source: SubprocessOutputSource) -> [IDEProjectOutputLine] {
        let stream: IDEProjectOutputLine.Stream = source == .stdout ? .stdout : .stderr
        lock.lock()
        defer { lock.unlock() }
        var buffer = source == .stdout ? stdout : stderr
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var chunk = buffer[..<newline]
            buffer.removeSubrange(..<buffer.index(after: newline))
            if chunk.last == 0x0D { chunk = chunk.dropLast() }
            lines.append(String(decoding: chunk, as: UTF8.self))
        }
        if source == .stdout { stdout = buffer } else { stderr = buffer }
        return lines.map { IDEProjectOutputLine(stream: stream, text: $0) }
    }

    func flush() -> [IDEProjectOutputLine] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [IDEProjectOutputLine] = []
        if !stdout.isEmpty {
            lines.append(IDEProjectOutputLine(stream: .stdout, text: String(decoding: stdout, as: UTF8.self)))
            stdout.removeAll(keepingCapacity: false)
        }
        if !stderr.isEmpty {
            lines.append(IDEProjectOutputLine(stream: .stderr, text: String(decoding: stderr, as: UTF8.self)))
            stderr.removeAll(keepingCapacity: false)
        }
        return lines
    }
}

// MARK: - Chrome

struct IDESwiftPMSidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let system = workspace.swiftPM
        VStack(alignment: .leading, spacing: 0) {
            header(system)
            if case let .failed(summary) = system.syncState {
                pinned(summary)
            } else if system.manifest == nil {
                pinned("No Package.swift")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Tasks")
                        ForEach(system.tasks, id: \.path) { task in
                            taskRow(task, system: system)
                        }
                        if let manifest = system.manifest, !manifest.targets.isEmpty {
                            section("Targets")
                            ForEach(manifest.targets, id: \.name) { target in
                                infoRow(symbol: Self.symbol(for: target.kind), title: target.name, detail: target.kind.rawValue)
                            }
                        }
                        if let manifest = system.manifest, !manifest.packages.isEmpty {
                            section("Dependencies")
                            ForEach(manifest.packages, id: \.name) { package in
                                infoRow(symbol: "shippingbox", title: package.name, detail: package.isLocal ? "local" : "")
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if case .untrusted = system.syncState {
                Text("This folder is not trusted.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.horizontal, IDEAppearance.Spacing.lg)
                    .padding(.vertical, IDEAppearance.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }

    private func header(_ system: IDESwiftPMProjectSystem) -> some View {
        HStack(spacing: 2) {
            IDEPanelTitle("SwiftPM")
                .frame(maxWidth: .infinity, alignment: .leading)
            if system.isRunningTasks {
                Button(action: { system.cancelTasks() }) { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .help("Stop")
                    .accessibilityLabel("Stop")
            }
            Button(action: { system.reload() }) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Reload")
                .accessibilityLabel("Reload")
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.top, IDEAppearance.Spacing.sm)
            .padding(.bottom, 2)
    }

    private func taskRow(_ task: IDEProjectTask, system: IDESwiftPMProjectSystem) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button(action: { system.runTasks([task.path]) }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(system.isRunningTasks)
            .help(task.summary)
            .accessibilityLabel("Run \(task.name)")
            Text(task.name)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !system.isRunningTasks { system.runTasks([task.path]) }
        }
    }

    private func infoRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
    }

    private func pinned(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.lg)
            .padding(.top, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func symbol(for kind: IDESwiftPMManifest.TargetKind) -> String {
        switch kind {
        case .regular: return "cube"
        case .executable: return "terminal"
        case .test: return "checkmark.seal"
        case .macro: return "wand.and.stars"
        case .plugin: return "puzzlepiece.extension"
        case .system: return "gearshape"
        case .binary: return "shippingbox"
        }
    }
}

struct IDESwiftPMConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if workspace.swiftPM.isBusy {
                Button("Cancel", action: { workspace.swiftPM.cancelTasks() })
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Button(action: { workspace.swiftPM.reload() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Reload")
                    .accessibilityLabel("Reload")
            }
            Button(action: copyOutput) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Copy SwiftPM Output")
                .accessibilityLabel("Copy SwiftPM Output")
        }
    }

    private func copyOutput() {
        let text = workspace.swiftPM.console.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct IDESwiftPMTabItem: View {
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12)
            } else {
                Image(systemName: "swift")
                    .font(.system(size: 10))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12)
            }
            Text("SwiftPM")
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRunning ? "SwiftPM, running" : "SwiftPM")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
