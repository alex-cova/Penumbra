import Foundation

#if DEBUG

/// Debug-only launch path for the ACP Adapter Manager UI tests.
///
/// `--acp-ui-test` points the adapter store, agent settings, and session files at directories the
/// test created. The installer still verifies the captured registry documents, the lockfile, the
/// file tree, and a real ACP handshake. Release builds compile this file out.
@MainActor
enum IDEACPUITestBootstrap {
    enum Scenario: String {
        case empty
        case installed
        case update
        case slow
        case hang
        case fail
        case offline
        case nodeMissing
    }

    nonisolated static var isEnabled: Bool {
        CommandLine.arguments.contains("--acp-ui-test")
    }

    nonisolated static var scenario: Scenario {
        Scenario(rawValue: ProcessInfo.processInfo.environment["UMBRA_ACP_UI_SCENARIO"] ?? "") ?? .empty
    }

    nonisolated static var isLive: Bool {
        ProcessInfo.processInfo.environment["UMBRA_ACP_UI_LIVE"] == "1"
    }

    /// Chats in the installed scenario are allowed to run the fixture adapter without an extra alert.
    nonisolated static var adoptsInstalledAgents: Bool {
        isEnabled && !isLive && scenario == .installed
    }

    /// Isolated `UserDefaults` suite. Never `UserDefaults.standard` while a UI test is running.
    nonisolated static var isolatedDefaults: UserDefaults? {
        guard isEnabled else { return nil }
        let name = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_DEFAULTS"] ?? "com.umbra.editor.acp-ui-test"
        return UserDefaults(suiteName: name)
    }

    /// Session files (`app.json`, `windows.json`). A missing path still stays out of Application Support.
    nonisolated static var sessionDirectory: URL? {
        guard isEnabled else { return nil }
        if let path = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_SESSION"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-ui-session", isDirectory: true)
    }

    static func installIfRequested() {
        guard isEnabled else { return }
        IDEWorkspace.isSessionPersistenceEnabled = false
        IDEWorkspace.suppressesFirstRunGuide = true
    }

    static func makeManagerIfRequested() -> IDEACPAdapterManager? {
        guard isEnabled else { return nil }
        let defaults = isolatedDefaults ?? UserDefaults(suiteName: "com.umbra.editor.acp-ui-test") ?? .standard
        let root = adapterRoot()
        if isLive {
            // A check would talk to the registry and write the check cache. Manual never checks alone.
            defaults.set(IDEACPUpdateCheckPolicy.manual.rawValue, forKey: IDEACPAdapterManager.policyKey)
            return IDEACPAdapterManager.makeProduction(root: root, defaults: defaults)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = IDEACPAdapterStore(root: root)
        let current = scenario
        let fixtures = fixturesDirectory
        let offline = current == .offline || ProcessInfo.processInfo.environment["UMBRA_ACP_UI_OFFLINE"] == "1"
        let nodeMissing = current == .nodeMissing || ProcessInfo.processInfo.environment["UMBRA_ACP_UI_NODE"] == "missing"
        let fetcher = IDEACPUITestFetcher(fixtures: fixtures, offline: offline)
        let registry = IDEACPNpmRegistry(fetcher: fetcher)
        let npm = IDEACPUITestNpm(fixtures: fixtures, scenario: current)
        let environment = IDEACPAdapterInstaller.Environment(
            store: store,
            registry: registry,
            npm: npm,
            locateNode: {
                if nodeMissing { return nil }
                guard let node = Self.nodeExecutable() else { return nil }
                let directory = (node as NSString).deletingLastPathComponent
                return await IDEACPNodeRuntime.detect(
                    pathValue: directory, environment: AgentCommandEnvironment.make(javaHome: nil))
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
            },
            progressInterval: .milliseconds(100))
        preinstall(store: store, scenario: current)
        return IDEACPAdapterManager(
            store: store, registry: registry, installer: IDEACPAdapterInstaller(environment: environment),
            defaults: defaults, isSandboxed: false,
            pathProvider: {
                if nodeMissing { return "/usr/bin:/bin" }
                guard let node = Self.nodeExecutable() else { return "/usr/bin:/bin" }
                return (node as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
            })
    }

    // MARK: - Layout

    nonisolated private static func adapterRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if isLive { return IDEACPAdapterStore.defaultRoot }
        return FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-ui-root", isDirectory: true)
    }

    nonisolated private static var fixturesDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_FIXTURES"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: "/dev/null")
    }

    nonisolated static func nodeExecutable() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// A version already on disk, so a test can start from Ready or Update available.
    /// The install and update the test performs still go through the real checks.
    private static func preinstall(store: IDEACPAdapterStore, scenario: Scenario) {
        switch scenario {
        case .installed:
            writeInstalled(
                store, id: "codex-acp", package: "@agentclientprotocol/codex-acp", version: "2.6.0")
            writeInstalled(
                store, id: "claude-agent-acp", package: "@agentclientprotocol/claude-agent-acp", version: "0.106.0")
        case .update:
            writeInstalled(
                store, id: "codex-acp", package: "@agentclientprotocol/codex-acp", version: "2.5.0")
        case .empty, .slow, .hang, .fail, .offline, .nodeMissing:
            break
        }
    }

    private static func writeInstalled(_ store: IDEACPAdapterStore, id: String, package: String, version: String) {
        do {
            try store.ensureLayout(for: id)
            let directory = store.versionDirectory(id, version)
            let relative = "node_modules/\(package)/dist/index.js"
            let entry = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try IDEACPUITestAgent.script.write(to: entry, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entry.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let node = nodeExecutable() ?? "/usr/bin/false"
            let manifest = IDEACPInstallManifest(
                adapterID: id, package: package, version: version, integrity: "sha512-preinstall",
                signatureKeyID: "SHA256:preinstall", provenanceRepository: "https://github.com/agentclientprotocol/\(id)",
                publisher: "Fixture", nodePath: node, nodeVersion: "22.0.0",
                entryRelativePath: relative, entrySHA256: IDEACPAdapterStore.sha256(of: entry) ?? "",
                installedBytes: 1,
                installedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()),
                warnings: [])
            try store.writeManifest(manifest, in: directory)
            try store.writeActive(id, IDEACPActiveManifest(version: version, previous: nil, activatedAt: Date()))
        } catch {
            FileHandle.standardError.write(Data("ACP UI fixture preinstall failed: \(error)\n".utf8))
        }
    }
}

