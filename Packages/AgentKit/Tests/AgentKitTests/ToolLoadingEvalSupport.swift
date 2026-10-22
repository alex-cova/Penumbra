import Foundation
@testable import AgentKit

/// Shared pieces of the opt-in evals that run the harness against real models and a real MCP server
/// (`ToolLoadingEvalTests`, `ToolCostCalibrationTests`). These spend money on OpenAI and Anthropic, so
/// three things must all be present before anything is called:
///
/// 1. `AGENTKIT_EVAL` is set;
/// 2. the models to use are **named** in `AGENTKIT_EVAL_MODELS` (there is no default list, so a key that
///    sits in your shell for the smoke tests does not start an eval);
/// 3. each named model's key or server is configured (`AGENTKIT_ANTHROPIC_KEY`, `AGENTKIT_OPENAI_KEY`,
///    `AGENTKIT_OLLAMA_URL`).
///
/// And a run is refused up front if it would start more than `AGENTKIT_EVAL_MAX_RUNS` (default 40) model
/// runs, counted as variants × models × scenarios × trials.
///
///     AGENTKIT_EVAL=1 AGENTKIT_EVAL_MODELS=haiku-5.5,bonsai-2 AGENTKIT_EVAL_TRIALS=3 \
///     AGENTKIT_EVAL_VARIANTS=trimmed AGENTKIT_EVAL_SCENARIOS=mcp-write,fetch \
///     AGENTKIT_ANTHROPIC_KEY=sk-ant-… AGENTKIT_OLLAMA_URL=http://host:11434 swift test --filter ToolLoadingEval
enum Eval {
    static let environment = ProcessInfo.processInfo.environment
    static var enabled: Bool { PaidTests.allowed("AGENTKIT_EVAL") }
    static var trials: Int { Int(environment["AGENTKIT_EVAL_TRIALS"] ?? "") ?? 3 }
    static var maxRuns: Int { Int(environment["AGENTKIT_EVAL_MAX_RUNS"] ?? "") ?? 40 }

    /// The labels named in `AGENTKIT_EVAL_MODELS`; empty when it is not set.
    static var requestedModelLabels: [String] {
        (PaidTests.value("AGENTKIT_EVAL_MODELS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The requested models that are configured, with a printed note for each one that is not.
    static var requestedModels: [Model] {
        requestedModelLabels.compactMap { label in
            if let model = model(label) { return model }
            print("EVAL skipped model \(label): unknown, or its key / server variable is not set")
            return nil
        }
    }

    struct Model {
        var label: String
        var id: String
        var effort: String?
        var window: Int
        var isLocal = false
        var make: () -> any LLMClient
    }

    static func model(_ label: String) -> Model? {
        let openAI = LLMEndpoint(baseURL: LLMEndpoint.openAI.baseURL, apiKey: PaidTests.value("AGENTKIT_OPENAI_KEY"))
        let anthropic = LLMEndpoint(baseURL: LLMEndpoint.anthropic.baseURL, apiKey: PaidTests.value("AGENTKIT_ANTHROPIC_KEY"))
        switch label {
        case "haiku-5.5" where PaidTests.allowed("AGENTKIT_ANTHROPIC_KEY"):
            return Model(label: label, id: "claude-haiku-5-5", effort: "low", window: 200_000) { AnthropicMessagesClient(endpoint: anthropic) }
        case "sonnet-5.5" where PaidTests.allowed("AGENTKIT_ANTHROPIC_KEY"):
            return Model(label: label, id: "claude-sonnet-5-5", effort: "low", window: 200_000) { AnthropicMessagesClient(endpoint: anthropic) }
        case "gpt-4.1-mini" where PaidTests.allowed("AGENTKIT_OPENAI_KEY"):
            return Model(label: label, id: "gpt-4.1-mini", effort: nil, window: 128_000) { OpenAIResponsesClient(endpoint: openAI) }
        case "gpt-5-mini" where PaidTests.allowed("AGENTKIT_OPENAI_KEY"):
            return Model(label: label, id: "gpt-5-mini", effort: "low", window: 128_000) { OpenAIResponsesClient(endpoint: openAI) }
        case "bonsai-2" where PaidTests.allowed("AGENTKIT_OLLAMA_URL"):
            let url = URL(string: PaidTests.value("AGENTKIT_OLLAMA_URL")!)!
            return Model(label: label, id: PaidTests.value("AGENTKIT_OLLAMA_MODEL") ?? "bonsai-2:latest", effort: nil, window: 32_768, isLocal: true) {
                OllamaClient(endpoint: LLMEndpoint(baseURL: url, apiKey: nil), contextLength: 32_768, supportsThinking: true)
            }
        default:
            return nil
        }
    }

    static func models(_ labels: [String]) -> [Model] { labels.compactMap(model) }
}

/// An `ACPTransport` over a real child process, for MCP servers in these evals.
final class EvalProcessTransport: ACPTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let incoming: AsyncStream<Data>

    init(arguments: [String], environment: [String: String] = [:]) throws {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
            .merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let captured = continuation!
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; captured.finish() } else { captured.yield(data) }
        }
        try process.run()
    }

