import AgentKit
import Foundation

public struct EvalConfiguration: Sendable {
    public var model: String
    public var reasoningEffort: String?
    public var maxIterations: Int
    public var contextWindow: Int?
    /// The whole trial, model time included.
    public var trialTimeout: TimeInterval
    public var toolset: Toolset
    public var offerRunTests: Bool
    public var compactionThreshold: Double
    public var editTolerance: EditTolerance
    public var verifyBeforeStopping: Bool

    public init(
        model: String, reasoningEffort: String? = nil, maxIterations: Int = 40, contextWindow: Int? = nil,
        trialTimeout: TimeInterval = 600, toolset: Toolset = .full, offerRunTests: Bool = true,
        compactionThreshold: Double = 0.75, editTolerance: EditTolerance = .hosted, verifyBeforeStopping: Bool = true
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxIterations = maxIterations
        self.contextWindow = contextWindow
        self.trialTimeout = trialTimeout
        self.toolset = toolset
        self.offerRunTests = offerRunTests
        self.compactionThreshold = compactionThreshold
        self.editTolerance = editTolerance
        self.verifyBeforeStopping = verifyBeforeStopping
    }
}

public struct TrialResult: Codable, Sendable, Equatable {
    public var taskID: String
    public var trial: Int
    public var passed: Bool
    /// Protected files (the tests) the agent changed. A non-empty list fails the trial.
    public var protectedChanged: [String]
    public var checkExitCode: Int32
    public var checkOutput: String
    public var ending: String
    public var turns: Int
    public var toolCalls: Int
    public var toolErrors: Int
    public var runTestsCalls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var compactions: Int
    /// A compaction needed a summary and the model did not write one.
    public var summaryFailed: Bool
    /// Tokens in the tool definitions offered to the model, not including the system prompt.
    public var toolCatalogTokens: Int
    public var seconds: Double
    public var changedFiles: [String]
    public var finalMessage: String
    /// Set when the trial could not be run at all (the sandbox, say), as opposed to the model failing.
    public var error: String?
}

public enum TrialRunner {
    public static func run(
        task: EvalTask, trial: Int, client: any LLMClient, configuration: EvalConfiguration,
        keepSandbox: Bool = false, transcript: URL? = nil
    ) async -> TrialResult {
        var result = TrialResult(
            taskID: task.id, trial: trial, passed: false, protectedChanged: [], checkExitCode: -1, checkOutput: "", ending: "not run",
            turns: 0, toolCalls: 0, toolErrors: 0, runTestsCalls: 0, inputTokens: 0, outputTokens: 0, cachedInputTokens: 0,
            compactions: 0, summaryFailed: false, toolCatalogTokens: 0, seconds: 0, changedFiles: [], finalMessage: "", error: nil)
        let sandbox: Sandbox
        do { sandbox = try Sandbox.create(from: task.projectDirectory) } catch {
            result.error = "could not create the sandbox: \(error.localizedDescription)"
            return result
        }
        defer { if !keepSandbox { sandbox.remove() } }

        let before = sandbox.snapshot()
        let runTests = configuration.offerRunTests ? RunTestsTool(command: task.check, directory: sandbox.root) : nil
        let workspace = DiskAgentWorkspace(root: sandbox.root)
        let tools = configuration.toolset.tools(runTests: runTests)
        result.toolCatalogTokens = ContextBudget.tokens(system: "", tools: tools.map(\.definition))
        let session = AgentSession(
            client: client, tools: tools, workspace: workspace,
            configuration: AgentConfiguration(
                model: configuration.model,
                systemPrompt: SystemPrompt.make(
                    projectRoot: workspace.rootPath, notes: ProjectInstructions.loadRoot(at: sandbox.root)),
                reasoningEffort: configuration.reasoningEffort,
                maxIterations: configuration.maxIterations,
                approval: .approveAll,
                contextWindow: configuration.contextWindow,
                compactionThreshold: configuration.compactionThreshold,
                verifyBeforeStopping: configuration.verifyBeforeStopping,
                editTolerance: configuration.editTolerance))

        let started = Date()
        let timedOut = Atomic(false)
        let deadline = Task {
            try await Task.sleep(for: .seconds(configuration.trialTimeout))
            timedOut.set(true)
            await session.stop()
        }
        var log = "TASK \(task.id) trial \(trial)\nPROMPT: \(task.prompt)\n\n"
        var lastMessage = ""
        for await event in await session.send(task.prompt) {
            switch event {
            case .stateChanged(.streaming): result.turns += 1
            case .assistantMessage(let text):
                lastMessage = text
                log += "ASSISTANT: \(text)\n"
            case .toolCallStarted:
                result.toolCalls += 1
            case .toolCallArguments(_, let name, let arguments):
                log += "CALL \(name) \(arguments.prefix(600))\n"
            case .toolCallFinished(_, _, let output):
                if output.isError { result.toolErrors += 1 }
                log += "  -> \(output.isError ? "ERROR " : "")\(output.text.prefix(400).replacingOccurrences(of: "\n", with: "\n     "))\n"
            case .usage(let usage):
                result.inputTokens += usage.inputTokens
                result.outputTokens += usage.outputTokens
                result.cachedInputTokens += usage.cachedInputTokens
            case .compacted(let report):
                if report.changedAnything { result.compactions += 1 }
                if report.summaryFailed { result.summaryFailed = true }
            case .runEnded(let ending):
                result.ending = describe(ending)
                log += "ENDED: \(result.ending)\n"
            default: break
            }
        }
        deadline.cancel()
        if timedOut.value { result.ending = "timeout" }
        result.seconds = Date().timeIntervalSince(started)
        result.runTestsCalls = runTests?.callCount ?? 0
        result.finalMessage = String(lastMessage.prefix(500))

        // The verdict is the evaluator's own run of the check, never the model's report of it.
        let after = sandbox.snapshot()
        result.protectedChanged = Sandbox.violations(protected: task.protected, before: before, after: after)
        result.changedFiles = Sandbox.changes(before: before, after: after)
        let check = await CheckRunner.run(task.check, in: sandbox.root, timeout: TimeInterval(task.timeoutSeconds))
        result.checkExitCode = check.exitCode
        result.checkOutput = String(check.output.suffix(1_500))
        result.passed = check.passed && result.protectedChanged.isEmpty
        log += "\nCHECK: exit \(check.exitCode)\(check.timedOut ? " (timed out)" : "")\n\(check.output.suffix(1_500))\n"
        if !result.protectedChanged.isEmpty { log += "PROTECTED FILES CHANGED: \(result.protectedChanged)\n" }
        log += "RESULT: \(result.passed ? "PASS" : "FAIL")\n"
        if let transcript {
            try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? log.write(to: transcript, atomically: true, encoding: .utf8)
        }
        if keepSandbox { result.finalMessage += "\n[sandbox kept at \(sandbox.root.path)]" }
        return result
    }

    static func describe(_ ending: RunEnding) -> String {
        switch ending {
        case .completed: "completed"
        case .lengthLimit: "output limit"
        case .contentFiltered: "content filter"
        case .iterationCap: "step limit"
        case .budget: "budget"
        case .stopped: "stopped"
        case .repeatedCall(let name): "repeated \(name)"
        case .failed(let message): "failed: \(message.prefix(300))"
        }
    }
}