// MARK: - Registry

/// Serves the captured npm documents from disk. Nothing is requested from registry.npmjs.org.
private final class IDEACPUITestFetcher: IDEACPHTTPFetching, @unchecked Sendable {
    let fixtures: URL
    let offline: Bool

    init(fixtures: URL, offline: Bool) {
        self.fixtures = fixtures
        self.offline = offline
    }

    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        if offline { throw URLError(.notConnectedToInternet) }
        let url = request.url?.absoluteString ?? ""
        if request.httpMethod == "POST" { return (Data("{}".utf8), 200) }
        let name: String
        if url.contains("attestations") {
            name = url.contains("claude-agent-acp")
                ? "claude-agent-acp-0.106.0.attestations.json"
                : "codex-acp-2.6.0.attestations.json"
        } else if url.contains("claude-agent-acp") {
            name = "claude-agent-acp-0.106.0.version.json"
        } else if url.contains("codex-acp") {
            name = "codex-acp-2.6.0.version.json"
        } else {
            return (Data("{}".utf8), 404)
        }
        do {
            return (try Data(contentsOf: fixtures.appendingPathComponent(name)), 200)
        } catch {
            return (Data("{}".utf8), 404)
        }
    }
}

// MARK: - npm

/// Writes the tree a real `npm install` would, without running npm or touching a global prefix.
private final class IDEACPUITestNpm: IDEACPNpmRunning, @unchecked Sendable {
    let fixtures: URL
    let scenario: IDEACPUITestBootstrap.Scenario

    init(fixtures: URL, scenario: IDEACPUITestBootstrap.Scenario) {
        self.fixtures = fixtures
        self.scenario = scenario
    }

