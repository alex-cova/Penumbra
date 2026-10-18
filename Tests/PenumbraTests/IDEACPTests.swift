import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
private final class ACPHost: IDEAgentHost {
    var agentProjectRoot: URL?
    var unsaved: [String: String] = [:]
    init(root: URL?) { agentProjectRoot = root }
    func agentUnsavedBuffers() -> [String: String] { unsaved }
    func agentEditorContext() -> String { "[Editor state]\n[End editor state]" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {
        guard let root = agentProjectRoot else { throw AgentWorkspaceError.readOnly }
        let text = try AgentTextEdit.apply(edits, to: expecting)
        try text.write(to: root.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }
    func agentCreateFile(relativePath: String, contents: String) async throws {
        guard let root = agentProjectRoot else { throw AgentWorkspaceError.readOnly }
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    func agentTrashFile(relativePath: String) async throws { throw AgentWorkspaceError.readOnly }
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { AgentCommandEnvironment.make(javaHome: nil) }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome { .notStarted("no") }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}

@MainActor
private func acpEventually(_ message: String, timeout: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message)
}

private let acpScript = #"""
import json, os, sys
log_path = sys.argv[1]
pid_path = sys.argv[2]
with open(pid_path, "w") as f: f.write(str(os.getpid()))
def log(msg):
    with open(log_path, "a") as f: f.write(msg + "\n")
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
def notify_update(update):
    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"script-1","update":update}})
def text_chunk(text):
    notify_update({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}})
counter = [100]
def request(method, params):
    counter[0] += 1
    rid = "agent-%d" % counter[0]
    send({"jsonrpc":"2.0","id":rid,"method":method,"params":params})
    while True:
        line = sys.stdin.readline()
        if not line: raise SystemExit(2)
        msg = json.loads(line)
        if msg.get("id") == rid:
            return msg
        # ignore notifications while waiting
cwd = ""
for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method: log(method)
    if method == "initialize":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True},"authMethods":[]}})
    elif method == "authenticate":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{}})
    elif method in ("session/new", "session/load"):
        cwd = msg["params"].get("cwd","")
        result = {"sessionId":"script-1","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent"},{"id":"plan","name":"Plan"}]},"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"script-1"}]}
        send({"jsonrpc":"2.0","id":msg["id"],"result":result})
    elif method == "session/set_mode":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{}})
    elif method == "session/prompt":
        prompt = "".join(b.get("text","") for b in msg["params"].get("prompt",[]) if b.get("type")=="text")
        if "crash" in prompt:
            text_chunk("dying")
            sys.stdout.flush()
            os._exit(3)
        text_chunk("Hello from ACP")
        if "full" in prompt:
            read = request("fs/read_text_file", {"sessionId":"script-1","path": cwd + "/a.txt"})
            content = read.get("result",{}).get("content","missing")
            text_chunk(" read:" + content)
            perm = request("session/request_permission", {"sessionId":"script-1","toolCall":{"toolCallId":"perm-1","title":"Run command","rawInput":{"command":"git status"}},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]})
            outcome = perm.get("result",{}).get("outcome",{})
            text_chunk(" perm:" + str(outcome.get("optionId","cancelled")))
            wrote = request("fs/write_text_file", {"sessionId":"script-1","path": cwd + "/b.txt","content":"written"})
            text_chunk(" write:" + ("ok" if "result" in wrote else "failed"))
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}})
"""#

@MainActor
final class IDEACPTests: XCTestCase {
    private func makeProject() throws -> (root: URL, script: URL, log: URL, pid: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake_agent.py")
        try acpScript.write(to: script, atomically: true, encoding: .utf8)
        return (root, script, root.appendingPathComponent("agent.log"), root.appendingPathComponent("agent.pid"))
    }

    private func makeConversation(root: URL, script: URL, log: URL, pid: URL) -> (IDEAgentConversation, ACPHost, IDEAgentSettings) {
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.addACPAgent(name: "Script Agent", commandLine: "/usr/bin/python3 \(script.path) \(log.path) \(pid.path)")
        if let definition = settings.acpAgents.first { settings.setACPAllowed(true, agentID: definition.id) }
        let host = ACPHost(root: root)
        let conversation = IDEAgentConversation(
            settings: settings, store: nil,
            clientFactory: { _ in MockLLMClient(turns: []) })
        conversation.host = host
        return (conversation, host, settings)
    }

    func testDefinitionParsing() {
        let parsed = IDEACPDefinition.parseCommandLine(#"my-agent --acp --name "a b""#)
        XCTAssertEqual(parsed?.command, "my-agent")
        XCTAssertEqual(parsed?.args, ["--acp", "--name", "a b"])
        XCTAssertNil(IDEACPDefinition.parseCommandLine("   "))
    }

    func testRegistryPersistsAndRequiresConsent() {
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.addACPAgent(name: "A", commandLine: "agent --acp")
        XCTAssertNil(settings.activeACPAgent, "not active until allowed")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        XCTAssertEqual(settings.activeACPAgent?.name, "A")
        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.acpAgents.count, 1)
        XCTAssertEqual(reloaded.activeACPAgent?.id, id)
        reloaded.removeACPAgent(id: id)
        XCTAssertTrue(reloaded.acpAgents.isEmpty)
        XCTAssertNil(reloaded.acpActiveAgentID)
    }

    func testConversationEndToEndReadsDirtyBufferApprovesAndWrites() async throws {
        let (root, script, log, pid) = try makeProject()
        try "disk".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        host.unsaved[root.appendingPathComponent("a.txt").path] = "dirty"
        conversation.submit(text: "full please")
        await acpEventually("approval card appears") {
            conversation.entries.contains { $0.approval != nil }
        }
        if let approval = conversation.entries.first(where: { $0.approval != nil })?.approval {
            conversation.decide(callID: approval.callID, .approve)
        }
        await acpEventually("run finishes") { !conversation.isRunning }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("Hello from ACP"), assistant)
        XCTAssertTrue(assistant.contains("read:dirty"), assistant)
        XCTAssertTrue(assistant.contains("perm:allow-once"), assistant)
        XCTAssertTrue(assistant.contains("write:ok"), assistant)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "written")
        XCTAssertEqual(conversation.acpCurrentModeID, "agent")
        XCTAssertEqual(conversation.acpConfigOptions.first?.id, "model")
        conversation.teardown()
    }

    func testPlanModeGatingRejectsPermissionAndWrite() async throws {
        let (root, script, log, pid) = try makeProject()
        try "disk".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        conversation.setMode(.plan)
        conversation.submit(text: "full please")
        await acpEventually("run finishes") { !conversation.isRunning && conversation.entries.contains { $0.kind == .assistant } }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("perm:reject-once"), assistant)
        XCTAssertTrue(assistant.contains("write:failed"), assistant)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.teardown()
    }

    func testCrashThenRestartLoadsSession() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        conversation.submit(text: "crash now")
        await acpEventually("crash ends the run") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        conversation.restartACP()
        conversation.submit(text: "hello again")
        await acpEventually("restarted run finishes") {
            !conversation.isRunning && conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined().contains("Hello from ACP")
        }
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("session/load"), logText)
        // Teardown kills the agent process group.
        let pidValue = Int32((try String(contentsOf: pid, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) {
            pidValue == 0 || kill(pidValue, 0) != 0
        }
    }
}
