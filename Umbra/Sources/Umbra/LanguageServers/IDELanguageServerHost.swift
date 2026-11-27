import EditorIntelligence
import EditorIntelligenceLSP
import Foundation
import SubprocessKit

/// Launches the language servers a module declared, and puts the connection where
/// ``LSPLanguageService`` reads it. A crash clears the connection (the native tier answers) and
/// the host starts the server again with backoff. `stop` sends nothing that retains the window:
/// the process is terminated and every callback holds the host weakly.
@MainActor
@Observable
final class IDELanguageServerHost {
    enum Phase: Equatable {
        case stopped
        case untrusted
        case missing
        /// The folder could not be made ready for the server (``IDEServerPreparation/unavailable(_:)``).
        case unprepared
        case starting
        case ready
        case restarting
        /// The server kept exiting and the restart limit was reached. Only Restart in Settings tries again.
        case failed
    }

    struct ServerStatus: Equatable {
        var id: String
        var name: String
        var phase: Phase
    }

    /// Shown in the status bar. Nil when no server is in play.
    private(set) var summary: String?
    private(set) var statuses: [ServerStatus] = []
    /// What each ready server reports it is doing (`Indexing: 3 / 10 (30%)`), by definition id. Cleared
    /// when the server leaves `ready`, so a crash never leaves a stale percentage in the status bar.
    private(set) var serverWork: [String: [LSPWorkProgress]] = [:]
    /// How many times a server exited on its own and the native tier was left in front.
    private(set) var nativeFallbacks = 0
    /// The tail of the last stderr a server left when it exited on its own, by definition id.
    private(set) var serverErrors: [String: String] = [:]
    /// Consecutive quick exits before the host stops restarting a server.
    var maxRestartAttempts = 5
    /// A server that ran this long before exiting counts as healthy: its next exit starts the backoff over.
    var healthyRunDuration: Duration = .seconds(60)

    var restartDelay: @Sendable (Int) -> Duration = { attempt in
        .milliseconds(min(8_000, 250 << min(attempt, 5)))
    }

    /// Asked once when a folder is not yet trusted. Returning true records trust and starts the server.
    /// Nil means "do not ask and do not start".
    var requestTrust: (@MainActor (IDELanguageServerDefinition, URL) async -> Bool)?

    /// The workspace whose documents the servers are told about (`LSPWorkspaceDocumentSync`). Set by the
    /// window; nil starts servers that are never sent a file, which answer nothing about an edited buffer.
    var documentWorkspace: Workspace?

    private let trustDirectory: URL
    private var sessions: [String: Session] = [:]
    private var generation = 0
    private var currentRoot: URL?
    /// Identifies one launched process, so the exit of a replaced one (Restart) never clears its successor.
    private var nextSerial = 0
    static let enabledDefaultsKey = "umbra.languageServers.enabled"
    private let enabledKey = IDELanguageServerHost.enabledDefaultsKey

    init(trustDirectory: URL? = nil) {
        self.trustDirectory = trustDirectory ?? Self.defaultTrustDirectory()
    }

    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    func trust(_ definition: IDELanguageServerDefinition, root: URL) {
        IDELanguageServerTrust(directory: trustDirectory, fileName: definition.trustFile).trust(root)
    }

    func isTrusted(_ definition: IDELanguageServerDefinition, root: URL) -> Bool {
        IDELanguageServerTrust(directory: trustDirectory, fileName: definition.trustFile).isTrusted(root)
    }

    /// Starts every module's server for `root` when the global switch is on and the folder is trusted.
    func projectDidChange(root: URL?, connections: [String: LSPConnectionBox]) {
        stop()
        currentRoot = root
        guard let root, isEnabled else { return }
        let definitions = IDELanguageModules.all.flatMap(\.languageServers)
        for definition in definitions {
            guard definition.isRelevantToProject(root), let box = connections[definition.id] else { continue }
            Task { await self.launch(definition, connection: box, root: root, attempt: 0) }
        }
    }

    /// Starts one server. Used by the modules' project change and by tests.
    func start(_ definition: IDELanguageServerDefinition, connection: LSPConnectionBox, root: URL) async {
        await launch(definition, connection: connection, root: root, attempt: 0)
    }

    /// Terminates one server and starts it again with a fresh restart budget, whatever state it was in
    /// (also `failed`, `missing` and `untrusted`, so a newly installed binary is picked up). Other servers
    /// are not touched.
    func restart(_ definition: IDELanguageServerDefinition, connection: LSPConnectionBox) {
        guard let root = currentRoot, isEnabled else { return }
        terminate(definition, connection: connection)
        Task { await self.launch(definition, connection: connection, root: root, attempt: 0) }
    }