    func run(
        npm: String, arguments: [String], workingDirectory: URL, environment: [String: String], timeout: Duration
    ) async throws -> IDEACPNpmRunResult {
        if arguments.first == "audit" {
            return IDEACPNpmRunResult(
                exitCode: 0, stdout: #"{"invalid":[],"missing":[]}"#, stderr: "", cancelled: false, timedOut: false)
        }
        let fail = scenario == .fail || ProcessInfo.processInfo.environment["UMBRA_ACP_UI_FAIL"] == "1"
        if fail {
            return IDEACPNpmRunResult(exitCode: 1, stdout: "", stderr: "fixture npm failure", cancelled: false, timedOut: false)
        }
        guard let prefixIndex = arguments.firstIndex(of: "--prefix"), prefixIndex + 1 < arguments.count else {
            return IDEACPNpmRunResult(exitCode: 1, stdout: "", stderr: "fixture npm missing prefix", cancelled: false, timedOut: false)
        }
        let spec = arguments.count > 3 ? arguments[3] : ""
        guard let parsed = Self.parse(spec), let integrity = Self.integrity(version: parsed.version, fixtures: fixtures) else {
            return IDEACPNpmRunResult(exitCode: 1, stdout: "", stderr: "fixture npm unexpected \(spec)", cancelled: false, timedOut: false)
        }
        let prefix = URL(fileURLWithPath: arguments[prefixIndex + 1], isDirectory: true)
        try Self.writeTree(prefix: prefix, name: parsed.name, version: parsed.version, integrity: integrity)
        let hang = scenario == .hang || ProcessInfo.processInfo.environment["UMBRA_ACP_UI_HANG"] == "1"
        if hang {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return IDEACPNpmRunResult(exitCode: 143, stdout: "", stderr: "", cancelled: true, timedOut: false)
        }
        let delay = Self.delayMilliseconds(scenario: scenario)
        if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
            if Task.isCancelled {
                return IDEACPNpmRunResult(exitCode: 143, stdout: "", stderr: "", cancelled: true, timedOut: false)
            }
        }
        return IDEACPNpmRunResult(exitCode: 0, stdout: "", stderr: "", cancelled: false, timedOut: false)
    }

    private static func delayMilliseconds(scenario: IDEACPUITestBootstrap.Scenario) -> Int {
        if let raw = ProcessInfo.processInfo.environment["UMBRA_ACP_UI_DELAY_MS"], let value = Int(raw) { return value }
        return scenario == .slow ? 2_000 : 0
    }

    private static func parse(_ spec: String) -> (name: String, version: String)? {
        guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { return nil }
        return (String(spec[..<at]), String(spec[spec.index(after: at)...]))
    }

    private static func integrity(version: String, fixtures: URL) -> String? {
        let file = version == "0.106.0" ? "claude-agent-acp-0.106.0.version.json" : "codex-acp-2.6.0.version.json"
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(file)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dist = object["dist"] as? [String: Any]
        else { return nil }
        return dist["integrity"] as? String
    }

