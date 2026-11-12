import AppKit
import Foundation
import Observation

/// How often Settings ▸ Agent ▸ Adapters may look at the registry on its own. A check reads
/// metadata only; installing an update always needs the user's approval.
enum IDEACPUpdateCheckPolicy: String, CaseIterable, Identifiable, Sendable {
    case whenOpened
    case daily
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenOpened: "When Settings opens"
        case .daily: "Once a day"
        case .manual: "Only when I ask"
        }
    }

    /// Minimum time between automatic checks. Nil never checks on its own.
    var interval: TimeInterval? {
        switch self {
        case .whenOpened: 6 * 3_600
        case .daily: 24 * 3_600
        case .manual: nil
        }
    }
}

/// The app-wide owner of managed ACP adapters: what is installed, what is available, what is
/// running an operation, and the operations themselves. Network, disk and process work happens
/// in `IDEACPAdapterInstaller` and `IDEACPAdapterStore` off the main actor; this class only holds
/// state and applies the results.
@MainActor
@Observable
final class IDEACPAdapterManager {
    struct AdapterState: Identifiable, Equatable {
        var entry: IDEACPAdapterEntry
        var phase: IDEACPAdapterPhase = .notInstalled
        /// Verified versions on disk, newest install first.
        var versions: [IDEACPInstallManifest] = []
        var activeVersion: String?
        var previousVersion: String?
        var available: String?
        var advisories: [String] = []
        var progress: IDEACPInstallProgress?
        /// The last registry check failed (offline, registry error). Not an install failure.
        var checkError: IDEACPAdapterError?
        var diagnostics = ""

        var id: String { entry.id }
        var activeManifest: IDEACPInstallManifest? { versions.first { $0.version == activeVersion } }
    }

    enum NodeStatus: Equatable {
        case unknown
        case found(IDEACPNodeInstallation)
        case missing
    }

    /// The app-wide manager. Tests replace it with one over a temporary folder.
    static var shared = IDEACPAdapterManager.makeProduction()

    private(set) var states: [String: AdapterState]
    private(set) var node: NodeStatus = .unknown
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var hasLoaded = false

    var updatePolicy: IDEACPUpdateCheckPolicy {
        didSet { defaults.set(updatePolicy.rawValue, forKey: Self.policyKey) }
    }

    let store: IDEACPAdapterStore
    let isSandboxed: Bool

    @ObservationIgnored private let registry: IDEACPNpmRegistry
    @ObservationIgnored private let installer: IDEACPAdapterInstaller
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pathProvider: @Sendable () async -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var systemPackageCache: [String: String?] = [:]
    /// Adapters whose interrupted installs have been cleaned up. Recovery runs once per adapter, at
    /// the first load, and never while an operation is running: it deletes every staging folder.
    @ObservationIgnored private var recovered: Set<String> = []

    static let policyKey = "umbra.agent.acpAdapterUpdateCheck"

    init(
        store: IDEACPAdapterStore,
        registry: IDEACPNpmRegistry,
        installer: IDEACPAdapterInstaller,
        defaults: UserDefaults = .standard,
        isSandboxed: Bool = IDEAgentSandbox.isAppSandboxed,
        pathProvider: @escaping @Sendable () async -> String = IDEACPAdapterManager.loginPath,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.registry = registry
        self.installer = installer
        self.defaults = defaults
        self.isSandboxed = isSandboxed
        self.pathProvider = pathProvider
        self.now = now
        updatePolicy = defaults.string(forKey: Self.policyKey).flatMap(IDEACPUpdateCheckPolicy.init(rawValue:)) ?? .whenOpened
        var initial: [String: AdapterState] = [:]
        for entry in IDEACPAdapterCatalog.entries { initial[entry.id] = AdapterState(entry: entry) }
        states = initial
        if let cached = store.readCachedCheck() {
            lastChecked = cached.checkedAt
            for (id, version) in cached.latest { states[id]?.available = version }
        }
    }

