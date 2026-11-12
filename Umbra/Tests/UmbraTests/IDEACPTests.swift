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

private let acpAuthScript = #"""
import json, os, sys
with open(sys.argv[2], "w") as f: f.write(str(os.getpid()))
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":False},"authMethods":[{"id":"chatgpt","name":"Sign in"}],"agentInfo":{"name":"codex-acp","title":"Codex"}}})
    elif method in ("session/new", "session/load", "authenticate"):
        send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32000,"message":"login required token=sk-abcdefghijklmnop"}})
    elif "id" in msg:
        send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32601,"message":"unexpected"}})
"""#

private let acpProtocolScript = #"""
import json, os, sys
with open(sys.argv[2], "w") as f: f.write(str(os.getpid()))
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":99,"agentCapabilities":{"loadSession":False},"authMethods":[]}})
    elif "id" in msg:
        send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32601,"message":"unexpected"}})
"""#

private let acpScript = #"""
import json, os, sys, time
log_path = sys.argv[1]
pid_path = sys.argv[2]
def log(msg):
    with open(log_path, "a") as f: f.write(msg + "\n")
previous = ""
try:
    with open(pid_path) as f: previous = f.read().strip()
except OSError:
    previous = ""
if previous.isdigit():
    try:
        os.kill(int(previous), 0)
        log("overlap")
    except OSError:
        pass
with open(pid_path, "w") as f: f.write(str(os.getpid()))
def control():
    try:
        with open(pid_path + ".mode") as f: return f.read().strip()
    except OSError:
        return ""
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
def notify_update(update):
    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"script-1","update":update}})
def text_chunk(text):
    notify_update({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}})
def session_result():
    return {"sessionId":"script-1","modes":{"currentModeId":"agent","availableModes":[{"id":"agent","name":"Agent"},{"id":"plan","name":"Plan"}]},"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"script-1"}]}
counter = [100]
def request(method, params):
    counter[0] += 1
    rid = "agent-%d" % counter[0]
    send({"jsonrpc":"2.0","id":rid,"method":method,"params":params})
    while True:
        line = sys.stdin.readline()
        if not line: raise SystemExit(2)
        msg = json.loads(line)
        if msg.get("method"): log(msg["method"])
        if msg.get("id") == rid: return msg
cwd = ""
for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method: log(method)
    flag = control()
    if method == "initialize":
        auth = [{"id":"chatgpt","name":"Sign in"}] if flag == "authload" else []
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession": flag != "noload"},"authMethods":auth}})
    elif method == "authenticate":
        if flag == "authload":
            send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32000,"message":"login required token=sk-abcdefghijklmnop"}})
        else:
            send({"jsonrpc":"2.0","id":msg["id"],"result":{}})
    elif method == "session/load":
        if flag == "stale":
            send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32000,"message":"session not found"}})
        elif flag == "authload":
            send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32000,"message":"login required token=sk-abcdefghijklmnop"}})
        else:
            cwd = msg["params"].get("cwd","")
            send({"jsonrpc":"2.0","id":msg["id"],"result":session_result()})
    elif method == "session/new":
        cwd = msg["params"].get("cwd","")
        send({"jsonrpc":"2.0","id":msg["id"],"result":session_result()})
    elif method == "session/set_mode":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{}})
    elif method == "session/set_config_option":
        value = msg["params"].get("value")
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":value,"options":[{"value":"script-1","name":"Script"},{"value":"other","name":"Other"}]}]}})
    elif method == "session/prompt":
        prompt = "".join(b.get("text","") for b in msg["params"].get("prompt",[]) if b.get("type")=="text")
        if "crash" in prompt:
            text_chunk("dying")
            sys.stdout.flush()
            os._exit(3)
        if "stderr" in prompt:
            sys.stderr.write("adapter failed token=sk-abcdefghijklmnop\n")
            sys.stderr.flush()
            os._exit(3)
        if "linger" in prompt:
            text_chunk("partial")
            time.sleep(30)
            text_chunk("done")
            send({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}})
            continue
        if "guard" in prompt:
            denied = request("terminal/create", {"sessionId":"script-1","command":"/usr/bin/true","cwd":"/etc"})
            text_chunk(" outside:" + ("denied" if "error" in denied else "allowed"))
            parent_name = cwd.rsplit("/", 1)[-1] + "-escape.txt"
            escape = cwd.rsplit("/", 1)[0] + "/" + parent_name
            escaped = request("fs/write_text_file", {"sessionId":"script-1","path":escape,"content":"no"})
            text_chunk(" escape:" + ("denied" if "error" in escaped else "allowed"))
            created = request("terminal/create", {"sessionId":"script-1","command":"/usr/bin/printenv","args":["UMBRA_ACP_PARENT_SECRET"]})
            if "error" in created:
                text_chunk(" parent:error")
            else:
                waited = request("terminal/wait_for_exit", {"terminalId": created["result"]["terminalId"]})
                output = waited.get("result", {}).get("output", "")
                text_chunk(" parent:" + ("leaked" if ("sk-" in output or "shouldnot" in output) else "hidden"))
                request("terminal/release", {"terminalId": created["result"]["terminalId"]})
            scoped = request("terminal/create", {"sessionId":"script-1","command":"/usr/bin/printenv","args":["UMBRA_ACP_SCOPED"]})
            if "error" in scoped:
                text_chunk(" scoped:error")
            else:
                waited = request("terminal/wait_for_exit", {"terminalId": scoped["result"]["terminalId"]})
                output = waited.get("result", {}).get("output", "")
                text_chunk(" scoped:" + output.strip())
                request("terminal/release", {"terminalId": scoped["result"]["terminalId"]})
            send({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}})
            continue
        text_chunk("Hello from ACP")
        if "elicit" in prompt:
            resp = request("elicitation/create", {"sessionId": "script-1", "message": "What color?", "mode": "form", "requestedSchema": {"type": "object", "title": "What color?", "properties": {"answer": {"type": "string"}}, "required": ["answer"]}})
            result = resp.get("result", {})
            content = result.get("content", {})
            text_chunk(" elicited:" + result.get("action", "none") + ":" + str(content.get("answer", "")))
        if "full" in prompt:
            read = request("fs/read_text_file", {"sessionId":"script-1","path": cwd + "/a.txt"})
            content = read.get("result",{}).get("content","missing")
            text_chunk(" read:" + content)
            perm = request("session/request_permission", {"sessionId":"script-1","toolCall":{"toolCallId":"perm-1","title":"Run command","rawInput":{"command":"git status"}},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]})
            outcome = perm.get("result",{}).get("outcome",{})
            option = outcome.get("optionId")
            if outcome.get("outcome") == "cancelled" or not option:
                text_chunk(" perm:cancelled")
            else:
                text_chunk(" perm:" + str(option))
                wrote = request("fs/write_text_file", {"sessionId":"script-1","path": cwd + "/b.txt","content":"written"})
                text_chunk(" write:" + ("ok" if "result" in wrote else "failed"))
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}})
"""#

/// Initialize is split across writes. The prompt reply is two updates plus the result in one write.
private let acpFragmentScript = #"""
import json, os, sys
log_path, pid_path = sys.argv[1], sys.argv[2]
with open(pid_path, "w") as f: f.write(str(os.getpid()))
def log(msg):
    with open(log_path, "a") as f: f.write(msg + "\n")
