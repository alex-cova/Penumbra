import Darwin
import EditorIntelligence
import Foundation
import JavaIntelligence
import Observation
import SubprocessKit
import SwiftUI

extension IDEBottomPanelTab {
    static let xcode = IDEBottomPanelTab("xcode")
}

/// One `xcodebuild` command the system runs.
struct IDEXcodeInvocation: Sendable, Equatable {
    var title: String
    var arguments: [String]
    /// Whether its output is read for compiler problems.
    var collectsDiagnostics = true
}

struct IDEXcodeOutcome: Sendable, Equatable {
    var invocation: IDEXcodeInvocation
    var status: Int32
    var duration: TimeInterval
    var cancelled: Bool
    var output: String

    var succeeded: Bool { status == 0 && !cancelled }
}

/// An Xcode project: a `*.xcodeproj` directly inside the open folder. Reading it is the sync and
/// runs nothing; `xcodebuild` runs through SubprocessKit once the user trusts the folder, since
/// build phases can run scripts. Both `project.xcproj` (Xcode 27) and `project.pbxproj` are read.
/// Compiler problems go to Problems under their own source (`IDEProblemsStore.xcodeBuildSource`).
@MainActor
@Observable
final class IDEXcodeProjectSystem: IDEProjectSystem {
    let id = "xcode"
    let displayName = "Xcode"
    var consoleTab: IDEBottomPanelTab? { .xcode }

    @ObservationIgnored var environment = IDEProjectEnvironment()
    /// The trust sheet. The window sets it. Nil answers "no" and stores nothing.
    @ObservationIgnored var trustPrompt: (@MainActor (URL) async -> Bool)?
    /// Reveals the console. Called when a command starts, including one that only explains why it did not.
    @ObservationIgnored var onActivity: (@MainActor () -> Void)?
    /// The child's whole environment. Nil inherits. Tests set a PATH that holds only a fake `xcodebuild`.
    @ObservationIgnored var launchEnvironment: [String: String]?
    /// Receives the compiler problems of a finished build, per file, replacing the previous set.
    @ObservationIgnored var onBuildDiagnostics: (@MainActor ([URL: [Diagnostic]]) -> Void)?
    /// The text of an open buffer, so a compiler column lands in what the editor shows.
    @ObservationIgnored var bufferText: (@MainActor (URL) -> String?)?

    private(set) var syncState: IDEProjectSyncState = .notDetected
    private(set) var runningTasks: [String] = []
    private(set) var console = IDEProjectConsoleLog()
    private(set) var tasks: [IDEProjectTask] = []
    private(set) var hasConfigurationChanges = false
    private(set) var isRunningTasks = false
    private(set) var model: IDEXcodeProjectModel?
    private(set) var rootURL: URL?

    @ObservationIgnored private let status: IDEProjectStatus
    @ObservationIgnored private let trustStore: GradleTrustStore
    @ObservationIgnored private var definitionBaseline: Data?
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var statusMessage: String?

