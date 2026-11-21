import AgentKit
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Umbra

// MARK: - A mock of each provider

/// One script that answers like Kiro, Cursor or Muse (argv[1]). The `initialize` and `session/new`
/// shapes are trimmed from what the real CLIs answered on 2026-11-16 (Kiro CLI 2.24.1, Cursor CLI
/// 2026.11.05, Muse 1.4.20). Every method it receives is logged, one line each, for assertions.
/// A file `<log>.logged-out` makes `session/new` fail as a signed-out CLI does. `kiro3` answers like Kiro CLI
/// 3.5.0 (captured 2026-11-21): the model and an `effortLevel` (`thought_level`) are config options, and a model
/// change re-advertises the effort levels in a `config_option_update` outside any run.
private let providerMockScript = #"""
import json, os, sys
provider, log_path, pid_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(pid_path, "w") as f: f.write(str(os.getpid()))
def log(text):
    with open(log_path, "a") as f: f.write(text + "\n")
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
next_id = [1000]
def request(method, params):
    next_id[0] += 1
    rid = next_id[0]
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    for line in sys.stdin:
        if not line.strip(): continue
        msg = json.loads(line)
        if msg.get("id") == rid and "method" not in msg: return msg
        if msg.get("method"): log("late " + msg["method"])
    return {}
