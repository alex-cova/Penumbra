import AgentKit
import Foundation
import XCTest
@testable import Umbra

private let fakeServerSource = """
import json, os, sys
pidfile = sys.argv[1]
open(pidfile, "w").write(str(os.getpid()))
def send(message):
    sys.stdout.write(json.dumps(message) + "\\n")
    sys.stdout.flush()
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    method, ident = message["method"], message["id"]
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": ident, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": ident, "result": {"tools": [{"name": "echo", "description": "echoes", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}})
    elif method == "tools/call":
        text = message["params"]["arguments"].get("text", "")
        send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": "echo: " + text + " env=" + os.environ.get("MCP_TEST_VALUE", "-")}]}})
    else:
        send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "no " + method}})
"""

@MainActor
final class IDEMCPStoreTests: XCTestCase {
    private func makeStore(_ suite: String = "umbra.mcp.\(UUID().uuidString)") -> (IDEMCPStore, UserDefaults, IDEAgentMemoryKeyStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let keys = IDEAgentMemoryKeyStore()
        return (IDEMCPStore(defaults: defaults, keyStore: keys), defaults, keys)
    }

    func testAnAddedServerKeepsItsSecretsInTheKeychainAndStartsOff() throws {
        let (store, defaults, keys) = makeStore()
        let entry = try XCTUnwrap(store.add(
            name: "Files", commandLine: #"npx -y server "/my dir""#, environment: "TOKEN=abc=def\n# note\n\nBAD KEY=1\n9X=2\nREGION=eu"))
        XCTAssertEqual(entry.command, "npx")
        XCTAssertEqual(entry.args, ["-y", "server", "/my dir"])
        XCTAssertEqual(entry.envKeys, ["TOKEN", "REGION"])
        XCTAssertEqual(try keys.load(account: IDEMCPStore.account(entry.id, "TOKEN")), "abc=def")
        XCTAssertFalse(store.isEnabled(entry.id), "adding is not consent to run")
        XCTAssertTrue(store.enabledConfigs().isEmpty)
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: "umbra.agent.mcpServers")), as: UTF8.self).contains("abc"),
                       "the value is not in UserDefaults")

        store.setEnabled(true, id: entry.id)
        let config = try XCTUnwrap(store.enabledConfigs().first)
        XCTAssertEqual(config.name, "Files")
        XCTAssertEqual(config.env, ["TOKEN": "abc=def", "REGION": "eu"])

        // It survives a relaunch.
        let again = IDEMCPStore(defaults: defaults, keyStore: keys)
        XCTAssertEqual(again.servers, store.servers)
        XCTAssertTrue(again.isEnabled(entry.id))

        store.remove(id: entry.id)
        XCTAssertNil(try keys.load(account: IDEMCPStore.account(entry.id, "TOKEN")), "removing deletes the secrets")
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertFalse(store.isEnabled(entry.id))
    }

    func testAnEmptyCommandAddsNothing() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.add(name: "x", commandLine: "   ", environment: ""))
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testTrustFollowsExactlyWhatWouldRun() {
        let (store, defaults, keys) = makeStore()
        let server = MCPServerConfig(name: "db", command: "npx", args: ["-y", "pg"], env: ["URL": "x"])
        XCTAssertFalse(store.isTrusted(server))
        XCTAssertFalse(store.isDeclined(server))
        store.trust(server)
        XCTAssertTrue(store.isTrusted(server))
        for changed in [
            MCPServerConfig(name: "db", command: "npx", args: ["-y", "pg2"], env: ["URL": "x"]),
            MCPServerConfig(name: "db", command: "npx", args: ["-y", "pg"], env: ["URL": "y"]),
            MCPServerConfig(name: "db", command: "npy", args: ["-y", "pg"], env: ["URL": "x"]),
            MCPServerConfig(name: "db2", command: "npx", args: ["-y", "pg"], env: ["URL": "x"]),
        ] { XCTAssertFalse(store.isTrusted(changed), "a changed server must be asked about again") }

        XCTAssertEqual(IDEMCPStore.fingerprint(of: server).count, 64)
        let reopened = IDEMCPStore(defaults: defaults, keyStore: keys)
        XCTAssertTrue(reopened.isTrusted(server))

        store.decline(server)
        XCTAssertTrue(store.isDeclined(server))
        XCTAssertFalse(store.isTrusted(server))
        store.forget(server)
        XCTAssertFalse(store.isDeclined(server))
    }

    func testProjectFilesAreReadInOrderAndALinkIsNotFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".umbra"), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"shared": {"command": "umbra-one"}, "only-umbra": {"command": "a"}}}"#.utf8)
            .write(to: root.appendingPathComponent(".umbra/mcp.json"))
        try Data(#"{"mcpServers": {"shared": {"command": "claude-one"}, "only-claude": {"command": "b"}, "web": {"url": "https://x.test"}}}"#.utf8)
            .write(to: root.appendingPathComponent(".mcp.json"))

        let loaded = IDEMCPProjectConfig.load(root: root)
        XCTAssertEqual(loaded.servers.map(\.name), ["only-umbra", "shared", "only-claude"])
        XCTAssertEqual(loaded.servers.first { $0.name == "shared" }?.command, "umbra-one", "Umbra's own file wins")
        XCTAssertEqual(loaded.skipped.map(\.name), ["web"])

        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"mcpServers": {"evil": {"command": "rm"}}}"#.utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".mcp.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".mcp.json"), withDestinationURL: elsewhere)
        let linked = IDEMCPProjectConfig.load(root: root)
        XCTAssertFalse(linked.servers.contains { $0.name == "evil" })
        XCTAssertTrue(linked.problems.contains { $0.contains("symbolic link") })

        try Data("not json".utf8).write(to: root.appendingPathComponent(".umbra/mcp.json"))
        XCTAssertTrue(IDEMCPProjectConfig.load(root: root).problems.contains { $0.hasPrefix(".umbra/mcp.json") })
    }
}

