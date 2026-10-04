import Foundation

/// Everything one `run` measured, for the table and for `--json`.
public struct EvalReport: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var provider: String
    public var model: String
    public var toolset: String
    public var runTests: Bool
    public var trialsPerTask: Int
    public var results: [TrialResult]
    public var tasks: [String: String]

    public init(startedAt: Date, provider: String, model: String, toolset: String, runTests: Bool, trialsPerTask: Int,
                results: [TrialResult], tasks: [String: String] = [:]) {
        self.startedAt = startedAt
        self.provider = provider
        self.model = model
        self.toolset = toolset
        self.runTests = runTests
        self.trialsPerTask = trialsPerTask
        self.results = results
        self.tasks = tasks
    }
}

public struct TaskSummary: Equatable, Sendable {
    public var taskID: String
    public var trials: Int
    public var passes: Int
    public var medianTurns: Double
    public var medianToolCalls: Double
    public var medianSeconds: Double
    public var meanTokens: Double
    /// How the failed trials ended, most common first.
    public var failureReasons: [String]
}

public enum Summary {
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    public static func perTask(_ results: [TrialResult]) -> [TaskSummary] {
        Dictionary(grouping: results, by: \.taskID).map { id, trials in
            let failures = trials.filter { !$0.passed }
            let reasons = Dictionary(grouping: failures, by: failureReason).sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            return TaskSummary(
                taskID: id, trials: trials.count, passes: trials.filter(\.passed).count,
                medianTurns: median(trials.map { Double($0.turns) }),
                medianToolCalls: median(trials.map { Double($0.toolCalls) }),
                medianSeconds: median(trials.map(\.seconds)),
                meanTokens: Double(trials.map { $0.inputTokens + $0.outputTokens }.reduce(0, +)) / Double(max(1, trials.count)),
                failureReasons: reasons.map { "\($0.key)×\($0.value.count)" })
        }.sorted { $0.taskID < $1.taskID }
    }

    /// Why a trial failed, in a word or two.
    public static func failureReason(_ trial: TrialResult) -> String {
        if let error = trial.error { return "error: \(error.prefix(60))" }
        if !trial.protectedChanged.isEmpty { return "edited tests" }
        if trial.ending.hasPrefix("failed:") {
            // The model's unreadable tool calls are the failure worth counting on their own.
            return trial.ending.contains("could not be read") ? "unreadable tool call" : String(trial.ending.prefix(50))
        }
        if trial.ending != "completed" { return trial.ending }
        if trial.changedFiles.isEmpty { return "no change" }
        return "tests still fail"
    }

    public static func passRate(_ results: [TrialResult]) -> Double {
        results.isEmpty ? 0 : Double(results.filter(\.passed).count) / Double(results.count)
    }

    public static func render(_ report: EvalReport) -> String {
        let summaries = perTask(report.results)
        let idWidth = max(4, summaries.map(\.taskID.count).max() ?? 4)
        func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, width - text.count))
            return right ? fill + text : text + fill
        }
        var lines = [
            "\(report.provider) · \(report.model) · toolset \(report.toolset)\(report.runTests ? "" : " · no run_tests") · \(report.trialsPerTask) trial\(report.trialsPerTask == 1 ? "" : "s") per task",
            "",
            pad("task", idWidth) + "  pass  turns  calls  secs  tokens  failures",
        ]
        for summary in summaries {
            lines.append(
                pad(summary.taskID, idWidth) + "  "
                + pad("\(summary.passes)/\(summary.trials)", 4, right: true) + "  "
                + pad(format(summary.medianTurns), 5, right: true) + "  "
                + pad(format(summary.medianToolCalls), 5, right: true) + "  "
                + pad(String(Int(summary.medianSeconds.rounded())), 4, right: true) + "  "
                + pad(tokens(summary.meanTokens), 6, right: true) + "  "
                + summary.failureReasons.joined(separator: ", "))
        }
        let total = report.results
        let passes = total.filter(\.passed).count
        let medianTokens = total.isEmpty ? 0 : Double(total.map { $0.inputTokens + $0.outputTokens }.reduce(0, +)) / Double(total.count)
        lines.append("")
        lines.append(
            "passed \(passes)/\(total.count) (\(Int((passRate(total) * 100).rounded()))%) · "
            + "\(tokens(medianTokens)) tokens and \(Int((total.map(\.seconds).reduce(0, +) / Double(max(1, total.count))).rounded())) s per trial on average")
        return lines.joined(separator: "\n")
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func tokens(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1fk", value / 1_000) : String(Int(value.rounded()))
    }
}

/// `validate`: every task must fail before the agent touches it and pass with its reference solution.
public struct TaskValidation: Equatable, Sendable {
    public var taskID: String
    public var pristineFails: Bool
    public var solutionPasses: Bool?
    public var protectedUntouchedBySolution: Bool?
    public var pristineTail: String

    public var isValid: Bool { pristineFails && solutionPasses == true && protectedUntouchedBySolution != false }
}

public enum TaskValidator {
    public static func validate(_ task: EvalTask) async throws -> TaskValidation {
        let pristine = try Sandbox.create(from: task.projectDirectory)
        defer { pristine.remove() }
        let before = await CheckRunner.run(task.check, in: pristine.root, timeout: TimeInterval(task.timeoutSeconds))
        var validation = TaskValidation(
            taskID: task.id, pristineFails: !before.passed, solutionPasses: nil, protectedUntouchedBySolution: nil,
            pristineTail: String(before.output.suffix(300)))
        guard let solution = task.solutionDirectory else { return validation }
        let solved = try Sandbox.create(from: task.projectDirectory)
        defer { solved.remove() }
        let snapshot = solved.snapshot()
        try solved.overlay(solution)
        validation.protectedUntouchedBySolution = Sandbox.violations(protected: task.protected, before: snapshot, after: solved.snapshot()).isEmpty
        let after = await CheckRunner.run(task.check, in: solved.root, timeout: TimeInterval(task.timeoutSeconds))
        validation.solutionPasses = after.passed
        return validation
    }
}