    static var defaultTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("xcode-trust.json")
    }

    init(status: IDEProjectStatus, trustStore: GradleTrustStore = IDESharedServices.shared.xcodeTrust) {
        self.status = status
        self.trustStore = trustStore
    }

    var isActive: Bool {
        if case .notDetected = syncState { return false }
        return rootURL != nil
    }

    var isBusy: Bool { isRunningTasks }

    /// True when the folder is trusted, asking first when it is not; a yes is remembered. A SwiftUI
    /// preview builds the target (its build phases run scripts) outside `run(_:)`, so it asks here.
    func ensureTrusted() async -> Bool {
        guard let root = rootURL else { return false }
        if trustStore.isTrusted(root) { return true }
        let token = projectGeneration
        guard let prompt = trustPrompt, await prompt(root), projectGeneration == token else { return false }
        trustStore.setTrusted(true, for: root)
        if case .untrusted = syncState, let model {
            syncState = .synced(modules: model.targets.count, dependencies: model.packageCount)
        }
        return true
    }

    var sourceRootPaths: Set<String> {
        Set(model?.sourceDirectories.map(\.path) ?? [])
    }

    var isTrusted: Bool {
        guard let rootURL else { return false }
        return trustStore.isTrusted(rootURL)
    }

    /// `Debug` when the project has it, else its first configuration.
    var buildConfiguration: String {
        guard let configurations = model?.configurations, !configurations.isEmpty else { return "Debug" }
        return configurations.contains("Debug") ? "Debug" : configurations[0]
    }

    // MARK: Lifecycle

    func projectDidChange(root: URL?) {
        cancelRun()
        hasConfigurationChanges = false
        console = IDEProjectConsoleLog()
        let standardized = root?.standardizedFileURL
        rootURL = standardized
        guard let standardized else {
            setModel(nil)
            definitionBaseline = nil
            syncState = .notDetected
            return
        }
        loadModel(root: standardized)
    }

    func reload() {
        guard let root = rootURL else { return }
        hasConfigurationChanges = false
        loadModel(root: root)
    }

    func dismissConfigurationChanges() {
        if let model {
            definitionBaseline = try? Data(contentsOf: model.definitionFile)
        }
        hasConfigurationChanges = false
    }

    func cancelSync() {}

    func cancelTasks() {
        runTask?.cancel()
    }

    func stop() {
        cancelRun()
        rootURL = nil
        setModel(nil)
        definitionBaseline = nil
        syncState = .notDetected
    }

    private func cancelRun() {
        clearStatus()
        projectGeneration += 1
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        isRunningTasks = false
        runningTasks = []
    }

    // MARK: Model

    private func loadModel(root: URL) {
        guard let project = IDEXcodeProjectModel.findProject(in: root) else {
            setModel(nil)
            definitionBaseline = nil
            syncState = .notDetected
            return
        }
        do {
            let loaded = try IDEXcodeProjectModel.load(projectURL: project)
            definitionBaseline = try? Data(contentsOf: loaded.definitionFile)
            setModel(loaded)
            syncState = trustStore.decision(for: root) == false
                ? .untrusted
                : .synced(modules: loaded.targets.count, dependencies: loaded.packageCount)
        } catch {
            setModel(nil)
            definitionBaseline = (try? Data(contentsOf: project.appendingPathComponent("project.xcproj")))
                ?? (try? Data(contentsOf: project.appendingPathComponent("project.pbxproj")))
            syncState = .failed(summary: error.localizedDescription)
        }
    }

    private func setModel(_ new: IDEXcodeProjectModel?) {
        model = new
        tasks = Self.tasks(for: new)
    }

    static func tasks(for model: IDEXcodeProjectModel?) -> [IDEProjectTask] {
        guard let model else { return [] }
        var tasks = [IDEProjectTask(
            path: "build", name: "build", module: ":", group: "build", summary: "xcodebuild -alltargets build"
        )]
        for target in model.targets {
            tasks.append(IDEProjectTask(
                path: "build:\(target.name)", name: "build \(target.name)", module: target.name, group: "build",
                summary: "xcodebuild -target \(target.name) build"
            ))
        }
        tasks.append(IDEProjectTask(
            path: "clean", name: "clean", module: ":", group: "build", summary: "xcodebuild -alltargets clean"
        ))
        return tasks
    }

    /// Raises or clears the reload banner from the bytes of the project file after the watcher
    /// reported it. An event says the file was touched, not that it changed.
    func filesDidChange(_ paths: Set<String>) {
        guard let model else { return }
        let file = model.definitionFile
        guard paths.contains(file.path) || paths.contains(file.standardizedFileURL.path) else { return }
        hasConfigurationChanges = (try? Data(contentsOf: file)) != definitionBaseline
    }

    // MARK: Tasks

    func invocation(forTask path: String) -> IDEXcodeInvocation? {
        guard let model else { return nil }
        let project = model.projectURL.path
        let configuration = buildConfiguration
        switch path {
        case "build":
            return IDEXcodeInvocation(
                title: "xcodebuild build",
                arguments: ["-project", project, "-alltargets", "-configuration", configuration, "build"]
            )
        case "clean":
            return IDEXcodeInvocation(
                title: "xcodebuild clean",
                arguments: ["-project", project, "-alltargets", "-configuration", configuration, "clean"],
                collectsDiagnostics: false
            )
        default:
            guard path.hasPrefix("build:") else { return nil }
            let name = String(path.dropFirst(6))
            guard model.targets.contains(where: { $0.name == name }) else { return nil }
            return IDEXcodeInvocation(
                title: "xcodebuild -target \(name)",
                arguments: ["-project", project, "-target", name, "-configuration", configuration, "build"]
            )
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
    func run(_ invocations: [IDEXcodeInvocation], completion: (@MainActor ([IDEXcodeOutcome]) -> Void)?) {
        guard !isRunningTasks, let root = rootURL, model != nil, !invocations.isEmpty else {
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
            var outcomes: [IDEXcodeOutcome] = []
            defer {
                if generation == self.runGeneration {
                    self.clearStatus()
                    self.isRunningTasks = false
                    self.runningTasks = []
                    self.runTask = nil
                }
                if generation == self.runGeneration, self.projectGeneration == projectToken { completion?(outcomes) }
            }
            await self.environment.prepareToRun()
            guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
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
                if case .untrusted = self.syncState, let model = self.model {
                    self.syncState = .synced(modules: model.targets.count, dependencies: model.packageCount)
                }
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
            self.setStatus("Running \(invocations[0].title)…")
            self.console.reset()
            self.console.appendNote("Project: \(root.path)")
            self.onActivity?()
            guard let executable = Self.resolveXcodebuild(environment: environment) else {
                self.console.appendNote("No xcodebuild found. Install Xcode and run xcode-select.")
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
                self.console.appendNote(String(format: "xcodebuild exited %d in %.1fs", outcome.status, outcome.duration))
                if outcome.status != 0 { break }
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken else { return }
            self.console.markFinished()
        }
    }

    private func publishDiagnostics(from outcome: IDEXcodeOutcome, root: URL) {
        let messages = SwiftBuildOutputParser.parse(outcome.output)
        let lookup = bufferText
        let diagnostics = SwiftBuildOutputParser.diagnostics(from: messages, baseDirectory: root) { url in
            lookup?(url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        onBuildDiagnostics?(diagnostics)
    }

    // MARK: Process

    private func launch(
        _ invocation: IDEXcodeInvocation, executable: String, root: URL, environment: [String: String]?
    ) async -> IDEXcodeOutcome {
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
                return IDEXcodeOutcome(
                    invocation: invocation, status: result.exit.status, duration: result.duration, cancelled: true, output: output
                )
            }
            for line in buffer.flush() { console.appendProcessLine(line) }
            return IDEXcodeOutcome(
                invocation: invocation, status: result.exit.status, duration: result.duration,
                cancelled: result.cancelled || Task.isCancelled, output: output
            )
        } catch {
            await Task.yield()
            console.appendNote("xcodebuild failed to start")
            return IDEXcodeOutcome(
                invocation: invocation, status: 1, duration: 0,
                cancelled: Task.isCancelled || projectGeneration != projectToken, output: ""
            )
        }
    }

    /// The first executable named `xcodebuild` on PATH, else `/usr/bin/xcodebuild` (the developer-tools shim).
    static func resolveXcodebuild(environment: [String: String]?) -> String? {
        let path = environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fileManager = FileManager.default
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("xcodebuild").path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        if environment == nil, fileManager.isExecutableFile(atPath: "/usr/bin/xcodebuild") { return "/usr/bin/xcodebuild" }
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
                id: "xcode", systemImage: "hammer", title: "Xcode", shortcut: nil, tint: .blue,
                placement: .trailingTop, isOpen: workspace.showsProjectSidebar,
                toggle: { [weak workspace] in workspace?.toggleProjectSidebar() },
                order: IDEToolWindow.Order.gradleSidebar
            ))
        }
        if showsConsole {
            windows.append(workspace.bottomToolWindow(
                .xcode, "text.alignleft", "Xcode", nil, .blue, .trailingBottom,
                order: IDEToolWindow.Order.xcodeConsole
            ))
        }
        return windows
    }

    func toolbarItems(for _: IDEWorkspace) -> [IDEToolbarItem] {
        guard isActive else { return [] }
        return [.button(
            id: "xcode.build", order: IDEToolbarItem.Order.build + 25, systemImage: "hammer", help: "xcodebuild",
            action: { [weak self] in self?.build() }
        )]
    }

    func bottomTabs(for _: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard showsConsole else { return [] }
        return [IDEBottomTabContribution(
            tab: .xcode, order: IDEBottomPanelTab.Order.xcode,
            item: { workspace in
                AnyView(IDEXcodeTabItem(
                    isSelected: workspace.isBottomTabSelected(.xcode),
                    isRunning: workspace.xcode.isBusy,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.xcode) }
                ))
            },
            content: { workspace in
                AnyView(IDEProjectConsoleView(
                    log: workspace.xcode.console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { _ in AnyView(IDEXcodeConsoleControls()) },
            staysWhenLastShellCloses: true
        )]
    }

    func makeSidebar() -> AnyView {
        AnyView(IDEXcodeSidebarPanel())
    }
}

