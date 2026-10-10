import Darwin
import Foundation
import JavaIntelligence
import Observation
import SubprocessKit
import SwiftUI

extension IDEBottomPanelTab {
    static let npm = IDEBottomPanelTab("npm")
}

/// An npm project: the root package.json. Parsing the manifest is the sync. Scripts run as
/// `npm run <name>` through SubprocessKit, after the user trusts this folder. Trust is a separate
/// file from Gradle's, and this system does not call `environment.requestTrust` — that closure
/// asks about Gradle build scripts.
@MainActor
@Observable
final class IDENpmProjectSystem: IDEProjectSystem {
    static let dependenciesDiagramID = "npm:dependencies"
    static let lastScriptKeyPrefix = "umbra.npm.lastScript."

    let id = "npm"
    let displayName = "npm"
    var consoleTab: IDEBottomPanelTab? { .npm }

    @ObservationIgnored var environment = IDEProjectEnvironment()
    /// The npm trust sheet. The window sets it. Nil answers "no" and stores nothing.
    @ObservationIgnored var trustPrompt: (@MainActor (URL) async -> Bool)?
    /// Reveals the npm console. Called when a run starts, including one that only explains why it did not.
    @ObservationIgnored var onActivity: (@MainActor () -> Void)?
    /// The child's whole environment. Nil inherits, so a real npm can find node. Tests set a PATH
    /// that contains only a fake `npm`.
    @ObservationIgnored var launchEnvironment: [String: String]?

    private(set) var syncState: IDEProjectSyncState = .notDetected
    private(set) var runningTasks: [String] = []
    private(set) var console = IDEProjectConsoleLog()
    private(set) var tasks: [IDEProjectTask] = []
    private(set) var hasConfigurationChanges = false
    private(set) var isRunningTasks = false

    @ObservationIgnored private let status: IDEProjectStatus
    @ObservationIgnored private let trustStore: GradleTrustStore
    @ObservationIgnored private let scriptDefaults: UserDefaults
    @ObservationIgnored private var projectRootURL: URL?
    @ObservationIgnored private var manifest: IDENpmManifest?
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var manifestWatcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var statusMessage: String?