    /// Terminates one server and leaves it stopped (Settings turned it off). Other servers keep running.
    func stop(_ definition: IDELanguageServerDefinition, connection: LSPConnectionBox) {
        terminate(definition, connection: connection)
        statuses.removeAll { $0.id == definition.id }
        serverWork[definition.id] = nil
        summary = Self.summary(statuses: statuses, work: serverWork)
    }

    private func terminate(_ definition: IDELanguageServerDefinition, connection: LSPConnectionBox) {
        if let session = sessions.removeValue(forKey: definition.id) {
            session.featuresTask?.cancel()
            session.stopSync()
            session.handle.terminate()
            session.finishReading()
        }
        connection.setCurrent(nil)
        connection.setSupportedFeatures(nil)
        serverErrors[definition.id] = nil
    }

    /// Terminates every server. A later exit does not restart.
    func stop() {
        generation += 1
        for session in sessions.values {
            session.featuresTask?.cancel()
            session.stopSync()
            session.handle.terminate()
            session.finishReading()
            session.connection.setCurrent(nil)
        }
        sessions = [:]
        statuses = []
        serverWork = [:]
        serverErrors = [:]
        summary = nil
    }

    private func launch(
        _ definition: IDELanguageServerDefinition, connection: LSPConnectionBox, root: URL, attempt: Int
    ) async {
        guard definition.isRelevantToProject(root) else { return }
        let token = generation
        nextSerial += 1
        let serial = nextSerial
        if !isTrusted(definition, root: root) {
            let allowed = await requestTrust?(definition, root) ?? false
            guard generation == token else { return }
            if allowed {
                trust(definition, root: root)
            } else {
                setStatus(definition, .untrusted)
                return
            }
        }
        setStatus(definition, attempt == 0 ? .starting : .restarting)
        let context = IDEServerDiscoveryContext(root: root, environment: ProcessInfo.processInfo.environment)
        guard let executable = await definition.discover(context) else {
            setStatus(definition, .missing)
            return
        }
        guard generation == token else { return }
        if case .unavailable = await definition.prepare(root) {
            guard generation == token else { return }
            setStatus(definition, .unprepared)
            return
        }
        guard generation == token else { return }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bridge = OutputBridge(continuation: continuation)
        let client = LanguageServerClient.make(
            write: { bridge.write($0) },
            read: stream,
            documentURI: { document in document.url?.absoluteString ?? "untitled:\(document.id)" },
            workspaceRoot: root,
            initializationOptions: definition.initializationOptions(root),
            onProgress: { [weak self] work in
                Task { @MainActor in
                    self?.noteWork(work, definition: definition, token: token, serial: serial)
                }
            }
        )
        var request = SubprocessRequest(executable: executable.url.path, arguments: definition.arguments(root))
        request.standardInput = .interactive
        request.stdoutCapture = .discard
        request.stderrCapture = .bounded(head: 0, tail: 16_384)
        request.processGroup = true
        request.killGroupOnExit = true
        request.workingDirectory = root
        request.environment = executable.environment
        let handle: SubprocessHandle
        do {
            handle = try SubprocessRunner.start(request) { data, source in
                if source == .stdout { bridge.yield(data) }
            }
        } catch {
            setStatus(definition, .missing)
            return
        }
        guard generation == token else {
            handle.terminate()
            bridge.finish()
            return
        }
        bridge.attach(handle)
        let launchedAt = ContinuousClock.now
        let session = Session(definition: definition, connection: connection, handle: handle, bridge: bridge, attempt: attempt, serial: serial)
        sessions[definition.id] = session
        connection.setCurrent(client)
        if let workspace = documentWorkspace {
            let configuration = definition.configuration
            session.startSync(
                LSPWorkspaceDocumentSync(
                    client: client, languages: configuration.languageIdentifiers,
                    lspLanguageID: { document in configuration.lspLanguageID(document.url, document.languageIdentifier ?? "plaintext") }
                ),
                workspace: workspace
            )
        }

        let featuresTask = Task { [weak self] in
            let features = await client.advertisedFeatures()
            await MainActor.run {
                guard let self, self.generation == token, self.sessions[definition.id]?.serial == serial else { return }
                connection.setSupportedFeatures(features)
                self.setStatus(definition, .ready)
                self.sessions[definition.id]?.beginSync()
            }
        }
        session.featuresTask = featuresTask

        Task { [weak self] in
            let result = await handle.result
            bridge.finish()
            await MainActor.run {
                self?.noteExit(
                    definition: definition, connection: connection, root: root, attempt: attempt, token: token, serial: serial,
                    result: result, ranFor: launchedAt.duration(to: .now)
                )
            }
        }
    }