/// The whole path with a real process: spawn, handshake, tools, a call, trust, and stopping.
@MainActor
final class IDEMCPManagerTests: XCTestCase {
    private var root: URL!
    private var script: URL!
    private var store: IDEMCPStore!
    private var manager: IDEMCPManager!
    private var pidFile: URL { root.appendingPathComponent("pid.txt") }

    override func setUpWithError() throws {
        let python = "/usr/bin/python3"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "pass"]
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { throw XCTSkip("python3 is not available") }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw XCTSkip("python3 is not usable here") }

        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-manager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        script = root.appendingPathComponent("server.py")
        try fakeServerSource.write(to: script, atomically: true, encoding: .utf8)
        store = IDEMCPStore(defaults: UserDefaults(suiteName: "umbra.mcp.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        manager = IDEMCPManager(store: store)
    }

    override func tearDown() async throws {
        manager?.shutdown()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeProjectFile(env: String = "") throws {
        let environment = env.isEmpty ? "" : #", "env": {\#(env)}"#
        try Data(#"{"mcpServers": {"fake": {"command": "/usr/bin/python3", "args": ["\#(script.path)", "\#(pidFile.path)"]\#(environment)}}}"#.utf8)
            .write(to: root.appendingPathComponent(".mcp.json"))
    }

    private func processIsAlive() -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) else { return false }
        return kill(pid, 0) == 0
    }

    private func eventually(_ message: String, seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), message)
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot await.
    private func tools(of hub: MCPHub?) async -> [any AgentTool] { await hub?.tools ?? [] }

    private func run(_ tool: any AgentTool, _ json: String) async throws -> String {
        let project = FileManager.default.temporaryDirectory
        let workspace = DiskAgentWorkspace(root: project)
        return try await tool.run(try ToolArguments(json: json), context: ToolContext(workspace: workspace, ledger: ReadLedger(), callID: "c"))
    }

    func testAProjectServerStartsOnlyAfterTheUserAllowsExactlyIt() async throws {
        try writeProjectFile()
        var asked: [[MCPServerConfig]] = []

        let refused = await manager.prepare(root: root, confirm: { servers in asked.append(servers); return [] }, willStart: {})
        XCTAssertNil(refused.hub)
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path), "nothing was started")

        // Declining is remembered: the next message does not ask again.
        _ = await manager.prepare(root: root, confirm: { servers in asked.append(servers); return [] }, willStart: {})
        XCTAssertEqual(asked.count, 1)

        // Changing the server makes it a different server, so it asks again; this time the answer is yes.
        try writeProjectFile(env: #""MCP_TEST_VALUE": "from-project""#)
        var started = 0
        let allowed = await manager.prepare(
            root: root, confirm: { servers in asked.append(servers); return Set(servers.map(IDEMCPStore.fingerprint(of:))) }, willStart: { started += 1 })
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(started, 1)
        let hub = try XCTUnwrap(allowed.hub)
        XCTAssertTrue(allowed.notices.isEmpty)

        let offered = await tools(of: hub)
        XCTAssertEqual(offered.map(\.name), ["mcp__fake__echo"])
        let output = try await run(offered[0], #"{"text":"hello"}"#)
        XCTAssertTrue(output.contains("echo: hello env=from-project"), output)
        XCTAssertTrue(output.contains("<untrusted source=\"mcp:fake\">"))
        XCTAssertTrue(processIsAlive())
        XCTAssertEqual(manager.states.first { $0.name == "fake" }?.kind, .running(tools: 1))
    }

    func testTheSameServersAreReusedAndShutdownStopsTheProcess() async throws {
        try writeProjectFile()
        let fingerprint = { (servers: [MCPServerConfig]) in Set(servers.map(IDEMCPStore.fingerprint(of:))) }
        var asked = 0
        let first = await manager.prepare(root: root, confirm: { asked += 1; return fingerprint($0) }, willStart: {})
        let second = await manager.prepare(root: root, confirm: { asked += 1; return fingerprint($0) }, willStart: { XCTFail("it was already running") })
        XCTAssertNotNil(first.hub)
        XCTAssertTrue(first.hub === second.hub, "one hub for the window")
        XCTAssertEqual(asked, 1)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0)

        manager.shutdown()
        await eventually("the process should be gone after shutdown") { kill(pid, 0) != 0 }
    }

    func testAnAddedServerNeedsUseSwitchedOnAndAMissingProgramIsExplained() async throws {
        let entry = try XCTUnwrap(store.add(name: "Gone", commandLine: "definitely-not-installed --flag", environment: ""))
        let off = await manager.prepare(root: root, confirm: { _ in [] }, willStart: {})
        XCTAssertNil(off.hub, "added, but not switched on")

        store.setEnabled(true, id: entry.id)
        let result = await manager.prepare(root: root, confirm: { _ in [] }, willStart: {})
        XCTAssertEqual(result.notices.count, 1)
        XCTAssertTrue(result.notices[0].contains("Gone") && result.notices[0].contains("PATH"), result.notices[0])
        let none = await tools(of: result.hub)
        XCTAssertTrue(none.isEmpty && result.hub != nil, "no tools, but the hub exists so the failure is not retried on every message")
        if case .failed? = manager.states.first(where: { $0.name == "Gone" })?.kind {} else { XCTFail("the state should say it failed") }
    }

    func testAnAddedServerWithSecretsPassesThemToTheProcess() async throws {
        let entry = try XCTUnwrap(store.add(
            name: "fake", commandLine: "/usr/bin/python3 \(script.path) \(pidFile.path)", environment: "MCP_TEST_VALUE=secret-value"))
        store.setEnabled(true, id: entry.id)
        let result = await manager.prepare(root: root, confirm: { _ in [] }, willStart: {})
        let available = await tools(of: result.hub)
        let tool = try XCTUnwrap(available.first)
        let output = try await run(tool, #"{"text":"x"}"#)
        XCTAssertTrue(output.contains("env=secret-value"), output)
    }

    func testTheProcessDoesNotInheritUmbrasEnvironment() async throws {
        setenv("UMBRA_MCP_LEAK_CHECK", "leaked", 1)
        defer { unsetenv("UMBRA_MCP_LEAK_CHECK") }
        let probe = root.appendingPathComponent("env.py")
        try """
        import json, os, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize":
                r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}
            elif m["method"] == "tools/list":
                r = {"tools": [{"name": "leak", "inputSchema": {"type": "object"}}]}
            else:
                r = {"content": [{"type": "text", "text": "LEAK=" + os.environ.get("UMBRA_MCP_LEAK_CHECK", "none")}]}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\\n"); sys.stdout.flush()
        """.write(to: probe, atomically: true, encoding: .utf8)
        let entry = try XCTUnwrap(store.add(name: "env", commandLine: "/usr/bin/python3 \(probe.path)", environment: ""))
        store.setEnabled(true, id: entry.id)
        let result = await manager.prepare(root: root, confirm: { _ in [] }, willStart: {})
        let available = await tools(of: result.hub)
        let tool = try XCTUnwrap(available.first)
        let output = try await run(tool, "{}")
        XCTAssertTrue(output.contains("LEAK=none"), output)
    }
}