    static var defaultTrustStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("npm-trust.json")
    }

    static func lastScriptKey(for root: URL) -> String {
        lastScriptKeyPrefix + root.standardizedFileURL.path
    }

    static func dependenciesDiagramRequest() -> IDEDiagramRequest {
        IDEDiagramRequest(
            id: dependenciesDiagramID, title: "Dependencies", symbolName: "shippingbox", presentation: .dependencies
        )
    }

    init(
        status: IDEProjectStatus,
        trustStore: GradleTrustStore = IDESharedServices.shared.npmTrust,
        scriptDefaults: UserDefaults = .standard
    ) {
        self.status = status
        self.trustStore = trustStore
        self.scriptDefaults = scriptDefaults
    }

    var isActive: Bool {
        if case .notDetected = syncState { return false }
        return projectRootURL != nil
    }

    var isBusy: Bool { isRunningTasks }

    var sourceRootPaths: Set<String> { [] }

    /// `start` when the manifest has it, otherwise the script last chosen in this folder, otherwise the first.
    var preferredScript: String? {
        let names = tasks.map(\.name)
        guard !names.isEmpty else { return nil }
        if names.contains("start") { return "start" }
        if let root = projectRootURL,
           let remembered = scriptDefaults.string(forKey: Self.lastScriptKey(for: root)),
           names.contains(remembered) {
            return remembered
        }
        return names.first
    }

    func projectDidChange(root: URL?) {
        clearStatus()
        projectGeneration += 1
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        isRunningTasks = false
        runningTasks = []
        stopManifestWatcher()
        hasConfigurationChanges = false
        console = IDEProjectConsoleLog()
        let standardized = root?.standardizedFileURL
        projectRootURL = standardized
        guard let standardized else {
            manifest = nil
            tasks = []
            syncState = .notDetected
            return
        }
        applyManifest(at: standardized)
        if FileManager.default.fileExists(atPath: standardized.appendingPathComponent("package.json").path) {
            startManifestWatcher(root: standardized)
        }
    }

    func reload() {
        guard let root = projectRootURL else { return }
        hasConfigurationChanges = false
        applyManifest(at: root)
        if manifest != nil {
            startManifestWatcher(root: root)
        } else {
            stopManifestWatcher()
        }
        guard manifest != nil, !trustStore.isTrusted(root) else { return }
        let generation = projectGeneration
        Task { [weak self] in
            guard let self else { return }
            let trusted = await self.trustPrompt?(root) ?? false
            guard self.projectGeneration == generation, !Task.isCancelled else { return }
            self.trustStore.setTrusted(trusted, for: root)
            guard let manifest = self.manifest else { return }
            self.syncState = trusted
                ? .synced(modules: 1, dependencies: manifest.dependencyCount)
                : .untrusted
        }
    }

    func dismissConfigurationChanges() {
        hasConfigurationChanges = false
    }

    func cancelSync() {}

    func cancelTasks() {
        runTask?.cancel()
    }

    /// Runs the named scripts in order and stops after the first non-zero exit. Does not remember a script.
    func runTasks(_ names: [String]) {
        guard !isRunningTasks, let root = projectRootURL, manifest != nil else { return }
        let scripts = names.filter { name in tasks.contains { $0.path == name } }
        guard !scripts.isEmpty else { return }
        runGeneration += 1
        let generation = runGeneration
        let projectToken = projectGeneration
        isRunningTasks = true
        runningTasks = scripts
        onActivity?()
        let prompt = trustPrompt
        let environment = launchEnvironment
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.runGeneration {
                    self.clearStatus()
                    self.isRunningTasks = false
                    self.runningTasks = []
                    self.runTask = nil
                }
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
                    self.syncState = .synced(modules: 1, dependencies: manifest.dependencyCount)
                }
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
            let message = "Running npm \(scripts[0])…"
            self.setStatus(message)
            self.console.reset()
            self.console.appendNote("Project: \(root.path)")
            self.onActivity?()
            guard let executable = Self.resolveNpm(environment: environment) else {
                self.console.appendNote("No npm found on PATH")
                self.console.markFinished()
                return
            }
            for name in scripts {
                guard generation == self.runGeneration, self.projectGeneration == projectToken, !Task.isCancelled else { return }
                self.runningTasks = [name]
                self.console.appendNote("npm run \(name)")
                let outcome = await self.launch(executable: executable, script: name, root: root, environment: environment)
                guard generation == self.runGeneration, self.projectGeneration == projectToken else { return }
                if outcome.cancelled {
                    self.console.appendNote("Cancelled")
                    break
                }
                self.console.appendNote(String(format: "npm exited %d in %.1fs", outcome.status, outcome.duration))
                if outcome.status != 0 { break }
            }
            guard generation == self.runGeneration, self.projectGeneration == projectToken else { return }
            self.console.markFinished()
        }
    }

    /// Remembers `name` for this folder, then runs it. The Build button does not come through here.
    func runScript(_ name: String) {
        if let root = projectRootURL {
            scriptDefaults.set(name, forKey: Self.lastScriptKey(for: root))
        }
        runTasks([name])
    }

    func build() {
        guard tasks.contains(where: { $0.path == "build" }) else { return }
        runTasks(["build"])
    }

    func stop() {
        clearStatus()
        projectGeneration += 1
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        isRunningTasks = false
        runningTasks = []
        stopManifestWatcher()
        projectRootURL = nil
        manifest = nil
        tasks = []
        syncState = .notDetected
    }

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if workspace.projectSystems.active?.id == id {
            windows.append(IDEToolWindow(
                id: "npm", systemImage: "shippingbox", title: "npm", shortcut: nil, tint: .orange,
                placement: .trailingTop, isOpen: workspace.showsProjectSidebar,
                toggle: { [weak workspace] in workspace?.toggleProjectSidebar() },
                order: IDEToolWindow.Order.gradleSidebar
            ))
        }
        if showsConsole {
            windows.append(workspace.bottomToolWindow(
                .npm, "text.alignleft", "npm", nil, .orange, .trailingBottom,
                order: IDEToolWindow.Order.npmConsole
            ))
        }
        return windows
    }

    func toolbarItems(for _: IDEWorkspace) -> [IDEToolbarItem] {
        guard isActive, tasks.contains(where: { $0.path == "build" }) else { return [] }
        return [.button(
            id: "npm.build", order: IDEToolbarItem.Order.build + 10, systemImage: "hammer", help: "npm run build",
            action: { [weak self] in self?.runTasks(["build"]) }
        )]
    }

    func bottomTabs(for _: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard showsConsole else { return [] }
        return [IDEBottomTabContribution(
            tab: .npm, order: IDEBottomPanelTab.Order.npm,
            item: { workspace in
                AnyView(IDENpmTabItem(
                    isSelected: workspace.isBottomTabSelected(.npm),
                    isRunning: workspace.npm.isBusy,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.npm) }
                ))
            },
            content: { workspace in
                AnyView(IDEProjectConsoleView(
                    log: workspace.npm.console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { _ in AnyView(IDENpmConsoleControls()) },
            staysWhenLastShellCloses: true
        )]
    }

    func makeSidebar() -> AnyView {
        AnyView(IDENpmSidebarPanel())
    }

    func loadDiagram(
        _ request: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace _: IDEWorkspace
    ) async -> IDEDiagramLoad? {
        guard request.id == Self.dependenciesDiagramID else { return nil }
        guard let manifest else {
            return IDEDiagramLoad(document: .empty(title: request.title), failure: "This folder has no package.json.")
        }
        return IDEDiagramLoad(document: IDENpmDiagram.document(manifest: manifest, title: request.title))
    }

    // MARK: - Manifest

    private func applyManifest(at root: URL) {
        let file = root.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            manifest = nil
            tasks = []
            syncState = .notDetected
            return
        }
        guard let data = try? Data(contentsOf: file),
              let parsed = IDENpmManifest.parse(data: data, folderName: root.lastPathComponent) else {
            manifest = nil
            tasks = []
            syncState = .failed(summary: "Couldn't read package.json")
            return
        }
        manifest = parsed
        tasks = parsed.scripts.map {
            IDEProjectTask(path: $0.name, name: $0.name, module: ":", group: "scripts", summary: $0.command)
        }
        if trustStore.decision(for: root) == false {
            syncState = .untrusted
        } else {
            syncState = .synced(modules: 1, dependencies: parsed.dependencyCount)
        }
    }

    private func startManifestWatcher(root: URL) {
        stopManifestWatcher()
        let file = root.appendingPathComponent("package.json")
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setCancelHandler { close(fd) }
        let watched = root.standardizedFileURL
        source.setEventHandler { [weak self, weak source] in
            let flags = source?.data ?? []
            Task { @MainActor in
                guard let self, self.projectRootURL?.standardizedFileURL == watched else { return }
                self.hasConfigurationChanges = true
                if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                    self.startManifestWatcher(root: watched)
                }
            }
        }
        manifestWatcher = source
        source.resume()
    }

    private func stopManifestWatcher() {
        let source = manifestWatcher
        manifestWatcher = nil
        source?.cancel()
    }

    // MARK: - Process

    private struct LaunchOutcome {
        var status: Int32
        var duration: TimeInterval
        var cancelled: Bool
    }

    private func launch(
        executable: String, script: String, root: URL, environment: [String: String]?
    ) async -> LaunchOutcome {
        var request = SubprocessRequest(executable: executable, arguments: ["run", script])
        request.workingDirectory = root
        request.environment = environment
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = nil
        let buffer = IDENpmOutputBuffer()
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
            guard projectGeneration == projectToken else {
                return LaunchOutcome(status: result.exit.status, duration: result.duration, cancelled: true)
            }
            for line in buffer.flush() { console.appendProcessLine(line) }
            return LaunchOutcome(
                status: result.exit.status, duration: result.duration, cancelled: result.cancelled || Task.isCancelled
            )
        } catch {
            await Task.yield()
            guard projectGeneration == projectToken else {
                return LaunchOutcome(status: 1, duration: 0, cancelled: true)
            }
            console.appendNote("npm failed to start")
            return LaunchOutcome(status: 1, duration: 0, cancelled: Task.isCancelled)
        }
    }

    /// The first executable named `npm` on PATH. The lookup uses `launchEnvironment` when tests set it.
    private static func resolveNpm(environment: [String: String]?) -> String? {
        let path = environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fileManager = FileManager.default
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("npm").path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
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
}