def send_raw(text):
    sys.stdout.write(text); sys.stdout.flush()
def send(obj):
    send_raw(json.dumps(obj) + "\n")
sys.stderr.write("noise token=sk-abcdefghijklmnop\n"); sys.stderr.flush()
for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method: log(method)
    if method == "initialize":
        payload = json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":False},"authMethods":[]}}) + "\n"
        send_raw(payload[:12]); send_raw(payload[12:])
    elif method == "session/new":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"sessionId":"script-1"}})
    elif method == "session/prompt":
        def note(text):
            return json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"script-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}}) + "\n"
        blob = note("Hello ") + note("world") + json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}}) + "\n"
        send_raw(blob[:8]); send_raw(blob[8:])
"""#

private let acpMalformedScript = #"""
import sys, os, time
with open(sys.argv[2], "w") as f: f.write(str(os.getpid()))
for line in sys.stdin:
    if "initialize" in line:
        sys.stdout.write("{not json\n"); sys.stdout.flush()
        time.sleep(30)
"""#

private let acpHungScript = #"""
import os, sys, time
with open(sys.argv[2], "w") as f: f.write(str(os.getpid()))
time.sleep(30)
"""#

@MainActor
final class IDEACPTests: XCTestCase {
    private func makeProject(scriptSource: String = acpScript) throws -> (root: URL, script: URL, log: URL, pid: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake_agent.py")
        try scriptSource.write(to: script, atomically: true, encoding: .utf8)
        return (root, script, root.appendingPathComponent("agent.log"), root.appendingPathComponent("agent.pid"))
    }

    private func makeConversation(
        root: URL, script: URL, log: URL, pid: URL,
        store: SessionStore? = nil,
        clientFactory: (@MainActor (IDEAgentSettings) throws -> any LLMClient)? = nil
    ) -> (IDEAgentConversation, ACPHost, IDEAgentSettings) {
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.addACPAgent(name: "Script Agent", commandLine: "/usr/bin/python3 \(script.path) \(log.path) \(pid.path)")
        if let definition = settings.acpAgents.first { settings.setACPAllowed(true, agentID: definition.id) }
        let host = ACPHost(root: root)
        let conversation = IDEAgentConversation(
            settings: settings, store: store,
            clientFactory: clientFactory ?? { _ in MockLLMClient(turns: []) })
        conversation.host = host
        return (conversation, host, settings)
    }

    private func setMode(_ pid: URL, _ mode: String?) throws {
        let url = URL(fileURLWithPath: pid.path + ".mode")
        if let mode {
            try mode.write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func transcriptSnapshot(
        root: URL, agentID: UUID, sessionID: String?, entries: [IDEAgentEntry],
        runInProgress: Bool = false, queued: [String] = []
    ) -> SessionSnapshot {
        let items: [ConversationItem] = entries.compactMap { entry in
            switch entry.kind {
            case .user: .user(entry.text)
            case .assistant: .assistant(entry.text)
            default: nil
            }
        }
        return SessionSnapshot(
            projectRoot: root.path, title: "Chat",
            items: items.isEmpty ? [.user("kept")] : items,
            host: IDEAgentSavedTranscript.encode(
                entries: entries, cost: nil, runInProgress: runInProgress, queued: queued,
                acpPinnedAgentID: agentID, acpSessionID: sessionID))
    }

    private func agentPid(_ url: URL) -> Int32 {
        Int32((try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
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

    func testElicitationCardAnswersAndSkips() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        conversation.submit(text: "elicit please")
        await acpEventually("elicitation card appears") {
            conversation.entries.contains { $0.elicitation != nil }
        }
        let callID = conversation.entries.first(where: { $0.elicitation != nil })?.elicitation?.toolCallId
            ?? conversation.entries.first(where: { $0.elicitation != nil })?.callID
        conversation.answerElicitation(callID: callID ?? "", text: "blue")
        await acpEventually("run finishes") { !conversation.isRunning }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("elicited:accept:blue"), assistant)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.teardown()
    }

    func testElicitationSkipDeclines() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        conversation.submit(text: "elicit please")
        await acpEventually("elicitation card appears") {
            conversation.entries.contains { $0.elicitation != nil }
        }
        let callID = conversation.entries.first(where: { $0.elicitation != nil })?.elicitation?.toolCallId
            ?? conversation.entries.first(where: { $0.elicitation != nil })?.callID
        conversation.answerElicitation(callID: callID ?? "", text: nil)
        await acpEventually("run finishes") { !conversation.isRunning }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("elicited:decline:"), assistant)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.teardown()
    }

    func testKeychainEnvRoundTrip() {
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let keys = IDEAgentMemoryKeyStore()
        let settings = IDEAgentSettings(defaults: defaults, keyStore: keys)
        settings.addACPAgent(name: "A", commandLine: "agent --acp")
        let id = settings.acpAgents[0].id
        XCTAssertNoThrow(try settings.saveACPEnvValue("s3cr3t", agentID: id, key: "API_KEY"))
        XCTAssertEqual(settings.acpKeychainEnv(for: id), ["API_KEY": "s3cr3t"])
        // Only the key name is persisted; the value never touches UserDefaults.
        let stored = defaults.dictionary(forKey: "umbra.agent.acpEnvKeys") as? [String: [String]]
        XCTAssertEqual(stored?[id.uuidString], ["API_KEY"])
        settings.removeACPEnvValue(agentID: id, key: "API_KEY")
        XCTAssertTrue(settings.acpKeychainEnv(for: id).isEmpty)
        XCTAssertNoThrow(try settings.saveACPEnvValue("x", agentID: id, key: "K"))
        settings.removeACPAgent(id: id)
        XCTAssertNil(try? keys.load(account: IDEAgentSettings.acpEnvAccount(agentID: id, key: "K")))
    }

    func testCrashThenRestartLoadsSession() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        conversation.submit(text: "crash now")
        await acpEventually("crash ends the run") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        if case .failed(let message) = conversation.acpLiveState {
            XCTAssertTrue(message.contains("disconnected"), message)
        } else {
            XCTFail("expected a failed agent, got \(conversation.acpLiveState)")
        }
        conversation.restartACP()
        conversation.submit(text: "hello again")
        await acpEventually("restarted run finishes") {
            !conversation.isRunning && conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined().contains("Hello from ACP")
        }
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("session/load"), logText)
        XCTAssertEqual(conversation.acpLiveState, .connected)
        // Teardown kills the agent process group.
        let pidValue = agentPid(pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) {
            pidValue == 0 || kill(pidValue, 0) != 0
        }
    }

    func testSetConfigOptionUsesTheAdvertisedValue() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("config is advertised") {
            !conversation.isRunning && conversation.acpConfigOptions.contains { $0.id == "model" }
        }
        XCTAssertEqual(conversation.acpLiveState, .connected)
        conversation.setACPConfig(id: "model", value: "other")
        await acpEventually("config value changes") {
            conversation.acpConfigOptions.first?.currentValueDescription == "other"
        }
        XCTAssertEqual(conversation.acpConfigOptions.first?.selectableChoices.map(\.value), ["script-1", "other"])
        let pinned = conversation.acpPin
        conversation.reset()
        XCTAssertEqual(conversation.acpPin, pinned)
        XCTAssertEqual(conversation.acpLiveState, .idle)
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testAuthenticationFailureDoesNotStoreOrRevealAToken() async throws {
        let (root, script, log, pid) = try makeProject(scriptSource: acpAuthScript)
        let calls = NativeCallFlag()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("auth failure is reported") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("needs authentication (Sign in)"), error)
        XCTAssertFalse(error.contains("sk-"), error)
        XCTAssertFalse(calls.called)
        if case .authenticationRequired(let method) = conversation.acpLiveState {
            XCTAssertEqual(method, "Sign in")
        } else {
            XCTFail("expected authentication required, got \(conversation.acpLiveState)")
        }
        let stored = settings.acpKeychainEnv(for: settings.acpAgents[0].id)
        XCTAssertTrue(stored.isEmpty)
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testUnsupportedProtocolDoesNotFallBackToNative() async throws {
        let (root, script, log, pid) = try makeProject(scriptSource: acpProtocolScript)
        let calls = NativeCallFlag()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("protocol failure is reported") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("protocol version 99"), error)
        XCTAssertFalse(calls.called)
        XCTAssertFalse(conversation.entries.contains { $0.kind == .assistant })
        if case .failed = conversation.acpLiveState {} else {
            XCTFail("expected a failed connection, got \(conversation.acpLiveState)")
        }
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testMissingExecutableFailsWithoutSpawning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        let missing = root.appendingPathComponent("no-such-agent").path
        settings.addACPAgent(name: "Missing", commandLine: missing)
        settings.setACPAllowed(true, agentID: settings.acpAgents[0].id)
        let calls = NativeCallFlag()
        let conversation = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        })
        let host = ACPHost(root: root)
        conversation.host = host
        conversation.submit(text: "hello")
        await acpEventually("missing executable is an error") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("Could not find"), error)
        XCTAssertFalse(error.contains("authentication"), error)
        XCTAssertFalse(calls.called)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        if case .failed = conversation.acpLiveState {} else {
            XCTFail("expected a failed connection, got \(conversation.acpLiveState)")
        }
        conversation.teardown()
    }

    func testConnectionTestHandshakesInATemporaryDirectoryAndReportsAuth() async throws {
        let (root, script, log, pid) = try makeProject()
        let (_, _, settings) = makeConversation(root: root, script: script, log: log, pid: pid)
        let definition = settings.acpAgents[0]
        let phase = await IDEACPConnectionTest.run(
            definition: definition,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: AgentCommandEnvironment.make(javaHome: nil))
        guard case .connected(let version, _, let load) = phase else {
            return XCTFail("expected a handshake, got \(phase)")
        }
        XCTAssertEqual(version, 1)
        XCTAssertTrue(load)
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("initialize"), logText)
        XCTAssertFalse(logText.contains("session/new"), logText)
        await acpEventually("probe process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }

        let authProject = try makeProject(scriptSource: acpAuthScript)
        let authSettings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        authSettings.addACPAgent(
            name: "Auth", commandLine: "/usr/bin/python3 \(authProject.script.path) \(authProject.log.path) \(authProject.pid.path)")
        let authPhase = await IDEACPConnectionTest.run(
            definition: authSettings.acpAgents[0],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: AgentCommandEnvironment.make(javaHome: nil))
        guard case .authenticationRequired(let method) = authPhase else {
            return XCTFail("expected authentication required, got \(authPhase)")
        }
        XCTAssertEqual(method, "Sign in")
        await acpEventually("auth probe process is gone", timeout: 5) { kill(agentPid(authProject.pid), 0) != 0 }
    }

    func testSwitchingDuringARunKeepsThatSessionAndOpensNative() async throws {
        let (root, script, log, pid) = try makeProject()
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .mlx
        settings.addACPAgent(name: "Script Agent", commandLine: "/usr/bin/python3 \(script.path) \(log.path) \(pid.path)")
        let agentID = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: agentID)
        let controller = IDEAgentController(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let host = ACPHost(root: root)
        controller.attach(host: host)
        let original = controller.selected
        try "disk".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        original.submit(text: "full please")
        await acpEventually("approval card appears") {
            original.isRunning && original.entries.contains { $0.approval != nil }
        }
        controller.selectProvider(.native)
        XCTAssertTrue(original.isRunning)
        XCTAssertEqual(original.resolvedACPAgentID, agentID)
        XCTAssertNotEqual(controller.selected.id, original.id)
        XCTAssertFalse(controller.selected.isACPConversation)
        XCTAssertEqual(controller.selected.effectiveChoice.provider, .mlx)
        XCTAssertNil(controller.selected.effectiveChoice.acpAgentID)
        XCTAssertTrue(original.entries.contains { $0.text.contains("Still running on Script Agent") })
        XCTAssertTrue(controller.selected.entries.contains { $0.text.contains("Umbra Native") })
        XCTAssertFalse(controller.selected.entries.contains { $0.text.contains("full please") })

        // The chat opened above already has a notice, so it is not empty. Another switch
        // opens a new chat and leaves both this one and the running chat where they are.
        let opened = controller.selected
        controller.selectProvider(.agent(agentID))
        XCTAssertNotEqual(controller.selected.id, opened.id)
        XCTAssertNotEqual(controller.selected.id, original.id)
        XCTAssertNil(opened.resolvedACPAgentID)
        XCTAssertEqual(controller.selected.resolvedACPAgentID, agentID)
        XCTAssertTrue(original.isRunning)
        XCTAssertEqual(original.resolvedACPAgentID, agentID)
        controller.selectProvider(.native)
        XCTAssertNotEqual(controller.selected.id, original.id)
        XCTAssertNil(controller.selected.resolvedACPAgentID)
        XCTAssertTrue(original.isRunning)
        XCTAssertEqual(original.resolvedACPAgentID, agentID)

        if let approval = original.entries.first(where: { $0.approval != nil })?.approval {
            original.decide(callID: approval.callID, .approve)
        }
        await acpEventually("original run finishes") {
            !original.isRunning && original.entries.filter { $0.kind == .assistant }.map(\.text).joined().contains("write:ok")
        }
        original.submit(text: "hello again")
        await acpEventually("same session answers again") {
            !original.isRunning
                && original.entries.filter { $0.kind == .assistant }.map(\.text).joined()
                    .components(separatedBy: "Hello from ACP").count >= 3
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(logText.components(separatedBy: "session/new").count - 1, 1, logText)
        XCTAssertFalse(logText.contains("session/load"), logText)

        controller.select(original.id)
        controller.selectProvider(.native)
        XCTAssertFalse(original.entries.filter { $0.kind == .assistant }.map(\.text).joined().isEmpty)
        XCTAssertEqual(original.resolvedACPAgentID, agentID)
        controller.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testConcurrentSessionsKeepSeparateProcesses() async throws {
        let first = try makeProject()
        let second = try makeProject()
        let (left, leftHost, _) = makeConversation(root: first.root, script: first.script, log: first.log, pid: first.pid)
        let (right, rightHost, _) = makeConversation(root: second.root, script: second.script, log: second.log, pid: second.pid)
        XCTAssertNotNil(leftHost.agentProjectRoot)
        XCTAssertNotNil(rightHost.agentProjectRoot)
        left.submit(text: "hello")
        right.submit(text: "hello")
        await acpEventually("left finishes") {
            !left.isRunning && left.entries.contains { $0.kind == .assistant && $0.text.contains("Hello from ACP") }
        }
        await acpEventually("right finishes") {
            !right.isRunning && right.entries.contains { $0.kind == .assistant && $0.text.contains("Hello from ACP") }
        }
        let leftPid = agentPid(first.pid)
        let rightPid = agentPid(second.pid)
        XCTAssertGreaterThan(leftPid, 0)
        XCTAssertGreaterThan(rightPid, 0)
        XCTAssertNotEqual(leftPid, rightPid)
        left.teardown()
        right.teardown()
        await acpEventually("both processes are gone", timeout: 5) {
            kill(leftPid, 0) != 0 && kill(rightPid, 0) != 0
        }
    }

    func testProcessDeathDuringStreamingEndsTheRun() async throws {
        let (root, script, log, pid) = try makeProject()
        let calls = NativeCallFlag()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "linger please")
        await acpEventually("partial text arrives") {
            conversation.entries.contains { $0.kind == .assistant && $0.text.contains("partial") }
        }
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        kill(pidValue, SIGKILL)
        await acpEventually("the run ends after the process dies") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertFalse(assistant.contains("done"), assistant)
        XCTAssertFalse(calls.called)
        if case .failed = conversation.acpLiveState {} else {
            XCTFail("expected a failed agent, got \(conversation.acpLiveState)")
        }
        conversation.teardown()
    }

    func testProcessDeathShowsSanitizedStderr() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "stderr please")
        await acpEventually("the crash is explained without the token") {
            !conversation.isRunning && conversation.entries.contains {
                $0.kind == .error && $0.text.contains("adapter failed") && $0.text.contains("[redacted]")
            }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertFalse(error.contains("sk-"), error)
        XCTAssertFalse(conversation.entries.contains { $0.kind == .assistant && $0.text.contains("Hello from ACP") })
        conversation.teardown()
    }

    func testWhitespaceSessionIDIsNotLoaded() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        let snapshot = transcriptSnapshot(
            root: root, agentID: settings.acpAgents[0].id, sessionID: "   ",
            entries: [
                IDEAgentEntry(kind: .user, text: "hello"),
                IDEAgentEntry(kind: .assistant, text: "kept"),
            ])
        conversation.load(snapshot)
        conversation.submit(text: "second")
        await acpEventually("a blank id starts a new session") {
            !conversation.isRunning && conversation.entries.contains { $0.text == IDEACPSessionResume.freshHistoryNotice }
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertFalse(logText.contains("session/load"), logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 1, logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 1, logText)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testLegacyTranscriptWithoutFingerprintStillLoads() async throws {
        let (root, script, log, pid) = try makeProject()
        let (snapshot, settings) = try await finishedHello(root: root, script: script, log: log, pid: pid)
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        XCTAssertEqual(saved.acpSessionID, "script-1")
        XCTAssertNotNil(saved.acpLaunchFingerprint)
        let legacy = transcriptSnapshot(
            root: root, agentID: settings.acpAgents[0].id, sessionID: "script-1",
            entries: [
                IDEAgentEntry(kind: .user, text: "hello"),
                IDEAgentEntry(kind: .assistant, text: "Hello from ACP"),
            ])
        XCTAssertNil(IDEAgentSavedTranscript.decode(legacy.host).acpLaunchFingerprint)
        let (next, nextHost) = reload(legacy, settings: settings, root: root)
        XCTAssertNotNil(nextHost.agentProjectRoot)
        next.submit(text: "second")
        await acpEventually("an older file still restores") {
            !next.isRunning && next.entries.contains { $0.text == IDEACPSessionResume.restoredNotice }
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(occurrences(of: "session/load", in: logText), 1, logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 1, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        next.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testStopDuringPermissionCancelsTheTool() async throws {
        let (root, script, log, pid) = try makeProject()
        try "disk".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "full please")
        await acpEventually("approval card appears") {
            conversation.entries.contains { $0.approval != nil }
        }
        conversation.stop()
        await acpEventually("the run stops") { !conversation.isRunning }
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("session/cancel"), logText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertFalse(assistant.contains("write:ok"), assistant)
        // Like Codex, this agent never reports the call after a cancelled permission. The card
        // must still go: its buttons can no longer do anything.
        XCTAssertFalse(conversation.entries.contains { $0.approval != nil }, "no card is left with live buttons")
        XCTAssertFalse(conversation.isAwaitingUser)
        XCTAssertTrue(conversation.entries.contains {
            $0.callID == "perm-1" && $0.output?.text.contains("not run") == true
        }, "the call says it was not run: \(conversation.entries.map { "\($0.kind):\($0.output?.text ?? "")" })")
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testPermissionTimeoutDoesNotRunTheTool() async throws {
        let (root, script, log, pid) = try makeProject()
        try "disk".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.acpPermissionTimeout = .milliseconds(200)
        conversation.submit(text: "full please")
        await acpEventually("the run finishes without approval") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .assistant && $0.text.contains("perm:cancelled") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("perm:cancelled"), assistant)
        XCTAssertFalse(assistant.contains("write:ok"), assistant)
        XCTAssertTrue(conversation.entries.contains {
            $0.output?.isError == true && $0.output?.text.contains("Permission request timed out") == true
        })
        XCTAssertFalse(conversation.isAwaitingUser)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testMalformedFrameClosesAndDoesNotCallNative() async throws {
        let (root, script, log, pid) = try makeProject(scriptSource: acpMalformedScript)
        let calls = NativeCallFlag()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("malformed frame is an error") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("Malformed"), error)
        XCTAssertFalse(calls.called)
        XCTAssertFalse(conversation.entries.contains { $0.kind == .assistant })
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testFragmentedFramesStillCompleteATurn() async throws {
        let (root, script, log, pid) = try makeProject(scriptSource: acpFragmentScript)
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("fragmented turn finishes") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .assistant && $0.text.contains("Hello world") }
        }
        let text = conversation.entries.map(\.text).joined()
        XCTAssertFalse(text.contains("sk-"), text)
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 1, logText)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testHungInitializeTimesOutAndKillsTheProcess() async throws {
        let (root, script, log, pid) = try makeProject(scriptSource: acpHungScript)
        let calls = NativeCallFlag()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.acpRequestTimeout = .milliseconds(400)
        conversation.submit(text: "hello")
        await acpEventually("initialize times out", timeout: 8) {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("Timed out waiting for initialize"), error)
        XCTAssertFalse(calls.called)
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        await acpEventually("hung process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
        conversation.teardown()
    }

    func testRepeatedRestartReplacesTheProcess() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, _) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        var previous: Int32 = 0
        for round in 1...3 {
            if round > 1 { conversation.restartACP() }
            conversation.submit(text: "hello \(round)")
            let expected = round
            await acpEventually("round \(round) finishes") {
                !conversation.isRunning
                    && self.occurrences(
                        of: "Hello from ACP",
                        in: conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()) == expected
            }
            let current = agentPid(pid)
            XCTAssertGreaterThan(current, 0)
            if previous != 0 {
                XCTAssertNotEqual(current, previous)
                let gone = previous
                await acpEventually("previous process is gone", timeout: 5) { kill(gone, 0) != 0 }
            }
            previous = current
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 1, logText)
        XCTAssertGreaterThanOrEqual(occurrences(of: "session/load", in: logText), 2, logText)
        XCTAssertFalse(logText.contains("overlap"), logText)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(previous, 0) != 0 }
    }

    func testSavedSessionLoadsAndDoesNotResendEarlierPrompts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-store-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: directory)
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid, store: store)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("first turn is saved") {
            !conversation.isRunning && store.load(conversation.conversationID, projectRoot: root.path) != nil
        }
        let snapshot = try XCTUnwrap(store.load(conversation.conversationID, projectRoot: root.path))
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        XCTAssertEqual(saved.acpSessionID, "script-1")
        XCTAssertEqual(saved.acpPinnedAgentID, settings.acpAgents[0].id)
        XCTAssertFalse(saved.acpLaunchFingerprint?.isEmpty ?? true)
        XCTAssertFalse(String(decoding: snapshot.host ?? Data(), as: UTF8.self).contains("sk-"))
        let firstPid = agentPid(pid)
        XCTAssertGreaterThan(firstPid, 0)
        conversation.teardown()
        await acpEventually("first process is gone", timeout: 5) { kill(firstPid, 0) != 0 }

        let next = IDEAgentConversation(settings: settings, store: store, clientFactory: { _ in MockLLMClient(turns: []) })
        let nextHost = ACPHost(root: root)
        next.host = nextHost
        next.load(snapshot)
        XCTAssertTrue(next.entries.contains { $0.kind == .user && $0.text == "hello" })
        next.submit(text: "second")
        await acpEventually("restored turn finishes") {
            !next.isRunning && next.entries.contains { $0.kind == .assistant && $0.text.contains("Hello from ACP") }
        }
        XCTAssertTrue(next.entries.contains { $0.kind == .notice && $0.text == IDEACPSessionResume.restoredNotice })
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(occurrences(of: "session/load", in: logText), 1, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 1, logText)
        next.teardown()
        await acpEventually("restored process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testSessionRestoreWithoutLoadSessionKeepsTheTranscript() async throws {
        let (root, script, log, pid) = try makeProject()
        let (snapshot, settings) = try await finishedHello(root: root, script: script, log: log, pid: pid)
        try setMode(pid, "noload")
        let (next, nextHost) = reload(snapshot, settings: settings, root: root)
        XCTAssertNotNil(nextHost.agentProjectRoot)
        next.submit(text: "second")
        await acpEventually("new session finishes") {
            !next.isRunning && next.entries.contains { $0.text == IDEACPSessionResume.unsupportedNotice }
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertFalse(logText.contains("session/load"), logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 2, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        next.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testStaleSessionStartsANewOneAndDoesNotResend() async throws {
        let (root, script, log, pid) = try makeProject()
        let (snapshot, settings) = try await finishedHello(root: root, script: script, log: log, pid: pid)
        try setMode(pid, "stale")
        let (next, nextHost) = reload(snapshot, settings: settings, root: root)
        XCTAssertNotNil(nextHost.agentProjectRoot)
        next.submit(text: "second")
        await acpEventually("stale session is replaced") {
            !next.isRunning && next.entries.contains { $0.text == IDEACPSessionResume.staleNotice }
        }
        let assistant = next.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("Hello from ACP"), assistant)
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(occurrences(of: "session/load", in: logText), 1, logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 2, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        next.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testAuthenticationFailureOnLoadDoesNotStartAnotherSession() async throws {
        let (root, script, log, pid) = try makeProject()
        try setMode(pid, "authload")
        let calls = NativeCallFlag()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid) { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        }
        XCTAssertNotNil(host.agentProjectRoot)
        let snapshot = transcriptSnapshot(
            root: root, agentID: settings.acpAgents[0].id, sessionID: "old-1",
            entries: [
                IDEAgentEntry(kind: .user, text: "earlier"),
                IDEAgentEntry(kind: .assistant, text: "kept"),
            ])
        conversation.load(snapshot)
        conversation.submit(text: "again")
        await acpEventually("authentication stops the restore") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("needs authentication"), error)
        XCTAssertFalse(error.contains("sk-"), error)
        XCTAssertFalse(calls.called)
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("session/load"), logText)
        XCTAssertFalse(logText.contains("session/new"), logText)
        XCTAssertFalse(logText.contains("session/prompt"), logText)
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
    }

    func testChangingTheCommandDoesNotLoadTheOldSession() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("first turn finishes") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .assistant }
        }
        let firstPid = agentPid(pid)
        XCTAssertGreaterThan(firstPid, 0)
        let definition = settings.acpAgents[0]
        XCTAssertTrue(settings.updateACPAgent(id: definition.id, name: definition.name, commandLine: definition.commandLine + " --again"))
        conversation.submit(text: "second")
        await acpEventually("replacement session finishes") {
            !conversation.isRunning && conversation.entries.contains { $0.text == IDEACPSessionResume.freshHistoryNotice }
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertFalse(logText.contains("session/load"), logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 2, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        let secondPid = agentPid(pid)
        XCTAssertGreaterThan(secondPid, 0)
        XCTAssertNotEqual(secondPid, firstPid)
        await acpEventually("first process is gone", timeout: 5) { kill(firstPid, 0) != 0 }
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(secondPid, 0) != 0 }
    }

    func testRelaunchAfterCommandChangeDoesNotLoadTheOldSession() async throws {
        let (root, script, log, pid) = try makeProject()
        let (snapshot, settings) = try await finishedHello(root: root, script: script, log: log, pid: pid)
        let saved = IDEAgentSavedTranscript.decode(snapshot.host)
        XCTAssertEqual(saved.acpSessionID, "script-1")
        let fingerprint = try XCTUnwrap(saved.acpLaunchFingerprint)
        XCTAssertFalse(fingerprint.contains("--again"), fingerprint)
        let definition = settings.acpAgents[0]
        XCTAssertTrue(settings.updateACPAgent(
            id: definition.id, name: definition.name, commandLine: definition.commandLine + " --again"))
        let (next, nextHost) = reload(snapshot, settings: settings, root: root)
        XCTAssertNotNil(nextHost.agentProjectRoot)
        next.submit(text: "second")
        await acpEventually("changed command starts a new session") {
            !next.isRunning && next.entries.contains { $0.text == IDEACPSessionResume.freshHistoryNotice }
        }
        let logText = (try String(contentsOf: log, encoding: .utf8))
        XCTAssertFalse(logText.contains("session/load"), logText)
        XCTAssertEqual(occurrences(of: "session/new", in: logText), 2, logText)
        XCTAssertEqual(occurrences(of: "session/prompt", in: logText), 2, logText)
        next.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    func testMissingAbsolutePathDoesNotSayOnPATH() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-abs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        let missing = root.appendingPathComponent("no-such-agent").path
        settings.addACPAgent(name: "Missing", commandLine: missing)
        settings.setACPAllowed(true, agentID: settings.acpAgents[0].id)
        let calls = NativeCallFlag()
        let conversation = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        })
        let host = ACPHost(root: root)
        conversation.host = host
        conversation.submit(text: "hello")
        await acpEventually("absolute path is an error") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .error }
        }
        let error = conversation.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(error.contains("Could not find"), error)
        XCTAssertFalse(error.contains("on PATH"), error)
        XCTAssertFalse(calls.called)
        conversation.teardown()
    }

    func testRemovedAgentDoesNotFallBackToNative() {
        let root = FileManager.default.temporaryDirectory
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .mlx
        settings.addACPAgent(name: "Gone", commandLine: "gone-agent")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        let calls = NativeCallFlag()
        let conversation = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in
            calls.called = true
            return MockLLMClient(turns: [])
        })
        let host = ACPHost(root: root)
        conversation.host = host
        conversation.acpPin = .agent(id)
        settings.removeACPAgent(id: id)
        conversation.submit(text: "hello")
        XCTAssertFalse(calls.called)
        XCTAssertFalse(conversation.isRunning)
        XCTAssertTrue(conversation.entries.contains { $0.kind == .error && $0.text.contains("no longer configured") })
        XCTAssertFalse(conversation.entries.contains { $0.kind == .assistant })
    }

    func testInterruptedACPRunDoesNotOfferResume() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-interrupt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "umbra.acp.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.addACPAgent(name: "Script Agent", commandLine: "/usr/bin/python3 /tmp/unused")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        let conversation = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let host = ACPHost(root: root)
        conversation.host = host
        conversation.load(transcriptSnapshot(
            root: root, agentID: id, sessionID: "script-1",
            entries: [IDEAgentEntry(kind: .user, text: "hello")],
            runInProgress: true, queued: ["finish later"]))
        XCTAssertTrue(conversation.entries.contains {
            $0.kind == .notice && $0.text.contains("does not send these messages again")
        })
        XCTAssertFalse(conversation.entries.contains { $0.canResume })
        XCTAssertEqual(conversation.draft, "finish later")
        XCTAssertFalse(conversation.isRunning)
    }

    func testTerminalAndFileToolsStayInsideTheProject() async throws {
        let (root, script, log, pid) = try makeProject()
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid)
        XCTAssertNotNil(host.agentProjectRoot)
        var agents = settings.acpAgents
        agents[0].env["UMBRA_ACP_SCOPED"] = "scoped-ok"
        settings.acpAgents = agents
        setenv("UMBRA_ACP_PARENT_SECRET", "sk-parentsecretvalue", 1)
        defer { unsetenv("UMBRA_ACP_PARENT_SECRET") }
        let escape = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-escape.txt")
        defer { try? FileManager.default.removeItem(at: escape) }
        conversation.submit(text: "guard please")
        await acpEventually("guard turn finishes") {
            !conversation.isRunning && conversation.entries.contains { $0.kind == .assistant && $0.text.contains("scoped:scoped-ok") }
        }
        let assistant = conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(assistant.contains("outside:denied"), assistant)
        XCTAssertTrue(assistant.contains("escape:denied"), assistant)
        XCTAssertTrue(assistant.contains("parent:hidden"), assistant)
        XCTAssertFalse(assistant.contains("sk-"), assistant)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path))
        conversation.teardown()
        await acpEventually("agent process is gone", timeout: 5) { kill(agentPid(pid), 0) != 0 }
    }

    /// One finished hello, saved, with the process already gone.
    private func finishedHello(
        root: URL, script: URL, log: URL, pid: URL
    ) async throws -> (SessionSnapshot, IDEAgentSettings) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-store-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: directory)
        let (conversation, host, settings) = makeConversation(root: root, script: script, log: log, pid: pid, store: store)
        XCTAssertNotNil(host.agentProjectRoot)
        conversation.submit(text: "hello")
        await acpEventually("hello is saved") {
            !conversation.isRunning && store.load(conversation.conversationID, projectRoot: root.path) != nil
        }
        let snapshot = try XCTUnwrap(store.load(conversation.conversationID, projectRoot: root.path))
        let pidValue = agentPid(pid)
        XCTAssertGreaterThan(pidValue, 0)
        conversation.teardown()
        await acpEventually("hello process is gone", timeout: 5) { kill(pidValue, 0) != 0 }
        return (snapshot, settings)
    }

    /// The host is returned because the conversation holds it weakly.
    private func reload(
        _ snapshot: SessionSnapshot, settings: IDEAgentSettings, root: URL
    ) -> (IDEAgentConversation, ACPHost) {
        let next = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let host = ACPHost(root: root)
        next.host = host
        next.load(snapshot)
        return (next, host)
    }
}

@MainActor
private final class NativeCallFlag {
    var called = false
}
