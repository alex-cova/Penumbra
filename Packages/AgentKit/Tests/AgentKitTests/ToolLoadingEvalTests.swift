import Foundation
import Testing
@testable import AgentKit

/// Opt-in gate for changes to how tools reach the model (trimming, hiding, deferring): the same
/// scenarios, run `AGENTKIT_EVAL_TRIALS` times per model, with an automatic pass or fail for each, and a
/// table of success rate, tokens and time. See `ToolLoadingEvalSupport.swift` for how to enable it.
/// `AGENTKIT_EVAL_MODELS`, `AGENTKIT_EVAL_VARIANTS` and `AGENTKIT_EVAL_SCENARIOS` (comma separated) narrow a run.
@Suite(.serialized, .enabled(if: Eval.enabled)) struct ToolLoadingEvalTests {
    enum Server: Hashable, Sendable { case files, big }

    struct Scenario: Sendable {
        var name: String
        var server: Server = .files
        /// The prompt, given the trial's folder.
        var prompt: @Sendable (URL) -> String
        /// Passes when this says so, given the folder and the final answer.
        var passes: @Sendable (URL, String) -> Bool
    }

    struct Trial {
        var passed: Bool
        var requests: Int
        var inputTokens: Int
        var seconds: Double
        var calls: [String]
        var note: String
    }

    nonisolated(unsafe) static let scenarios: [Scenario] = [
        Scenario(
            name: "mcp-write",
            prompt: { "Using the files tools, read \($0.path)/note.txt and create \($0.path)/reply.txt containing only the secret word from it. Then tell me the word." },
            passes: { dir, _ in
                ((try? String(contentsOf: dir.appendingPathComponent("reply.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "Tangerine"
            }),
        Scenario(
            name: "fetch",
            prompt: { _ in "Use web_fetch to read https://example.com and tell me in one sentence what the page is for." },
            passes: { _, answer in answer.lowercased().contains("documentation") || answer.lowercased().contains("example") }),
        Scenario(
            name: "explore",
            prompt: { _ in "Use the explore tool to find which file defines the function greet. Answer with the path only." },
            passes: { _, answer in answer.contains("Greeter.swift") }),
        Scenario(
            name: "task",
            prompt: { _ in "Use the task tool with agent general to create docs/INDEX.md listing the files in src/. Tell me when it is done." },
            passes: { dir, _ in
                ((try? String(contentsOf: dir.appendingPathComponent("docs/INDEX.md"), encoding: .utf8)) ?? "").contains("Greeter")
            }),
        Scenario(
            name: "big-create-issue", server: .big,
            prompt: { _ in "In the repository acme/widgets, create an issue titled \"Fix login bug\" with the body \"Steps to reproduce: open the login page.\" Then tell me it is done." },
            passes: { folder, _ in
                evalBigServerCalls(log: folder.deletingLastPathComponent().appendingPathComponent("calls.jsonl")).contains {
                    $0.tool == "issue_create" && $0.arguments["owner"]?.stringValue == "acme" && $0.arguments["repo"]?.stringValue == "widgets"
                        && ($0.arguments["title"]?.stringValue ?? "").contains("Fix login bug")
                }
            }),
        Scenario(
            name: "big-list-prs", server: .big,
            prompt: { _ in "List the open pull requests in acme/widgets and tell me their titles." },
            passes: { folder, answer in
                evalBigServerCalls(log: folder.deletingLastPathComponent().appendingPathComponent("calls.jsonl")).contains {
                    $0.tool == "pull_request_list" && $0.arguments["owner"]?.stringValue == "acme" && $0.arguments["repo"]?.stringValue == "widgets"
                        && ($0.arguments["state"]?.stringValue ?? "open") == "open"
                } && answer.lowercased().contains("dark mode")
            }),
    ]

    /// One way of giving the model its tools.
    struct Variant: Sendable {
        var name: String
        var trimming: ToolTrimming
        /// Hide the filesystem server's tools that duplicate our built-in file tools.
        var hidesDuplicates = false
        var filesDeferral: MCPDeferral.Mode = .never
        var bigDeferral: MCPDeferral.Mode = .never

        func hub(for server: Server, base: URL, provider: String) async -> MCPHub {
            switch server {
            case .files:
                let duplicates: Set<String> = ["read_file", "read_text_file", "read_multiple_files", "write_file", "edit_file", "list_directory",
                                               "list_directory_with_sizes", "directory_tree", "search_files"]
                return await evalFilesystemHub(
                    directory: base, trimming: trimming, hidden: hidesDuplicates ? ["files": duplicates] : [:],
                    deferral: MCPDeferral(mode: filesDeferral, provider: provider))
            case .big:
                return await evalBigServerHub(
                    log: base.appendingPathComponent("calls.jsonl"), trimming: trimming,
                    deferral: MCPDeferral(mode: bigDeferral, provider: provider))
            }
        }
    }

    static var variants: [Variant] {
        let all = [
            Variant(name: "direct", trimming: .none),
            Variant(name: "trimmed", trimming: .standard),
            Variant(name: "trimmed-hidden", trimming: .standard, hidesDuplicates: true),
            Variant(name: "deferred", trimming: .standard, hidesDuplicates: true, filesDeferral: .always, bigDeferral: .always),
            Variant(name: "big-automatic", trimming: .standard, hidesDuplicates: true, bigDeferral: .automatic),
        ]
        guard let wanted = Eval.environment["AGENTKIT_EVAL_VARIANTS"]?.split(separator: ",").map(String.init) else { return all }
        return all.filter { wanted.contains($0.name) }
    }

    static var scenarioNames: Set<String>? {
        Eval.environment["AGENTKIT_EVAL_SCENARIOS"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    static func modelLabels() -> [String] {
        Eval.environment["AGENTKIT_EVAL_MODELS"]?.split(separator: ",").map(String.init) ?? ["haiku-5.5", "gpt-4.1-mini", "bonsai-2"]
    }

    static func run(_ scenario: Scenario, model: Eval.Model, hub: MCPHub, folder: URL) async -> Trial {
        let tools = evalBuiltInTools() + (await hub.tools)
        let session = AgentSession(
            client: model.make(), tools: tools, workspace: DiskAgentWorkspace(root: folder),
            configuration: AgentConfiguration(
                model: model.id, systemPrompt: SystemPrompt.make(projectRoot: folder.path), reasoningEffort: model.effort,
                maxOutputTokens: 8_000, maxIterations: 12, toolTimeout: 300, approval: .askForCommands,
                contextWindow: model.window, compactionThreshold: 0.8))
        let started = Date()
        var answer = ""
        var calls: [String] = []
        var requests = 0
        var note = ""
        for await event in await session.send(scenario.prompt(folder)) {
            switch event {
            case .toolCallStarted(_, let name): calls.append(name)
            case .approvalRequested(let request): await session.resolveApproval(callID: request.callID, decision: .approve)
            case .assistantMessage(let text): answer = text
            case .usage: requests += 1
            case .runEnded(let ending): if ending != .completed { note = "\(ending)" }
            default: break
            }
        }
        let usage = await session.totalUsage
        return Trial(
            passed: scenario.passes(folder, answer), requests: requests, inputTokens: usage.inputTokens,
            seconds: Date().timeIntervalSince(started), calls: calls, note: note)
    }

    static func prepare(_ base: URL, trial: Int) throws -> URL {
        let folder = base.appendingPathComponent("t\(trial)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "Tangerine is the secret word. Remember it.\n".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "func greet(name: String) -> String { \"Hello, \\(name)\" }\n".write(to: folder.appendingPathComponent("src/Greeter.swift"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func matrix() async throws {
        let models = Eval.models(Self.modelLabels())
        for variant in Self.variants {
            for model in models {
                let base = FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(UUID().uuidString)").resolvingSymlinksInPath()
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                var hubs: [Server: MCPHub] = [:]
                var line: [String] = []
                var totalRequests = 0, totalInput = 0, totalSeconds = 0.0, runs = 0
                var listedTokens: [String] = []
                for scenario in Self.scenarios where Self.scenarioNames?.contains(scenario.name) ?? true {
                    if hubs[scenario.server] == nil {
                        let hub = await variant.hub(for: scenario.server, base: base, provider: model.id)
                        hubs[scenario.server] = hub
                        let tokens = ToolCost.tokens(of: await hub.tools.map(\.definition), provider: model.id)
                        listedTokens.append("\(scenario.server == .files ? "files" : "big") tools ≈\(tokens)")
                    }
                    guard let hub = hubs[scenario.server] else { continue }
                    var passed = 0
                    var failures: [String] = []
                    for trial in 1...Eval.trials {
                        let folder = try Self.prepare(base, trial: trial)
                        try? FileManager.default.removeItem(at: base.appendingPathComponent("calls.jsonl"))
                        let result = await Self.run(scenario, model: model, hub: hub, folder: folder)
                        if result.passed { passed += 1 } else { failures.append("calls=\(result.calls) \(result.note)") }
                        totalRequests += result.requests; totalInput += result.inputTokens; totalSeconds += result.seconds; runs += 1
                    }
                    line.append("\(scenario.name) \(passed)/\(Eval.trials)")
                    if !failures.isEmpty { print("EVAL   fail \(variant.name)/\(model.label)/\(scenario.name): \(failures.prefix(2))") }
                }
                let perRequest = totalRequests == 0 ? 0 : totalInput / totalRequests
                print("EVAL \(variant.name) | \(model.label) | \(line.joined(separator: " | ")) | listed: \(listedTokens.joined(separator: ", ")) | per request ≈\(perRequest) in-tok | per run \(totalInput / max(1, runs)) in-tok, \(Int(totalSeconds / Double(max(1, runs)))) s")
                for hub in hubs.values { await hub.close() }
                try? FileManager.default.removeItem(at: base)
            }
        }
    }
}