    private static func writeTree(prefix: URL, name: String, version: String, integrity: String) throws {
        let fileManager = FileManager.default
        let packageDirectory = prefix.appendingPathComponent("node_modules/\(name)", isDirectory: true)
        let entry = packageDirectory.appendingPathComponent("dist/index.js")
        try fileManager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try IDEACPUITestAgent.script.write(to: entry, atomically: true, encoding: .utf8)
        let tarball = name.split(separator: "/").last.map(String.init) ?? name
        var lock: [String: Any] = [
            "lockfileVersion": 3,
            "packages": [
                "": ["dependencies": [name: version]],
                "node_modules/\(name)": [
                    "version": version,
                    "resolved": "https://registry.npmjs.org/\(name)/-/\(tarball)-\(version).tgz",
                    "integrity": integrity,
                ],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: lock).write(to: prefix.appendingPathComponent("package-lock.json"))
        try Data(#"{"dependencies":{}}"#.utf8).write(to: prefix.appendingPathComponent("package.json"))
        // A few real bytes so the progress poll has something to measure while a slow install waits.
        try Data(count: 64 * 1024).write(to: packageDirectory.appendingPathComponent("payload.bin"))
        _ = lock
    }
}

// MARK: - Fake ACP agent

/// A Node.js ACP agent. Prompts select a behavior: `tool`, `edit`, `permit`, `reject`, `linger`.
/// Anything else streams "Hello from the fixture".
enum IDEACPUITestAgent {
    static let script = #"""
    const readline = require("readline");
    const path = require("path");
    let sessionId = "fixture-1";
    let cwd = process.cwd();
    let nextId = 1000;
    const waiters = new Map();
    let promptId = null;

    function send(obj) {
      process.stdout.write(JSON.stringify(obj) + "\n");
    }
    function request(method, params) {
      const id = nextId++;
      return new Promise((resolve) => {
        waiters.set(id, resolve);
        send({ jsonrpc: "2.0", id, method, params });
      });
    }
    function textOf(prompt) {
      if (!Array.isArray(prompt)) return "";
      return prompt.map((block) => (block && (block.text || (block.content && block.content.text))) || "").join("");
    }
    function update(body) {
      send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: body } });
    }
    function chunk(text) {
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
    }

    const rl = readline.createInterface({ input: process.stdin });
    rl.on("line", (line) => { handle(line); });

    async function handle(line) {
      if (!line.trim()) return;
      let msg;
      try { msg = JSON.parse(line); } catch { return; }
      if (msg.id !== undefined && msg.method === undefined) {
        const waiter = waiters.get(msg.id);
        if (waiter) { waiters.delete(msg.id); waiter(msg.result || {}); }
        return;
      }
      const method = msg.method;
      const params = msg.params || {};
      if (method === "initialize") {
        send({ jsonrpc: "2.0", id: msg.id, result: {
          protocolVersion: 1,
          agentCapabilities: { loadSession: false },
          authMethods: [],
          agentInfo: { name: "fixture", title: "Fixture", version: "1.0.0" }
        }});
        return;
      }
      if (method === "session/new" || method === "session/load" || method === "session/resume") {
        if (params.cwd) cwd = params.cwd;
        send({ jsonrpc: "2.0", id: msg.id, result: { sessionId } });
        return;
      }
      if (method === "session/cancel") {
        if (promptId !== null) {
          send({ jsonrpc: "2.0", id: promptId, result: { stopReason: "cancelled" } });
          promptId = null;
        }
        return;
      }
      if (method === "session/prompt") {
        promptId = msg.id;
        if (params.sessionId) sessionId = params.sessionId;
        const text = textOf(params.prompt);
        try {
          if (text.includes("umbra-fixture:linger")) {
            chunk("partial");
            return;
          }
          if (text.includes("umbra-fixture:permit") || text.includes("umbra-fixture:reject")) {
            const result = await request("session/request_permission", {
              sessionId,
              toolCall: { toolCallId: "perm-1", title: "Run fixture", name: "fixture-read", status: "pending" },
              options: [
                { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
                { optionId: "reject-once", name: "Reject", kind: "reject_once" }
              ]
            });
            const option = (result.outcome && result.outcome.optionId) || "none";
            chunk("perm:" + option);
          } else if (text.includes("umbra-fixture:tool")) {
            update({ sessionUpdate: "tool_call", toolCallId: "tool-1", title: "fixture-read", name: "fixture-read", kind: "read", status: "pending" });
            update({ sessionUpdate: "tool_call_update", toolCallId: "tool-1", status: "completed" });
          } else if (text.includes("umbra-fixture:edit")) {
            await request("fs/write_text_file", { sessionId, path: path.join(cwd, "note.txt"), content: "fixture note\n" });
            chunk("wrote note.txt");
          } else {
            chunk("Hello from ");
            chunk("the fixture");
          }
          send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
        } catch (error) {
          send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: String(error) } });
        }
        promptId = null;
        return;
      }
      if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, result: {} });
    }
    """#
}

#endif