    func send(_ line: Data) async throws { input.fileHandleForWriting.write(line + Data([10])) }

    func close() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// The built-in tools every eval session gets (AgentKit's; Umbra adds its IDE tools on top).
func evalBuiltInTools() -> [any AgentTool] {
    ReadOnlyTools.all() + EditingTools.all() + [ExploreTool(), TaskTool(), WebFetchTool(), TodoTool(), AskUserTool(), ExitPlanModeTool()]
}

/// A hub over `@modelcontextprotocol/server-filesystem` allowed to work in `directory`.
func evalFilesystemHub(
    directory: URL, trimming: ToolTrimming = .none, hidden: [String: Set<String>] = [:], deferral: MCPDeferral = .never
) async -> MCPHub {
    let path = directory.path
    let hub = MCPHub(servers: [MCPServerConfig(name: "files", command: "npx")], trimming: trimming, hidden: hidden, deferral: deferral) { _ in
        try EvalProcessTransport(arguments: ["npx", "-y", "@modelcontextprotocol/server-filesystem", path])
    }
    await hub.start()
    return hub
}

/// A fake hosted service with 90 tools (15 kinds × list/get/create/update/search/delete), written to look
/// like a real one in size and in how wordy its descriptions are, for the deferral gate. Every call is
/// appended to a log file as one JSON line so a scenario can check what the model asked for.
let evalBigServerSource = #"""
import json, sys
log = sys.argv[1]
kinds = ["issue", "pull_request", "repository", "branch", "commit", "release", "workflow_run", "gist", "notification",
         "team", "project", "label", "milestone", "discussion", "code_scanning_alert"]
def plural(kind): return kind.replace("_", " ") + "s"
def owner_repo():
    return {"owner": {"type": "string", "description": "The account that owns the repository. This is the user or organization name in the repository URL, not the display name."},
            "repo": {"type": "string", "description": "The name of the repository without the owner prefix. It is case-insensitive."}}
def paging():
    return {"per_page": {"type": "number", "description": "Results per page, from 1 to 100. Defaults to 30."},
            "page": {"type": "number", "description": "Page number of the results to fetch. Defaults to 1."}}
tools = []
for kind in kinds:
    p = plural(kind)
    base = "Requires a token with the repo scope for private repositories; public data needs no special scope. Responses are JSON and large results are paginated, so use page and per_page to walk through them. Rate limits apply per token."
    props = owner_repo()
    tools.append({"name": kind + "_list", "description": "List " + p + " in a repository, most recently updated first. Filter by state, sort by created or updated time, and choose the direction. " + base,
        "inputSchema": {"type": "object", "properties": {**props, "state": {"type": "string", "enum": ["open", "closed", "all"], "description": "Only return items in this state. Defaults to open."},
            "sort": {"type": "string", "enum": ["created", "updated", "comments"], "description": "What to sort the results by."},
            "direction": {"type": "string", "enum": ["asc", "desc"], "description": "Sort direction. Defaults to desc."}, **paging()}, "required": ["owner", "repo"]}})
    tools.append({"name": kind + "_get", "description": "Get the details of one " + kind.replace("_", " ") + " by its number, including its title, body, state, author, labels, assignees and timestamps. " + base,
        "inputSchema": {"type": "object", "properties": {**props, "number": {"type": "number", "description": "The number that identifies the item within the repository."}}, "required": ["owner", "repo", "number"]}})
    tools.append({"name": kind + "_create", "description": "Create a new " + kind.replace("_", " ") + " in a repository with a title and an optional body written in Markdown, labels and assignees. The authenticated user becomes the author. " + base,
        "inputSchema": {"type": "object", "properties": {**props, "title": {"type": "string", "description": "The title. Keep it short and specific; it appears in lists and notifications."},
            "body": {"type": "string", "description": "The description in Markdown. Mention people with @ to notify them."},
            "labels": {"type": "array", "items": {"type": "string"}, "description": "Names of labels to apply. Labels that do not exist are ignored."},
            "assignees": {"type": "array", "items": {"type": "string"}, "description": "Logins of the people to assign. They must be collaborators."}}, "required": ["owner", "repo", "title"]}})
    tools.append({"name": kind + "_update", "description": "Update an existing " + kind.replace("_", " ") + ": change its title, body or state. Fields you leave out are left unchanged. Closing an item records who closed it. " + base,
        "inputSchema": {"type": "object", "properties": {**props, "number": {"type": "number", "description": "The number that identifies the item within the repository."},
            "title": {"type": "string", "description": "A new title."}, "body": {"type": "string", "description": "A new body in Markdown."},
            "state": {"type": "string", "enum": ["open", "closed"], "description": "The new state."}}, "required": ["owner", "repo", "number"]}})
    tools.append({"name": kind + "_search", "description": "Search " + p + " across repositories with the search query syntax, for example by text, author, label, state or date. " + base,
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "The search query. Qualifiers such as repo:owner/name, author:login and state:open narrow the results."}, **paging()}, "required": ["query"]}})
    tools.append({"name": kind + "_delete", "description": "Permanently delete a " + kind.replace("_", " ") + " from a repository. This cannot be undone and needs admin permission on the repository. " + base,
        "inputSchema": {"type": "object", "properties": {**props, "number": {"type": "number", "description": "The number that identifies the item within the repository."}}, "required": ["owner", "repo", "number"]}})