// MARK: - Chrome

struct IDEXcodeSidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let system = workspace.xcode
        VStack(alignment: .leading, spacing: 0) {
            header(system)
            if case let .failed(summary) = system.syncState {
                pinned(summary)
            } else if let model = system.model {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Project")
                        infoRow(symbol: "hammer", title: model.name, detail: model.format == .xcproj ? "project.xcproj" : "pbxproj")
                        section("Tasks")
                        ForEach(system.tasks, id: \.path) { task in
                            taskRow(task, system: system)
                        }
                        if !model.targets.isEmpty {
                            section("Targets")
                            ForEach(model.targets, id: \.name) { target in
                                infoRow(symbol: target.kind.systemImage, title: target.name, detail: target.kind.rawValue)
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                pinned("No Xcode project")
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

    private func header(_ system: IDEXcodeProjectSystem) -> some View {
        HStack(spacing: 2) {
            IDEPanelTitle("Xcode")
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

    private func taskRow(_ task: IDEProjectTask, system: IDEXcodeProjectSystem) -> some View {
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
}

struct IDEXcodeConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if workspace.xcode.isBusy {
                Button("Cancel", action: { workspace.xcode.cancelTasks() })
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Button(action: { workspace.xcode.reload() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Reload")
                    .accessibilityLabel("Reload")
            }
            Button(action: copyOutput) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Copy Xcode Output")
                .accessibilityLabel("Copy Xcode Output")
        }
    }

    private func copyOutput() {
        let text = workspace.xcode.console.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct IDEXcodeTabItem: View {
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
                Image(systemName: "hammer")
                    .font(.system(size: 10))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12)
            }
            Text("Xcode")
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
        .accessibilityLabel(isRunning ? "Xcode, running" : "Xcode")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