    private func noteExit(
        definition: IDELanguageServerDefinition,
        connection: LSPConnectionBox,
        root: URL,
        attempt: Int,
        token: Int,
        serial: Int,
        result: SubprocessResult,
        ranFor: Duration = .zero
    ) {
        guard generation == token, sessions[definition.id]?.serial == serial else { return }
        sessions[definition.id]?.featuresTask?.cancel()
        sessions[definition.id]?.stopSync()
        sessions[definition.id] = nil
        connection.setCurrent(nil)
        connection.setSupportedFeatures(nil)
        if result.cancelled { return }
        nativeFallbacks += 1
        let stderr = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        serverErrors[definition.id] = stderr.isEmpty ? "Exited with \(result.exit)." : String(stderr.suffix(2_000))
        // A server that ran for a while and then died starts a new budget; one that dies at once uses it up.
        let next = ranFor >= healthyRunDuration ? 1 : attempt + 1
        if next > maxRestartAttempts {
            setStatus(definition, .failed)
            return
        }
        setStatus(definition, .restarting)
        let delay = restartDelay(attempt)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.launch(definition, connection: connection, root: root, attempt: next)
        }
    }

    /// Progress from a server's `$/progress`. Dropped when it comes from a session this host has since
    /// stopped or replaced.
    private func noteWork(_ work: [LSPWorkProgress], definition: IDELanguageServerDefinition, token: Int, serial: Int) {
        guard generation == token, sessions[definition.id]?.serial == serial else { return }
        serverWork[definition.id] = work.isEmpty ? nil : work
        summary = Self.summary(statuses: statuses, work: serverWork)
    }

    private func setStatus(_ definition: IDELanguageServerDefinition, _ phase: Phase) {
        statuses.removeAll { $0.id == definition.id }
        if phase != .stopped {
            statuses.append(ServerStatus(id: definition.id, name: definition.configuration.name, phase: phase))
        }
        if phase != .ready { serverWork[definition.id] = nil }
        summary = Self.summary(statuses: statuses, work: serverWork)
    }

    /// The status-bar text: one entry per server, `·` between them. A ready server shows its first piece
    /// of work (and how many more run beside it) instead of just its name. A missing server stays out:
    /// its binary is not installed, so the editor banner on a matching file carries it instead.
    static func summary(statuses: [ServerStatus], work: [String: [LSPWorkProgress]]) -> String? {
        let text = statuses.map { status -> String in
            switch status.phase {
            case .stopped: return ""
            case .missing: return ""
            case .untrusted: return "\(status.name): not trusted"
            case .unprepared: return "\(status.name): project not indexed"
            case .starting: return "\(status.name): starting"
            case .restarting: return "\(status.name): restarting"
            case .failed: return "\(status.name): stopped after repeated crashes"
            case .ready:
                guard let running = work[status.id], let first = running.first else { return status.name }
                let more = running.count > 1 ? " +\(running.count - 1)" : ""
                return "\(status.name): \(first.summary)\(more)"
            }
        }.filter { !$0.isEmpty }.sorted().joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    private static func defaultTrustDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.umbra.editor", isDirectory: true)
    }

    private final class Session {
        let definition: IDELanguageServerDefinition
        let connection: LSPConnectionBox
        let handle: SubprocessHandle
        let bridge: OutputBridge
        let attempt: Int
        let serial: Int
        var featuresTask: Task<Void, Never>?
        private var sync: LSPWorkspaceDocumentSync?
        private var pendingWorkspace: Workspace?

        init(
            definition: IDELanguageServerDefinition, connection: LSPConnectionBox,
            handle: SubprocessHandle, bridge: OutputBridge, attempt: Int, serial: Int
        ) {
            self.definition = definition
            self.connection = connection
            self.handle = handle
            self.bridge = bridge
            self.attempt = attempt
            self.serial = serial
        }

        func finishReading() { bridge.finish() }

        /// Tells the server about the open documents and keeps doing so until ``stopSync()``.
        /// Remembers the sync; ``beginSync()`` starts it once `initialize` has completed. A `didOpen` that goes out
        /// while a slow server (clangd, rust-analyzer) is still starting is dropped, and every later request about
        /// the file then fails with "non-added document". Two concurrent `initialize` waits are not safe either
        /// (the second reads no capabilities), so the host's one feature query is what the sync waits for.
        func startSync(_ sync: LSPWorkspaceDocumentSync, workspace: Workspace) {
            self.sync = sync
            pendingWorkspace = workspace
        }

        func beginSync() {
            guard let sync, let workspace = pendingWorkspace else { return }
            pendingWorkspace = nil
            Task { await sync.start(workspace: workspace) }
        }

        func stopSync() {
            guard let sync else { return }
            self.sync = nil
            Task { await sync.stop() }
        }
    }
}

/// Stdout bytes from the child, and stdin bytes back to it. Neither buffer grows with the stream:
/// stdout is yielded and dropped, and SubprocessKit's capture for that pipe is `.discard`.
private final class OutputBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var handle: SubprocessHandle?

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func attach(_ handle: SubprocessHandle) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    func yield(_ data: Data) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(data)
    }

    func write(_ data: Data) {
        lock.lock()
        let handle = handle
        lock.unlock()
        handle?.write(data)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