def send(message):
    sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message: continue
    method, ident = message["method"], message["id"]
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": ident, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "bigservice", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": ident, "result": {"tools": tools}})
    elif method == "tools/call":
        name = message["params"]["name"]; arguments = message["params"].get("arguments", {})
        with open(log, "a") as handle: handle.write(json.dumps({"tool": name, "arguments": arguments}) + "\n")
        if name.endswith("_list"):
            text = json.dumps([{"number": 7, "title": "Add dark mode", "state": arguments.get("state", "open")}, {"number": 9, "title": "Fix crash on launch", "state": arguments.get("state", "open")}])
        else:
            text = "OK: " + name + " done for " + str(arguments.get("owner", "")) + "/" + str(arguments.get("repo", ""))
        send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": text}]}})
    else:
        send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "no " + method}})
"""#

/// A hub over the fake 90-tool service, logging calls to `log`.
func evalBigServerHub(log: URL, trimming: ToolTrimming = .none, deferral: MCPDeferral = .never) async -> MCPHub {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("evalbig-\(UUID().uuidString).py")
    try? evalBigServerSource.write(to: script, atomically: true, encoding: .utf8)
    let logPath = log.path
    let hub = MCPHub(servers: [MCPServerConfig(name: "bigservice", command: "python3")], trimming: trimming, deferral: deferral) { _ in
        try EvalProcessTransport(arguments: ["python3", script.path, logPath])
    }
    await hub.start()
    return hub
}

/// The calls the fake service logged, as (tool, arguments).
func evalBigServerCalls(log: URL) -> [(tool: String, arguments: [String: JSONValue])] {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let value = try? JSONValue(parsing: String(line)), let tool = value["tool"]?.stringValue else { return nil }
        return (tool, value["arguments"]?.objectValue ?? [:])
    }
}