    /// The real thing: the real registry, npm and processes. `root` is Application Support unless a
    /// live test installs into a folder of its own.
    static func makeProduction(root: URL = IDEACPAdapterStore.defaultRoot) -> IDEACPAdapterManager {
        let store = IDEACPAdapterStore(root: root)
        let registry = IDEACPNpmRegistry()
        let environment = IDEACPAdapterInstaller.Environment(
            store: store, registry: registry,
            locateNode: {
                let path = await loginPath()
                return await IDEACPNodeRuntime.detect(pathValue: path, environment: AgentCommandEnvironment.make(javaHome: nil))
            },
            smokeTest: { launch in
                let login = await IDELoginShellPath.shared.entries()
                let environment = AgentCommandEnvironment.make(javaHome: nil, loginPath: login)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("umbra-acp-check-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let definition = IDEACPDefinition(name: "Adapter check", command: launch.executable, args: launch.args)
                return await IDEACPConnectionTest.run(
                    definition: definition, launch: launch, workingDirectory: directory,
                    environment: environment, leases: nil, timeout: .seconds(20))
            })
        return IDEACPAdapterManager(
            store: store, registry: registry, installer: IDEACPAdapterInstaller(environment: environment))
    }

    /// The `PATH` agents run with: the login shell's entries, then the base directories.
    nonisolated static func loginPath() async -> String {
        let login = await IDELoginShellPath.shared.entries()
        return AgentCommandEnvironment.make(javaHome: nil, loginPath: login)["PATH"]
            ?? AgentCommandEnvironment.basePath.joined(separator: ":")
    }

    // MARK: - Loading

    /// Reads what is on disk. The first call per adapter also repairs an interrupted install
    /// (leftover staging, a version without a manifest, a damaged `active.json`). Safe to call
    /// repeatedly and from several views: later calls only read, so they cannot remove the staging
    /// folder of an install that is running right now.
    func load() async {
        let store = store
        let ids = IDEACPAdapterCatalog.managedEntries.map(\.id)
        let toRecover = Set(ids.filter { id in
            !recovered.contains(id) && tasks[id] == nil && !(states[id]?.phase.isBusy ?? false)
        })
        recovered.formUnion(toRecover)
        let snapshots = await Task.detached(priority: .utility) {
            ids.map { (id: $0, snapshot: Self.readDisk(store: store, id: $0, recover: toRecover.contains($0))) }
        }.value
        for item in snapshots { applyDisk(item.snapshot, id: item.id) }
        hasLoaded = true
    }

    private struct DiskSnapshot: Sendable {
        var versions: [IDEACPInstallManifest]
        var active: IDEACPActiveManifest?
        var diagnostics: String
    }

    private nonisolated static func readDisk(store: IDEACPAdapterStore, id: String, recover: Bool) -> DiskSnapshot {
        if recover { store.recover(id) }
        let versions = store.installedVersions(id)
        let active = (try? store.readActive(id)).flatMap { manifest in
            versions.contains { $0.version == manifest.version } ? manifest : nil
        }
        return DiskSnapshot(versions: versions, active: active, diagnostics: store.readDiagnostics(id))
    }

    private func applyDisk(_ snapshot: DiskSnapshot, id: String) {
        guard var state = states[id] else { return }
        state.versions = snapshot.versions
        state.activeVersion = snapshot.active?.version
        state.previousVersion = snapshot.active?.previous.flatMap { previous in
            snapshot.versions.contains { $0.version == previous } ? previous : nil
        }
        state.diagnostics = snapshot.diagnostics
        switch state.phase {
        case .notInstalled, .ready, .updateAvailable:
            state.phase = Self.settledPhase(state)
        default:
            break
        }
        states[id] = state
    }

    /// `ready` or `updateAvailable` (or `notInstalled`) from what is installed and known.
    private static func settledPhase(_ state: AdapterState) -> IDEACPAdapterPhase {
        guard let installed = state.activeVersion else { return .notInstalled }
        if let available = state.available, isNewer(available, than: installed) {
            return .updateAvailable(installed: installed, available: available, security: !state.advisories.isEmpty)
        }
        return .ready(version: installed)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        if let lhs = IDEACPSemver(candidate), let rhs = IDEACPSemver(installed) { return lhs > rhs }
        return candidate != installed
    }

    func refreshNode() async {
        let path = await pathProvider()
        let found = await IDEACPNodeRuntime.detect(pathValue: path, environment: AgentCommandEnvironment.make(javaHome: nil))
        node = found.map(NodeStatus.found) ?? .missing
    }

    // MARK: - State machine

    @discardableResult
    private func apply(_ event: IDEACPAdapterEvent, to id: String) -> Bool {
        guard var state = states[id], let next = IDEACPAdapterMachine.transition(from: state.phase, event: event) else {
            return false
        }
        state.phase = next
        states[id] = state
        return true
    }

    private func settle(_ id: String) {
        guard var state = states[id] else { return }
        state.phase = Self.settledPhase(state)
        state.progress = nil
        states[id] = state
    }

    /// Dismisses a failure: the adapter goes back to what is really on disk.
    func acknowledgeFailure(_ id: String) {
        guard case .failed = states[id]?.phase else { return }
        settle(id)
    }

    // MARK: - Update checks

    func checkIfDue() async {
        guard let interval = updatePolicy.interval, !isSandboxed else { return }
        if let lastChecked, now().timeIntervalSince(lastChecked) < interval { return }
        await checkForUpdates()
    }

    /// Reads the registry's `latest` and the advisories for the installed version. Metadata only:
    /// no tarball is fetched and nothing is run.
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var latest: [String: String] = [:]
        for entry in IDEACPAdapterCatalog.managedEntries {
            guard let source = entry.npm else { continue }
            do {
                let document = try await registry.latest(package: source.package)
                latest[entry.id] = document.version
                states[entry.id]?.available = document.version
                states[entry.id]?.checkError = nil
                guard let state = states[entry.id], let installed = state.activeVersion else { continue }
                switch state.phase {
                case .ready, .updateAvailable:
                    if Self.isNewer(document.version, than: installed) {
                        let advisories = (try? await registry.advisories(package: source.package, version: installed)) ?? []
                        states[entry.id]?.advisories = advisories
                        apply(.updateFound(available: document.version, security: !advisories.isEmpty), to: entry.id)
                    } else {
                        states[entry.id]?.advisories = []
                        apply(.upToDate, to: entry.id)
                    }
                default:
                    break
                }
            } catch {
                states[entry.id]?.checkError = Self.normalize(error)
            }
        }
        lastChecked = now()
        if !latest.isEmpty {
            store.writeCachedCheck(IDEACPAdapterStore.CachedCheck(latest: latest, checkedAt: now()))
        }
    }

