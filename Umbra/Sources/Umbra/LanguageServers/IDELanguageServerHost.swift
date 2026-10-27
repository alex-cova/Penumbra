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
        summary = nil
    }

    private func launch(
        _ definition: IDELanguageServerDefinition, connection: LSPConnectionBox, root: URL, attempt: Int
    ) async {
        guard definition.isRelevantToProject(root) else { return }
        let token = generation
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
                    self?.noteWork(work, definition: definition, token: token, attempt: attempt)
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
        let session = Session(definition: definition, connection: connection, handle: handle, bridge: bridge, attempt: attempt)
        sessions[definition.id] = session
        connection.setCurrent(client)
        if let workspace = documentWorkspace {
            session.startSync(
                LSPWorkspaceDocumentSync(client: client, languages: definition.configuration.languageIdentifiers),
                workspace: workspace
            )
        }

        let featuresTask = Task { [weak self] in
            let features = await client.advertisedFeatures()
            await MainActor.run {
                guard let self, self.generation == token, self.sessions[definition.id]?.attempt == attempt else { return }
                connection.setSupportedFeatures(features)
                self.setStatus(definition, .ready)
            }
        }
        session.featuresTask = featuresTask

        Task { [weak self] in
            let result = await handle.result
            bridge.finish()
            await MainActor.run {
                self?.noteExit(definition: definition, connection: connection, root: root, attempt: attempt, token: token, result: result)
            }
        }
    }

    private func noteExit(
        definition: IDELanguageServerDefinition,
        connection: LSPConnectionBox,
        root: URL,
        attempt: Int,
        token: Int,
        result: SubprocessResult
    ) {
        guard generation == token, sessions[definition.id]?.attempt == attempt else { return }
        sessions[definition.id]?.featuresTask?.cancel()
        sessions[definition.id]?.stopSync()
        sessions[definition.id] = nil
        connection.setCurrent(nil)
        connection.setSupportedFeatures(nil)
        if result.cancelled { return }
        nativeFallbacks += 1
        setStatus(definition, .restarting)
        let delay = restartDelay(attempt)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.launch(definition, connection: connection, root: root, attempt: attempt + 1)
        }
    }

    /// Progress from a server's `$/progress`. Dropped when it comes from a session this host has since
    /// stopped or replaced.
    private func noteWork(_ work: [LSPWorkProgress], definition: IDELanguageServerDefinition, token: Int, attempt: Int) {
        guard generation == token, sessions[definition.id]?.attempt == attempt else { return }
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
    /// of work (and how many more run beside it) instead of just its name.
    static func summary(statuses: [ServerStatus], work: [String: [LSPWorkProgress]]) -> String? {
        let text = statuses.map { status -> String in
            switch status.phase {
            case .stopped: return ""
            case .untrusted: return "\(status.name): not trusted"
            case .missing: return "\(status.name): not found"
            case .unprepared: return "\(status.name): project not indexed"
            case .starting: return "\(status.name): starting"
            case .restarting: return "\(status.name): restarting"
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
        var featuresTask: Task<Void, Never>?
        private var sync: LSPWorkspaceDocumentSync?

        init(
            definition: IDELanguageServerDefinition, connection: LSPConnectionBox,
            handle: SubprocessHandle, bridge: OutputBridge, attempt: Int
        ) {
            self.definition = definition
            self.connection = connection
            self.handle = handle
            self.bridge = bridge
            self.attempt = attempt
        }

        func finishReading() { bridge.finish() }

        /// Tells the server about the open documents and keeps doing so until ``stopSync()``.
        func startSync(_ sync: LSPWorkspaceDocumentSync, workspace: Workspace) {
            self.sync = sync
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