/// Splits live process output into lines. One buffer per stream; a partial line waits for its newline.
private final class IDENpmOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func consume(_ data: Data, source: SubprocessOutputSource) -> [IDEProjectOutputLine] {
        let stream: IDEProjectOutputLine.Stream = source == .stdout ? .stdout : .stderr
        lock.lock()
        defer { lock.unlock() }
        var buffer = source == .stdout ? stdout : stderr
        buffer.append(data)
        let lines = takeLines(from: &buffer)
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

    private func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var chunk = buffer[..<newline]
            buffer.removeSubrange(..<buffer.index(after: newline))
            if chunk.last == 0x0D { chunk = chunk.dropLast() }
            lines.append(String(decoding: chunk, as: UTF8.self))
        }
        return lines
    }
}

// MARK: - Chrome

/// Which script the arrow keys, Return, and ⌘C act on. Names in a package.json are unique.
enum IDENpmScriptList {
    static func neighbor(of selected: String?, in names: [String], delta: Int) -> String? {
        guard !names.isEmpty else { return nil }
        let index: Int
        if let selected, let current = names.firstIndex(of: selected) {
            index = min(max(current + delta, 0), names.count - 1)
        } else {
            index = delta < 0 ? names.count - 1 : 0
        }
        return names[index]
    }
}