def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})
def text(t):
    notify("session/update", {"sessionId": "s-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}}})

def kiro3_options(model, effort):
    levels = {"claude-opus-5.5": ["low", "medium", "high", "xhigh", "max"], "gpt-5.6-sol": ["none", "low", "medium", "high"]}.get(model, [])
    options = [{"type": "select", "id": "mode", "name": "Mode", "category": "mode", "currentValue": "vibe",
                "options": [{"value": "vibe", "name": "Default"}, {"value": "plan", "name": "Plan"}]},
               {"type": "select", "id": "model", "name": "Model", "category": "model", "currentValue": model,
                "options": [{"value": "auto", "name": "auto", "description": "Models chosen by task for optimal usage and consistent quality",
                             "_meta": {"kiro": {"rateMultiplier": 1, "rateUnit": "Credit"}}},
                            {"value": "claude-opus-5.5", "name": "claude-opus-5.5", "description": "Claude Opus 5.5 model with 1M context window",
                             "_meta": {"kiro": {"rateMultiplier": 2, "rateUnit": "Credit"}}},
                            {"value": "gpt-5.6-sol", "name": "gpt-5.6-sol", "description": "OpenAI GPT 5.6 Sol with 1M context window",
                             "_meta": {"kiro": {"rateMultiplier": 4.4, "rateUnit": "Credit"}}},
                            {"value": "claude-haiku-5.5", "name": "claude-haiku-5.5", "description": "Claude Haiku 5.5 model with 1M context window",
                             "_meta": {"kiro": {"rateMultiplier": 0.06, "rateUnit": "Credit"}}}]}]
    if levels:
        options.append({"type": "select", "id": "effortLevel", "name": "Effort", "category": "thought_level",
                        "currentValue": effort if effort in levels else levels[1],
                        "options": [{"value": v, "name": v.capitalize()} for v in levels]})
    options.append({"type": "select", "id": "autopilot", "name": "autopilot", "currentValue": "on",
                    "options": [{"value": "on", "name": "on"}, {"value": "off", "name": "off"}]})
    return options
kiro3 = {"model": "claude-opus-5.5", "effort": "medium"}

AUTH = {
    "kiro": [], "kiro3": [],
    "cursor": [{"id": "cursor_login", "name": "Cursor Login", "description": "Run 'agent login' first if not logged in."}],
    "muse": [{"id": "muse-login", "name": "Log in to Muse", "description": "Sign in with a device code shown in your browser."}],
}[provider]
SESSION = {
    "kiro": {"modes": {"currentModeId": "kiro_default", "availableModes": [
                {"id": "kiro_default", "name": "kiro_default"}, {"id": "kiro_planner", "name": "kiro_planner"}]},
             "models": {"currentModelId": "auto", "availableModels": [
                {"modelId": "auto", "name": "auto"}, {"modelId": "claude-sonnet-5.5", "name": "claude-sonnet-5.5"}]}},
    "kiro3": {"modes": {"currentModeId": "vibe", "availableModes": [{"id": "vibe", "name": "Default"}, {"id": "plan", "name": "Plan"}]},
              "configOptions": kiro3_options("claude-opus-5.5", "medium")},
    "cursor": {"modes": {"currentModeId": "agent", "availableModes": [
                {"id": "agent", "name": "Agent"}, {"id": "plan", "name": "Plan"}, {"id": "ask", "name": "Ask"}]},
               "models": {"currentModelId": "composer-2.5[fast=true]", "availableModels": [
                {"modelId": "composer-2.5[fast=true]", "name": "composer-2.5"}, {"modelId": "gpt-5.5[context=272k]", "name": "gpt-5.5"}]}},
    "muse": {"modes": {"currentModeId": "allowAll", "availableModes": [
                {"id": "allowAll", "name": "Allow all"}, {"id": "promptUnmatched", "name": "Ask before unmatched actions"},
                {"id": "onRequest", "name": "Ask on request"}, {"id": "denyUnmatched", "name": "Deny unmatched actions"}]},
             "configOptions": [
                {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "allowAll",
                 "options": [{"value": "allowAll", "name": "Allow all"}, {"value": "promptUnmatched", "name": "Ask before unmatched actions"}]},
                {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "muse-spark-1.3",
                 "options": [{"value": "muse-spark-1.3", "name": "muse-spark-1.3"}, {"value": "muse-wonder-1.0", "name": "muse-wonder-1.0"}]}]},
}[provider]

for line in sys.stdin:
    if not line.strip(): continue
    msg = json.loads(line)
    method = msg.get("method")
    if method is None: continue
    params = msg.get("params") or {}
    if method == "session/set_mode": log("session/set_mode " + params.get("modeId", ""))
    elif method == "session/set_model": log("session/set_model " + params.get("modelId", ""))
    elif method == "session/set_config_option": log("session/set_config_option " + params.get("configId", "") + "=" + str(params.get("value", "")))
    else: log(method)
    if "id" not in msg: continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1,
              "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}},
              "authMethods": AUTH}})
    elif method == "authenticate":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
    elif method in ("session/new", "session/load"):
        if os.path.exists(log_path + ".logged-out"):
            send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000,
                  "message": "Not logged in. Open https://example.invalid/device and enter ABCD-1234."}})
        else:
            result = {"sessionId": "s-1"}; result.update(SESSION)
            send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
    elif method == "session/set_config_option" and provider == "kiro3":
        key = {"model": "model", "effortLevel": "effort"}.get(params.get("configId"))
        if key: kiro3[key] = params.get("value")
        # Like Kiro: the answer has the options as they were, the new effort levels follow in an update.
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"configOptions": kiro3_options(kiro3["model"], kiro3["effort"]) if key == "effort" else SESSION["configOptions"]}})
        notify("session/update", {"sessionId": "s-1", "update": {"sessionUpdate": "config_option_update",
               "configOptions": kiro3_options(kiro3["model"], kiro3["effort"])}})
    elif method in ("session/set_mode", "session/set_model", "session/set_config_option"):
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
    elif method == "session/prompt":
        prompt = "".join(b.get("text", "") for b in params.get("prompt", []))
        text("Hello from " + provider)
        if provider == "cursor" and "ask" in prompt:
            answer = request("cursor/ask_question", {"sessionId": "s-1", "toolCallId": "ask-1", "title": "Question",
                "questions": [{"id": "q1", "prompt": "Which mode?", "options": [{"id": "agent", "label": "Agent"}, {"id": "plan", "label": "Plan"}]}]})
            outcome = answer.get("result", {}).get("outcome", {})
            picked = ",".join(a["selectedOptionIds"][0] for a in outcome.get("answers", []))
            text(" asked:" + outcome.get("outcome", "none") + ":" + picked)
        if provider == "cursor" and "plan" in prompt:
            notify("cursor/update_todos", {"sessionId": "s-1", "toolCallId": "t", "merge": False,
                   "todos": [{"id": "1", "content": "Write it", "status": "pending"}]})
            answer = request("cursor/create_plan", {"sessionId": "s-1", "toolCallId": "plan-1", "plan": "\u0023 Plan\n1. Write it",
                   "todos": [{"id": "1", "content": "Write it", "status": "pending"}]})
            text(" planned:" + answer.get("result", {}).get("outcome", {}).get("outcome", "none"))
        if "unknown" in prompt:
            answer = request("_kiro.dev/commands/execute", {"sessionId": "s-1"})
            text(" unknown:" + str(answer.get("error", {}).get("code", "answered")))
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}})
"""#

@MainActor
private final class ProviderHost: IDEAgentHost {
    var agentProjectRoot: URL?
    init(root: URL?) { agentProjectRoot = root }
    func agentUnsavedBuffers() -> [String: String] { [:] }
    func agentEditorContext() -> String { "[Editor state]\n[End editor state]" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {}
    func agentCreateFile(relativePath: String, contents: String) async throws {}
    func agentTrashFile(relativePath: String) async throws {}
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { AgentCommandEnvironment.make(javaHome: nil) }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome { .notStarted("no") }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}

// MARK: - Catalog, discovery, provider rules (no process)

final class IDEACPNativeProviderCatalogTests: XCTestCase {
    func testKiroCursorAndMuseAreNativeCLIsWithTheirDocumentedCommands() throws {
        for (id, command, args) in [("kiro", "kiro-cli", ["acp"]), ("cursor", "agent", ["acp"]), ("muse", "muse", ["acp"])] {
            let entry = try XCTUnwrap(IDEACPAdapterCatalog.entry(presetID: id))
            XCTAssertEqual(entry.kind, .nativeCLI(command: command, args: args))
            XCTAssertFalse(entry.isManaged, "\(id) is detected, never installed")
            XCTAssertEqual(entry.authenticationPolicy, .userInitiated, "\(id) never starts a login unasked")
            XCTAssertNotNil(entry.loginCommand)
            let preset = try XCTUnwrap(IDEACPRegistry.preset(id: id))
            XCTAssertEqual(preset.recordedLauncher.command, command)
            XCTAssertEqual(preset.recordedLauncher.args, args)
        }
        XCTAssertEqual(IDEACPRegistry.preset(id: "kiro")?.name, "Kiro")
        XCTAssertEqual(IDEACPRegistry.preset(id: "cursor")?.name, "Cursor")
        XCTAssertEqual(IDEACPRegistry.preset(id: "muse")?.name, "Muse")
        XCTAssertEqual(IDEACPAdapterCatalog.cursor.extensions, [.cursor])
        XCTAssertTrue(IDEACPAdapterCatalog.kiro.extensions.isEmpty)
        XCTAssertTrue(IDEACPAdapterCatalog.muse.isExperimental)
        // The earlier presets keep their behavior.
        XCTAssertEqual(IDEACPAdapterCatalog.codex.authenticationPolicy, .automatic)
        XCTAssertEqual(IDEACPAdapterCatalog.claude.authenticationPolicy, .automatic)
        XCTAssertEqual(IDEACPAdapterCatalog.managedEntries.map(\.id), ["codex-acp", "claude-agent-acp"])
    }

    private func resolve(
        _ presetID: String, path: String, present: Set<String>, links: [String: String] = [:],
        mode: IDEACPDefinition.LaunchMode = .auto, command: String? = nil
    ) -> IDEACPLaunchResolver.Resolution {
        let preset = IDEACPRegistry.preset(id: presetID)!
        let definition = IDEACPDefinition(
            name: preset.name, command: command ?? preset.recordedLauncher.command,
            args: preset.recordedLauncher.args, presetID: presetID, launchMode: mode)
        return IDEACPLaunchResolver.resolve(
            definition: definition, entry: definition.adapterEntry, active: nil, pathValue: path,
            isExecutable: { present.contains($0) }, systemPackageName: { _ in nil },
            resolvedPath: { links[$0] ?? $0 }, home: "/Users/me")
    }

    func testKiroIsFoundOnPathAndInTheInstallersFolderWhenPathLacksIt() throws {
        let onPath = try XCTUnwrap(resolve("kiro", path: "/opt/homebrew/bin", present: ["/opt/homebrew/bin/kiro-cli"]).launch)
        XCTAssertEqual(onPath.executable, "/opt/homebrew/bin/kiro-cli")
        XCTAssertEqual(onPath.args, ["acp"])
        XCTAssertEqual(onPath.source, .nativeCLI)
        // A GUI app's PATH often lacks ~/.local/bin, where Kiro's installer puts the CLI.
        let local = try XCTUnwrap(resolve("kiro", path: "/usr/bin:/bin", present: ["/Users/me/.local/bin/kiro-cli"]).launch)
        XCTAssertEqual(local.executable, "/Users/me/.local/bin/kiro-cli")
        XCTAssertEqual(resolve("kiro", path: "/usr/bin", present: []), .unavailable(.cliMissing("kiro-cli")))
    }

    func testCursorSkipsAnotherProgramsAgentAndFindsCursorsLaterOnPath() throws {
        // As on the Mac this was written on: Grok's `agent` comes first on the login PATH.
        let links = [
            "/Users/me/.grok/bin/agent": "/Users/me/.grok/downloads/grok-1.0.77-macos-aarch64",
            "/Users/me/.local/bin/agent": "/Users/me/.local/share/cursor-agent/versions/2026.11.05/cursor-agent",
        ]
        let launch = try XCTUnwrap(resolve(
            "cursor", path: "/Users/me/.grok/bin:/Users/me/.local/bin",
            present: Set(links.keys), links: links).launch)
        XCTAssertEqual(launch.executable, "/Users/me/.local/bin/agent")
        XCTAssertEqual(launch.args, ["acp"])
    }

    func testCursorRefusesAnAgentThatIsNotCursorsAndSaysWhy() {
        let result = resolve(
            "cursor", path: "/Users/me/.grok/bin", present: ["/Users/me/.grok/bin/agent"],
            links: ["/Users/me/.grok/bin/agent": "/Users/me/.grok/downloads/grok"])
        guard case .unavailable(let reason) = result, case .cliUnverified(let command, let path, let agent) = reason else {
            return XCTFail("expected an unverified CLI, got \(result)")
        }
        XCTAssertEqual(command, "agent")
        XCTAssertEqual(path, "/Users/me/.grok/bin/agent")
        XCTAssertEqual(agent, "Cursor")
        XCTAssertTrue(reason.message.contains("not Cursor’s CLI"), reason.message)
        XCTAssertTrue(reason.message.contains("full path"), reason.message)
    }

    func testCursorAlsoAnswersToCursorAgentAndHomebrewsCask() throws {
        let alias = try XCTUnwrap(resolve(
            "cursor", path: "/usr/local/bin", present: ["/usr/local/bin/cursor-agent"],
            links: ["/usr/local/bin/cursor-agent": "/Users/me/.local/share/cursor-agent/versions/1/cursor-agent"]).launch)
        XCTAssertEqual(alias.executable, "/usr/local/bin/cursor-agent")
        let cask = try XCTUnwrap(resolve(
            "cursor", path: "/opt/homebrew/bin", present: ["/opt/homebrew/bin/agent"],
            links: ["/opt/homebrew/bin/agent": "/opt/homebrew/Caskroom/cursor-cli/2026.11/agent"]).launch)
        XCTAssertEqual(cask.executable, "/opt/homebrew/bin/agent")
    }

    func testACustomPathIsTheUsersChoiceAndIsNotSecondGuessed() throws {
        let launch = try XCTUnwrap(resolve(
            "cursor", path: "", present: ["/opt/tools/agent"], mode: .custom, command: "/opt/tools/agent").launch)
        XCTAssertEqual(launch.executable, "/opt/tools/agent")
        XCTAssertEqual(launch.source, .custom)
        XCTAssertEqual(resolve("muse", path: "", present: [], mode: .custom, command: "/nowhere/muse"),
                       .unavailable(.customMissing("Could not find the ACP agent executable “/nowhere/muse”.")))
    }

    func testMuseFollowsUmbrasPermissionModeAndNeverStaysOnAllowAll() {
        let muse = IDEACPAdapterCatalog.muse
        let advertised = ["allowAll", "promptUnmatched", "onRequest", "denyUnmatched"]
        XCTAssertEqual(muse.agentModeID(for: .acceptEdits, current: "allowAll", advertised: advertised), "promptUnmatched")
        XCTAssertEqual(muse.agentModeID(for: .manual, current: "allowAll", advertised: advertised), "promptUnmatched")
        XCTAssertEqual(muse.agentModeID(for: .auto, current: "promptUnmatched", advertised: advertised), "onRequest")
        XCTAssertEqual(muse.agentModeID(for: .plan, current: "onRequest", advertised: advertised), "denyUnmatched")
        XCTAssertNil(muse.agentModeID(for: .acceptEdits, current: "promptUnmatched", advertised: advertised), "already there")
        XCTAssertNil(muse.agentModeID(for: .plan, current: "allowAll", advertised: ["allowAll"]), "a mode the agent did not advertise is never sent")
    }

    func testCursorEntersAndLeavesItsPlanModeButKeepsAModeTheUserPicked() {
        let cursor = IDEACPAdapterCatalog.cursor
        let advertised = ["agent", "plan", "ask"]
        XCTAssertEqual(cursor.agentModeID(for: .plan, current: "agent", advertised: advertised), "plan")
        XCTAssertEqual(cursor.agentModeID(for: .acceptEdits, current: "plan", advertised: advertised), "agent")
        XCTAssertNil(cursor.agentModeID(for: .manual, current: "ask", advertised: advertised), "Ask was picked on Cursor's chip")
        XCTAssertNil(cursor.agentModeID(for: .acceptEdits, current: "agent", advertised: advertised))
        XCTAssertNil(IDEACPAdapterCatalog.kiro.agentModeID(for: .plan, current: "kiro_default", advertised: ["kiro_default", "kiro_planner"]),
                     "Kiro's modes are agent configurations, not approval modes")
    }

    func testSignInMessageKeepsTheAgentsInstructionsAndNamesTheLoginCommand() {
        let message = IDEACPAuth.signInMessage(
            agent: "Muse", agentMessage: "Not logged in. Visit https://example.invalid/device code ABCD-1234 token=sk-abcdefghijklmnop",
            loginCommand: "muse login")
        XCTAssertTrue(message.hasPrefix("Muse needs you to sign in."))
        XCTAssertTrue(message.contains("ABCD-1234"))
        XCTAssertTrue(message.contains("Run “muse login” in Terminal"))
        XCTAssertFalse(message.contains("sk-abcdefghijklmnop"))
    }

    func testAuthRequiredIsRecognizedByCodeWhenTheAgentOffersASignIn() {
        let error = ACPError.agentError(JSONRPCError(code: -32000, message: "Session could not start"))
        XCTAssertTrue(IDEACPAuth.isAuthenticationRequired(error, agentAdvertisedMethods: true))
        XCTAssertFalse(IDEACPAuth.isAuthenticationRequired(error, agentAdvertisedMethods: false),
                       "a missing executable uses the same code and is not a sign-in")
    }
}

// MARK: - Real chats over the mock provider processes

@MainActor
final class IDEACPNativeProviderConversationTests: XCTestCase {
    private var project: URL!
    private var host: ProviderHost!
    private var chats: [IDEAgentConversation] = []

    override func setUp() async throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-providers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try providerMockScript.write(to: project.appendingPathComponent("provider_mock.py"), atomically: true, encoding: .utf8)
        host = ProviderHost(root: project)
    }

    override func tearDown() async throws {
        for chat in chats { chat.teardown() }
        try? FileManager.default.removeItem(at: project)
    }

    private var log: URL { project.appendingPathComponent("agent.log") }
    private var pidFile: URL { project.appendingPathComponent("agent.pid") }

    private func logLines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A row created from the provider's preset, pointed at the mock: a custom launch that keeps the
    /// provider's rules (auth policy, extensions, mode mapping).
    private func chat(_ presetID: String, mock: String? = nil) -> (IDEAgentConversation, IDEAgentSettings) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.acp.providers.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let row = settings.materializePreset(IDEACPRegistry.preset(id: presetID)!)
        let script = project.appendingPathComponent("provider_mock.py").path
        XCTAssertTrue(settings.updateACPAgent(
            id: row.id, name: row.name, commandLine: "/usr/bin/python3 \(script) \(mock ?? presetID) \(log.path) \(pidFile.path)"))
        settings.setACPAllowed(true, agentID: row.id)
        settings.acpActiveAgentID = row.id
        let conversation = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        conversation.host = host
        chats.append(conversation)
        return (conversation, settings)
    }

    private func assistant(_ chat: IDEAgentConversation) -> String {
        chat.entries.filter { $0.kind == .assistant }.map(\.text).joined()
    }

    private func dump(_ chat: IDEAgentConversation) -> String {
        chat.entries.map { "\($0.kind):\($0.text.prefix(120))" }.joined(separator: " | ") + " log: \(logLines())"
    }

    private func send(_ chat: IDEAgentConversation, _ text: String, until: @escaping @MainActor () -> Bool) async -> Bool {
        chat.submit(text: text)
        return await acpWaitUntil(20) { !chat.isRunning && until() }
    }

    func testKiroChatStreamsAndOffersOnlyTheModelsItAdvertised() async throws {
        let (chat, _) = chat("kiro")
        let replied = await send(chat, "hi") { self.assistant(chat).contains("Hello from kiro") }
        XCTAssertTrue(replied, dump(chat))
        XCTAssertEqual(chat.acpLiveState, .connected)
        let shown = await acpWaitUntil(5) { !chat.acpAvailableModels.isEmpty }
        XCTAssertTrue(shown, dump(chat))
        XCTAssertEqual(chat.acpAvailableModels.map(\.modelId), ["auto", "claude-sonnet-5.5"])
        XCTAssertEqual(chat.acpCurrentModelID, "auto")
        XCTAssertEqual(chat.acpAvailableModes.map(\.id), ["kiro_default", "kiro_planner"])
        chat.setACPModel("claude-sonnet-5.5")
        let switched = await acpWaitUntil(5) { chat.acpCurrentModelID == "claude-sonnet-5.5" }
        XCTAssertTrue(switched)
        XCTAssertTrue(logLines().contains("session/set_model claude-sonnet-5.5"), dump(chat))
        chat.setACPModel("not-advertised")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(logLines().contains { $0.contains("not-advertised") })
        XCTAssertFalse(logLines().contains("authenticate"))
        XCTAssertFalse(logLines().contains { $0.hasPrefix("session/set_mode ") }, "Kiro's modes are left as the user picks them")
    }

    func testKiroEffortHasItsOwnControlAndFollowsTheModel() async throws {
        let (chat, _) = chat("kiro", mock: "kiro3")
        let replied = await send(chat, "hi") { self.assistant(chat).contains("Hello from kiro3") }
        XCTAssertTrue(replied, dump(chat))
        let shown = await acpWaitUntil(5) { chat.acpEffortOption != nil }
        XCTAssertTrue(shown, dump(chat))
        let effort = try XCTUnwrap(chat.acpEffortOption)
        XCTAssertEqual(effort.id, "effortLevel")
        XCTAssertEqual(effort.selectableChoices.map(\.value), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(effort.currentChoiceTitle, "Medium")
        XCTAssertTrue(chat.acpAvailableModels.isEmpty, "Kiro 3.5 offers the model as a config option")
        XCTAssertEqual(chat.acpModelOption?.id, "model")
        XCTAssertTrue(chat.acpHasModelControls)
        XCTAssertEqual(chat.acpModelOption?.selectableChoiceDetails.map { $0.rate?.label },
                       ["1×", "2×", "4.4×", "0.06×"], "Kiro's credit multipliers are shown on the model rows")
        XCTAssertEqual(chat.acpModelOption?.selectableChoiceDetails.first?.rate?.unit, "Credit")
        try renderForLooking(IDEACPModelPickerPopover(
            conversation: chat,
            models: chat.acpModelOption!.selectableChoiceDetails.map {
                IDEACPModelPicker.Model(id: $0.value, title: $0.title, detail: $0.detail, rate: $0.rate)
            },
            currentModelID: chat.acpModelOption?.currentValueDescription), name: "acp-model-picker", size: NSSize(width: 300, height: 330))
        XCTAssertEqual(chat.acpDisplayedConfigOptions.map(\.id), ["autopilot"],
                       "the model picker shows the model and effort, the mode chip the mode")

        chat.setACPConfig(id: "effortLevel", value: "high")
        let raised = await acpWaitUntil(5) { chat.acpEffortOption?.currentValueDescription == "high" }
        XCTAssertTrue(raised, dump(chat))
        XCTAssertTrue(logLines().contains("session/set_config_option effortLevel=high"), dump(chat))

        // A model change answers with the old options; the new levels arrive in an update, with no run going.
        chat.setACPConfig(id: "model", value: "gpt-5.6-sol")
        let followed = await acpWaitUntil(5) { chat.acpEffortOption?.selectableChoices.first?.value == "none" }
        XCTAssertTrue(followed, dump(chat))
        XCTAssertFalse(chat.isRunning)

        chat.setACPConfig(id: "model", value: "auto")
        let hidden = await acpWaitUntil(5) { chat.acpEffortOption == nil }
        XCTAssertTrue(hidden, "a model with no effort levels shows no effort control")
    }

    /// Writes a PNG to `AI_MODE_PNG_DIR` to look at; does nothing without it.
    private func renderForLooking<V: View>(_ view: V, name: String, size: NSSize) throws {
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"] else { return }
        let host = NSHostingView(rootView: view
            .background(IDEAppearance.ColorToken.panel)
            .preferredColorScheme(IDEAppearance.preferredColorScheme))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testAnUnknownAgentRequestIsAnsweredSoTheTurnFinishes() async throws {
        let (chat, _) = chat("kiro")
        let replied = await send(chat, "unknown") { self.assistant(chat).contains("unknown:") }
        XCTAssertTrue(replied, dump(chat))
        XCTAssertTrue(assistant(chat).contains("unknown:-32601"), dump(chat))
    }

    func testCursorQuestionIsACardAndTheAnswerGoesBackAsTheOptionID() async throws {
        let (chat, _) = chat("cursor")
        chat.submit(text: "ask me")
        let carded = await acpWaitUntil(20) { chat.entries.contains { $0.question != nil } }
        XCTAssertTrue(carded, dump(chat))
        let question = try XCTUnwrap(chat.entries.first { $0.question != nil }?.question)
        XCTAssertEqual(question.question, "Which mode?")
        XCTAssertEqual(question.options, ["Agent", "Plan"])
        XCTAssertTrue(chat.isAwaitingUser)
        chat.answer(callID: question.callID, text: "Plan")
        let finished = await acpWaitUntil(20) { !chat.isRunning }
        XCTAssertTrue(finished)
        XCTAssertTrue(assistant(chat).contains("asked:answered:plan"), dump(chat))
        XCTAssertFalse(logLines().contains("authenticate"), "Cursor's login is never started unasked")
    }

    func testCursorPlanIsAPlanCardAndApprovingItAcceptsThePlan() async throws {
        let (chat, _) = chat("cursor")
        chat.submit(text: "make a plan")
        let carded = await acpWaitUntil(20) { chat.entries.contains { $0.plan != nil } }
        XCTAssertTrue(carded, dump(chat))
        XCTAssertEqual(chat.todos.map(\.content), ["Write it"])
        let entry = try XCTUnwrap(chat.entries.first { $0.plan != nil })
        XCTAssertTrue(entry.plan?.contains("1. Write it") == true)
        chat.approvePlan(callID: try XCTUnwrap(entry.callID), mode: .acceptEdits)
        let finished = await acpWaitUntil(20) { !chat.isRunning }
        XCTAssertTrue(finished)
        XCTAssertTrue(assistant(chat).contains("planned:accepted"), dump(chat))
    }

    func testCursorFollowsUmbrasPlanModeAndReturnsToAgent() async throws {
        let (chat, _) = chat("cursor")
        let replied = await send(chat, "hi") { self.assistant(chat).contains("Hello from cursor") }
        XCTAssertTrue(replied, dump(chat))
        XCTAssertFalse(logLines().contains { $0.hasPrefix("session/set_mode ") }, "Accept Edits leaves Cursor in Agent")
        chat.setMode(.plan)
        let planned = await acpWaitUntil(5) { self.logLines().contains("session/set_mode plan") }
        XCTAssertTrue(planned, dump(chat))
        chat.setMode(.acceptEdits)
        let back = await acpWaitUntil(5) { self.logLines().contains("session/set_mode agent") }
        XCTAssertTrue(back, dump(chat))
    }

    func testMuseIsMovedOffAllowAllBeforeTheFirstPromptAndShowsOneModelControl() async throws {
        let (chat, _) = chat("muse")
        let replied = await send(chat, "hi") { self.assistant(chat).contains("Hello from muse") }
        XCTAssertTrue(replied, dump(chat))
        let lines = logLines()
        let setMode = try XCTUnwrap(lines.firstIndex(of: "session/set_mode promptUnmatched"), "\(lines)")
        let prompt = try XCTUnwrap(lines.firstIndex(of: "session/prompt"))
        XCTAssertLessThan(setMode, prompt, "the approval mode is set before anything runs")
        let shown = await acpWaitUntil(5) { !chat.acpConfigOptions.isEmpty }
        XCTAssertTrue(shown)
        XCTAssertEqual(chat.acpCurrentModeID, "promptUnmatched")
        XCTAssertEqual(chat.acpModelOption?.id, "model", "the model picker shows Muse's model option")
        XCTAssertEqual(chat.acpDisplayedConfigOptions.map(\.id), [], "the mode chip shows the mode and the picker the model, so neither is repeated")
        XCTAssertTrue(chat.acpAvailableModels.isEmpty, "Muse offers its model as a config option, so there is no second picker")
        chat.setMode(.plan)
        let denied = await acpWaitUntil(5) { self.logLines().contains("session/set_mode denyUnmatched") }
        XCTAssertTrue(denied)
    }

    func testASignedOutMuseSaysHowToSignInAndNeverStartsTheLoginItself() async throws {
        try "".write(to: URL(fileURLWithPath: log.path + ".logged-out"), atomically: true, encoding: .utf8)
        let (chat, _) = chat("muse")
        chat.submit(text: "hi")
        let failed = await acpWaitUntil(20) { !chat.isRunning && chat.entries.contains { $0.kind == .error } }
        XCTAssertTrue(failed, dump(chat))
        let error = try XCTUnwrap(chat.entries.last { $0.kind == .error }?.text)
        XCTAssertTrue(error.contains("Muse needs you to sign in."), error)
        XCTAssertTrue(error.contains("ABCD-1234"), "the agent's own sign-in instructions are kept: \(error)")
        XCTAssertTrue(error.contains("muse login"), error)
        XCTAssertEqual(chat.acpLiveState, .authenticationRequired("Log in to Muse"))
        XCTAssertFalse(logLines().contains("authenticate"))
        // The failed process is not left running.
        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "") ?? 0
        XCTAssertGreaterThan(pid, 0)
        let gone = await acpWaitUntil(10) { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "the agent process was reaped")
    }

    func testTheConnectionTestReportsSignInWithoutStartingALogin() async throws {
        try "".write(to: URL(fileURLWithPath: log.path + ".logged-out"), atomically: true, encoding: .utf8)
        let (_, settings) = chat("cursor")
        let definition = try XCTUnwrap(settings.acpAgents.first)
        let phase = await IDEACPConnectionTest.run(
            definition: definition, workingDirectory: project, environment: AgentCommandEnvironment.make(javaHome: nil))
        XCTAssertEqual(phase, .authenticationRequired("Cursor Login"))
        XCTAssertFalse(logLines().contains("authenticate"))
    }

    func testRestartingTheAgentLeavesNoProcessBehind() async throws {
        let (chat, _) = chat("kiro")
        let replied = await send(chat, "hi") { self.assistant(chat).contains("Hello from kiro") }
        XCTAssertTrue(replied, dump(chat))
        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "") ?? 0
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(kill(pid, 0), 0, "running while the chat is open")
        chat.restartACP()
        let gone = await acpWaitUntil(10) { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "restart reaps the old process")
    }
}

// MARK: - Antigravity, GitHub Copilot, OpenCode, Kimi Code, Qwen Code (catalog only, no process)

final class IDEACPMoreNativeProviderCatalogTests: XCTestCase {
    private let expected: [(id: String, name: String, command: String, args: [String])] = [
        ("antigravity", "Antigravity", "agy", ["acp"]),
        ("copilot", "GitHub Copilot", "copilot", ["--acp"]),
        ("opencode", "OpenCode", "opencode", ["acp"]),
        ("kimi", "Kimi Code", "kimi", ["acp"]),
        ("qwen", "Qwen Code", "qwen", ["--acp"]),
    ]

    func testCommandsAndRegistration() throws {
        for item in expected {
            let entry = try XCTUnwrap(IDEACPAdapterCatalog.entry(presetID: item.id))
            XCTAssertEqual(entry.name, item.name)
            XCTAssertEqual(entry.kind, .nativeCLI(command: item.command, args: item.args))
            XCTAssertFalse(entry.isManaged)
            XCTAssertEqual(entry.authenticationPolicy, .userInitiated, "\(item.id) never starts a login unasked")
            XCTAssertNotNil(entry.loginCommand)
            let preset = try XCTUnwrap(IDEACPRegistry.preset(id: item.id))
            XCTAssertEqual(preset.recordedLauncher.command, item.command)
            XCTAssertEqual(preset.recordedLauncher.args, item.args)
            XCTAssertFalse(entry.kind == .nativeCLI(command: item.command, args: ["--experimental-acp"]))
        }
    }

    func testDiscoveryUsesPathThenInstallerFoldersAndNeverRunsAnything() throws {
        for item in expected {
            let preset = try XCTUnwrap(IDEACPRegistry.preset(id: item.id))
            let found = preset.resolution(active: nil, pathValue: "/opt/homebrew/bin:/usr/bin",
                                          isExecutable: { $0 == "/opt/homebrew/bin/\(item.command)" })
            XCTAssertEqual(found.launch?.executable, "/opt/homebrew/bin/\(item.command)")
            XCTAssertEqual(found.launch?.args, item.args)
            XCTAssertEqual(preset.resolution(active: nil, pathValue: "/usr/bin", isExecutable: { _ in false }),
                           .unavailable(.cliMissing(item.command)))
        }
        let home = NSHomeDirectory()
        let agy = try XCTUnwrap(IDEACPRegistry.preset(id: "antigravity"))
        XCTAssertEqual(agy.resolution(active: nil, pathValue: "/usr/bin",
                                      isExecutable: { $0 == "\(home)/.local/bin/agy" }).launch?.executable, "\(home)/.local/bin/agy")
    }

    func testAntigravityModesAreApprovalPoliciesAppliedOnlyWhenAdvertised() {
        let agy = IDEACPAdapterCatalog.antigravity
        let advertised = ["default", "accept-edits", "plan"]
        XCTAssertEqual(agy.agentModeID(for: .plan, current: "default", advertised: advertised), "plan")
        XCTAssertEqual(agy.agentModeID(for: .acceptEdits, current: "default", advertised: advertised), "accept-edits")
        XCTAssertEqual(agy.agentModeID(for: .manual, current: "plan", advertised: advertised), "default")
        XCTAssertNil(agy.agentModeID(for: .plan, current: "default", advertised: ["default"]), "unadvertised ids are never sent")
        XCTAssertEqual(agy.agentModeID(for: .auto, current: "plan", advertised: advertised), "default")
    }
}