    // MARK: - Install and update

    /// Resolves the version, runs the trust checks and describes the install. Nothing is
    /// downloaded or run. The result goes to the approval sheet.
    func prepareInstall(_ id: String) async throws -> IDEACPInstallProposal {
        guard !isSandboxed else { throw IDEACPAdapterError.sandboxed }
        guard let state = states[id], state.entry.isManaged else { throw IDEACPAdapterError.notManaged }
        guard !state.phase.isBusy, tasks[id] == nil else {
            throw IDEACPAdapterError.inUse("Another operation on \(state.entry.name) is still running.")
        }
        let security: Bool
        if case .updateAvailable(_, _, let flag) = state.phase { security = flag } else { security = false }
        do {
            let proposal = try await installer.propose(
                entry: state.entry, updatingFrom: state.activeVersion, security: security)
            states[id]?.checkError = nil
            return proposal
        } catch {
            let normalized = Self.normalize(error)
            if case .offline = normalized { states[id]?.checkError = normalized }
            throw normalized
        }
    }

    /// Starts the install the user approved. Progress and the outcome arrive as state changes.
    func install(_ proposal: IDEACPInstallProposal, settings: IDEAgentSettings) {
        let id = proposal.entryID
        guard !isSandboxed, tasks[id] == nil, let state = states[id], state.entry.isManaged else { return }
        let entry = state.entry
        let event: IDEACPAdapterEvent = proposal.updatingFrom != nil
            ? .beginUpdate(to: proposal.version) : .beginInstall
        guard apply(event, to: id) else { return }
        states[id]?.progress = nil

        let (stream, continuation) = AsyncStream.makeStream(of: IDEACPInstallProgress.self)
        let installer = installer
        let task = Task { [weak self] in
            let reader = Task { @MainActor [weak self] in
                for await progress in stream { self?.noteProgress(progress, id: id) }
            }
            do {
                let manifest = try await installer.install(proposal: proposal, entry: entry) { continuation.yield($0) }
                continuation.finish()
                await reader.value
                await self?.finishInstall(entry: entry, manifest: manifest, settings: settings)
            } catch {
                continuation.finish()
                await reader.value
                await self?.finishFailure(id: id, error: Self.normalize(error))
            }
        }
        tasks[id] = task
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    private func noteProgress(_ progress: IDEACPInstallProgress, id: String) {
        apply(.advance(progress.step), to: id)
        states[id]?.progress = progress
    }

    private func finishInstall(entry: IDEACPAdapterEntry, manifest: IDEACPInstallManifest, settings: IDEAgentSettings) async {
        tasks[entry.id] = nil
        if states[entry.id]?.available == nil { states[entry.id]?.available = manifest.version }
        states[entry.id]?.advisories = []
        await load()
        apply(.activated(version: manifest.version), to: entry.id)
        settle(entry.id)
        settings.adoptManagedAdapter(entry)
        await settings.refreshACPPath()
    }

    private func finishFailure(id: String, error: IDEACPAdapterError) async {
        tasks[id] = nil
        await load()
        if error == .cancelled {
            apply(.cancelled, to: id)
            settle(id)
        } else {
            apply(.failed(error), to: id)
            states[id]?.progress = nil
        }
    }

    // MARK: - Versions

    func makeActive(_ id: String, version: String) async throws {
        guard let state = states[id], !state.phase.isBusy else {
            throw IDEACPAdapterError.inUse("An operation on this adapter is still running.")
        }
        let store = store
        _ = try await Task.detached { try store.restore(id, version: version) }.value
        await load()
        settle(id)
    }

    func restorePrevious(_ id: String) async throws {
        guard let previous = states[id]?.previousVersion else { throw IDEACPAdapterError.noPreviousVersion }
        try await makeActive(id, version: previous)
    }

    func removeVersion(_ id: String, version: String) async throws {
        let store = store
        try await Task.detached { try store.removeVersion(id, version: version) }.value
        await load()
        settle(id)
    }

    func remove(_ id: String) async throws {
        guard let state = states[id], !state.phase.isBusy else {
            throw IDEACPAdapterError.inUse("An operation on this adapter is still running.")
        }
        let store = store
        try await Task.detached { try store.removeAdapter(id) }.value
        states[id]?.versions = []
        states[id]?.activeVersion = nil
        states[id]?.previousVersion = nil
        apply(.removed, to: id)
        settle(id)
    }

    /// Chats using any version of this adapter right now.
    func runningUses(_ id: String) -> Int { store.leases.totalCount(adapterID: id) }

    func isInUse(_ id: String, version: String) -> Bool { store.leases.isLeased(adapterID: id, version: version) }

    func reveal(_ id: String) {
        let directory = store.adapterDirectory(id)
        let target = FileManager.default.fileExists(atPath: directory.path) ? directory : store.root
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func setDisabled(_ id: String, _ disabled: Bool) {
        guard let state = states[id] else { return }
        if disabled, case .disabled = state.phase { return }
        if disabled { apply(.disable, to: id) } else if case .disabled = state.phase { apply(.enable, to: id) }
    }

    // MARK: - Resolution

    /// The managed install that new sessions start, from state already loaded. No disk access.
    func activeInstall(for adapterID: String) -> IDEACPActiveInstall? {
        states[adapterID]?.activeManifest.map { store.install(from: $0) }
    }

    func resolution(for definition: IDEACPDefinition, pathValue: String) -> IDEACPLaunchResolver.Resolution {
        let entry = definition.adapterEntry
        return IDEACPLaunchResolver.resolve(
            definition: definition, entry: entry, active: entry.flatMap { activeInstall(for: $0.id) },
            pathValue: pathValue,
            systemPackageName: { [unowned self] path in
                if let cached = systemPackageCache[path] { return cached }
                let name = IDEACPLaunchResolver.packageName(ofExecutable: path)
                systemPackageCache[path] = .some(name)
                return name
            })
    }

    /// The launch for a process about to start. Reads the active version from disk, so a version
    /// activated a moment ago is the one used.
    func resolutionForLaunch(for definition: IDEACPDefinition, pathValue: String) -> IDEACPLaunchResolver.Resolution {
        let entry = definition.adapterEntry
        let active = entry.flatMap { store.activeInstall($0.id) }
        return IDEACPLaunchResolver.resolve(
            definition: definition, entry: entry, active: active, pathValue: pathValue)
    }

    func availability(of definition: IDEACPDefinition, settings: IDEAgentSettings, isLive: Bool) -> IDEACPAvailability {
        let result = resolution(for: definition, pathValue: settings.acpPathValue)
        if definition.isEnabled, !isLive, case .unavailable(.nodeMissing) = result {
            return .failed(IDEACPLaunchUnavailable.nodeMissing.message)
        }
        return IDEACPAvailabilityResolver.resolve(
            isEnabled: definition.isEnabled, executableFound: result.launch != nil,
            probe: settings.acpProbes[definition.id], isLive: isLive,
            installable: definition.adapterEntry?.isManaged == true && !isSandboxed)
    }

    // MARK: - Connection test

    /// Starts the agent the way a chat would, performs the handshake, and closes it. The caller
    /// has the user's consent to run the program. Runs in a temporary folder, never the project.
    func testConnection(
        definition: IDEACPDefinition, settings: IDEAgentSettings, environment: [String: String]
    ) async {
        settings.recordProbe(.running, for: definition.id)
        var merged = environment
        for (key, value) in definition.env { merged[key] = value }
        for (key, value) in settings.acpKeychainEnv(for: definition.id) { merged[key] = value }
        let pathValue = merged["PATH"] ?? settings.acpPathValue
        let phase: IDEACPProbe.Phase
        switch resolutionForLaunch(for: definition, pathValue: pathValue) {
        case .unavailable(let reason):
            phase = .failed(reason.message)
        case .launch(let launch):
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("umbra-acp-test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            phase = await IDEACPConnectionTest.run(
                definition: definition, launch: launch, workingDirectory: directory, environment: merged,
                leases: store.leases)
            try? FileManager.default.removeItem(at: directory)
        }
        settings.recordProbe(phase, for: definition.id)
    }

    // MARK: - Helpers

    nonisolated static func normalize(_ error: Error) -> IDEACPAdapterError {
        IDEACPAdapterInstaller.normalize(error)
    }
}