struct IDENpmSidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var selectedName: String?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case let .failed(summary) = workspace.npm.syncState {
                pinned(summary)
            } else if workspace.npm.tasks.isEmpty {
                pinned("No scripts in package.json")
            } else {
                GeometryReader { proxy in
                    ScrollViewReader { scroller in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(workspace.npm.tasks, id: \.name) { task in
                                    IDENpmScriptRow(
                                        task: task,
                                        isSelected: selectedName == task.name,
                                        isRunDisabled: workspace.npm.isRunningTasks,
                                        onSelect: { select(task.name) },
                                        onRun: { run(task.name) },
                                        onCopy: { copy(task.name) }
                                    )
                                    .id(task.name)
                                }
                            }
                            .padding(.vertical, IDEAppearance.Spacing.xs)
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                        }
                        .focusable()
                        .focusEffectDisabled()
                        .focused($isListFocused)
                        .onKeyPress(phases: [.down, .repeat]) { press in
                            handleKey(press, scroller: scroller)
                        }
                        .background {
                            IDENpmScriptKeyMonitor(isActive: isListFocused, copy: copySelectedScript)
                        }
                    }
                }
                .onChange(of: workspace.npm.tasks.map(\.name)) { _, names in
                    if let selectedName, !names.contains(selectedName) {
                        self.selectedName = nil
                    }
                }
            }
            if case .untrusted = workspace.npm.syncState {
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

    private var header: some View {
        HStack(spacing: 2) {
            IDEPanelTitle("npm")
                .frame(maxWidth: .infinity, alignment: .leading)
            if workspace.npm.isRunningTasks {
                Button(action: { workspace.npm.cancelTasks() }) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .help("Stop")
                .accessibilityLabel("Stop")
            }
            Button(action: { workspace.npm.reload() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Reload")
            .accessibilityLabel("Reload")
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
    }

    private func select(_ name: String) {
        selectedName = name
        isListFocused = true
    }

    private func run(_ name: String) {
        select(name)
        guard !workspace.npm.isRunningTasks else { return }
        workspace.npm.runScript(name)
    }

    private func moveSelection(by delta: Int, scroller: ScrollViewProxy) {
        let names = workspace.npm.tasks.map(\.name)
        guard let name = IDENpmScriptList.neighbor(of: selectedName, in: names, delta: delta) else { return }
        selectedName = name
        isListFocused = true
        scroller.scrollTo(name)
    }

    private func handleKey(_ press: KeyPress, scroller: ScrollViewProxy) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveSelection(by: -1, scroller: scroller)
            return .handled
        case .downArrow:
            moveSelection(by: 1, scroller: scroller)
            return .handled
        case .return:
            guard let selectedName, !workspace.npm.isRunningTasks else { return .ignored }
            run(selectedName)
            return .handled
        default:
            return .ignored
        }
    }

    private func copySelectedScript() -> Bool {
        guard let selectedName, workspace.npm.tasks.contains(where: { $0.name == selectedName }) else { return false }
        copy(selectedName)
        return true
    }

    private func copy(_ name: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
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

private struct IDENpmScriptRow: View {
    let task: IDEProjectTask
    let isSelected: Bool
    let isRunDisabled: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button(action: onRun) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isRunDisabled)
            .focusable(false)
            .help("npm run \(task.name)")
            .accessibilityLabel("Run \(task.name)")

            VStack(alignment: .leading, spacing: 0) {
                Text(task.name)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                if !task.summary.isEmpty {
                    Text(task.summary)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onRun)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu {
            Button("Run") { onRun() }
                .disabled(isRunDisabled)
            Button("Copy") { onCopy() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return IDEAppearance.ColorToken.selection }
        return isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear
    }
}

/// Claims ⌘C while the script list is focused. The Edit menu's Copy item otherwise goes to the
/// editor, which shares the window, and SwiftUI does not deliver that shortcut to `onKeyPress`.
private struct IDENpmScriptKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    var copy: () -> Bool

    func makeNSView(context: Context) -> IDENpmScriptKeyView {
        IDENpmScriptKeyView()
    }

    func updateNSView(_ view: IDENpmScriptKeyView, context: Context) {
        view.isActive = isActive
        view.copySelection = copy
    }
}

final class IDENpmScriptKeyView: NSView {
    var isActive = false
    var copySelection: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isActive, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return super.performKeyEquivalent(with: event)
        }
        return copySelection()
    }
}

struct IDENpmConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            elapsedTimeView
            if workspace.npm.isBusy {
                Button("Cancel", action: { workspace.npm.cancelTasks() })
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Button(action: { workspace.npm.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Reload")
                .accessibilityLabel("Reload")
            }
            Button(action: copyOutput) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Copy npm Output")
            .accessibilityLabel("Copy npm Output")
        }
    }

    @ViewBuilder
    private var elapsedTimeView: some View {
        if let startedAt = workspace.npm.console.startedAt {
            if workspace.npm.isBusy {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.formattedElapsed(context.date.timeIntervalSince(startedAt)))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            } else if let finishedAt = workspace.npm.console.finishedAt {
                Text(Self.formattedElapsed(finishedAt.timeIntervalSince(startedAt)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    private func copyOutput() {
        let text = workspace.npm.console.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func formattedElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct IDENpmTabItem: View {
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
                Image(systemName: "shippingbox")
                    .font(.system(size: 10))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12)
            }
            Text("npm")
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
        .accessibilityLabel(isRunning ? "npm, running" : "npm")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
