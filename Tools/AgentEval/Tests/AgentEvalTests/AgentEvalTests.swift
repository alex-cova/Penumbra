import AgentKit
import Foundation
import Testing
@testable import AgentEvalKit

private let hasPython: Bool = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
    || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
    || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3")

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-eval-tests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func builtInTasks(only ids: [String]? = nil) throws -> [EvalTask] {
    try TaskLibrary.load(from: TaskLibrary.defaultDirectory(), only: ids)
}

@Suite struct TaskLibraryTests {
    @Test func theBuiltInTasksLoadSortedWithTheirFiles() throws {
        let tasks = try builtInTasks()
        #expect(tasks.map(\.id) == tasks.map(\.id).sorted())
        #expect(tasks.count >= 8)
        for task in tasks {
            #expect(FileManager.default.fileExists(atPath: task.projectDirectory.path), "\(task.id) project")
            #expect(task.solutionDirectory != nil, "\(task.id) needs a reference solution to be validated")
            #expect(!task.protected.isEmpty, "\(task.id) must protect its tests")
            #expect(["easy", "medium", "hard"].contains(task.difficulty))
        }
    }

    @Test func selectingKeepsTheRequestedOrderAndRejectsUnknownNames() throws {
        let some = try builtInTasks(only: ["fix-two-bugs", "fix-off-by-one"])
        #expect(some.map(\.id) == ["fix-two-bugs", "fix-off-by-one"])
        #expect(throws: TaskLibraryError.unknownTasks(["nope", "nada"])) { try builtInTasks(only: ["fix-off-by-one", "nope", "nada"]) }
    }

    @Test func aMissingFolderAndMalformedTasksAreExplained() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: TaskLibraryError.noTasksFolder(folder.appendingPathComponent("absent").path)) {
            try TaskLibrary.load(from: folder.appendingPathComponent("absent"))
        }
        try write("{ not json", to: folder.appendingPathComponent("broken/task.json"))
        #expect(throws: TaskLibraryError.self) { try TaskLibrary.load(from: folder) }

        try FileManager.default.removeItem(at: folder.appendingPathComponent("broken"))
        try write(#"{"title":"t","prompt":"p","check":"true"}"#, to: folder.appendingPathComponent("noproject/task.json"))
        #expect(throws: TaskLibraryError.invalidTask(id: "noproject", reason: "no project/ folder")) { try TaskLibrary.load(from: folder) }

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("noproject/project"), withIntermediateDirectories: true)
        let loaded = try TaskLibrary.load(from: folder)
        #expect(loaded.first?.timeoutSeconds == 60 && loaded.first?.protected == [] && loaded.first?.difficulty == "medium", "defaults")
    }
}

@Suite(.enabled(if: hasPython)) struct BuiltInTaskValidityTests {
    /// The guard on the task set itself: every task fails untouched and passes with its reference
    /// solution, which leaves the tests alone. A broken fixture would otherwise show up as a model failure.
    @Test func everyTaskFailsBeforeAndPassesWithTheReferenceSolution() async throws {
        for task in try builtInTasks() {
            let result = try await TaskValidator.validate(task)
            #expect(result.pristineFails, "\(task.id) passes before any change")
            #expect(result.solutionPasses == true, "\(task.id) reference solution fails")
            #expect(result.protectedUntouchedBySolution == true, "\(task.id) solution edits its tests")
        }
    }

    @Test func untouchedProjectsFailBecauseOfTheirTestsNotBecauseTheyCannotRun() async throws {
        // A discovery or import error reads as "fails" too, which would make every task look valid.
        for task in try builtInTasks() where task.id != "extract-duplicate" {
            let sandbox = try Sandbox.create(from: task.projectDirectory)
            defer { sandbox.remove() }
            let result = await CheckRunner.run(task.check, in: sandbox.root, timeout: 60)
            #expect(result.output.contains("FAILED (") || result.output.contains("FAIL:") || result.output.contains("ERROR:"), "\(task.id): \(result.output.suffix(200))")
            #expect(!result.output.contains("Start directory is not importable"), "\(task.id)")
        }
    }
}

@Suite struct SandboxTests {
    @Test func aSandboxIsACopyAndSnapshotsIgnoreInterpreterCaches() throws {
        let source = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: source) }
        try write("a", to: source.appendingPathComponent("a.py"))
        try write("t", to: source.appendingPathComponent("tests/test_a.py"))
        let sandbox = try Sandbox.create(from: source)
        defer { sandbox.remove() }
        try write("junk", to: sandbox.root.appendingPathComponent("__pycache__/a.cpython-314.pyc"))
        try write("junk", to: sandbox.root.appendingPathComponent("tests/__pycache__/x.pyc"))
        #expect(Set(sandbox.snapshot().keys) == ["a.py", "tests/test_a.py"])
        try write("changed", to: sandbox.root.appendingPathComponent("a.py"))
        #expect(try String(contentsOf: source.appendingPathComponent("a.py"), encoding: .utf8) == "a", "the original is untouched")
    }

    @Test func protectedFilesAreJudgedByContentAndCreationAndDeletionCount() throws {
        let before: [String: UInt64] = ["src/a.py": 1, "tests/test_a.py": 2, "tests/test_b.py": 3]
        var after = before
        #expect(Sandbox.violations(protected: ["tests/**"], before: before, after: after).isEmpty)
        after["src/a.py"] = 9
        #expect(Sandbox.violations(protected: ["tests/**"], before: before, after: after).isEmpty, "editing source is the point")
        after["tests/test_a.py"] = 9
        after["tests/test_c.py"] = 4
        after["tests/test_b.py"] = nil
        #expect(Sandbox.violations(protected: ["tests/**"], before: before, after: after) == ["tests/test_a.py", "tests/test_b.py", "tests/test_c.py"])
        #expect(Sandbox.changes(before: before, after: after) == ["src/a.py", "tests/test_a.py", "tests/test_b.py", "tests/test_c.py"])
    }

    @Test func aSolutionOverlayReplacesAndAddsFiles() throws {
        let project = try temporaryFolder(), solution = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: project); try? FileManager.default.removeItem(at: solution) }
        try write("old", to: project.appendingPathComponent("a.txt"))
        try write("new", to: solution.appendingPathComponent("a.txt"))
        try write("extra", to: solution.appendingPathComponent("sub/b.txt"))
        let sandbox = try Sandbox.create(from: project)
        defer { sandbox.remove() }
        try sandbox.overlay(solution)
        #expect(try String(contentsOf: sandbox.root.appendingPathComponent("a.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: sandbox.root.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "extra")
    }
}

@Suite struct CheckRunnerTests {
    @Test func reportsExitCodeAndTheEndOfTheOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let passed = await CheckRunner.run("echo hello; echo oops 1>&2", in: folder, timeout: 10)
        #expect(passed.passed && passed.output.contains("hello") && passed.output.contains("oops"), "stdout and stderr are both kept")
        let failed = await CheckRunner.run("echo before; exit 3", in: folder, timeout: 10)
        #expect(failed.exitCode == 3 && !failed.passed)
        let loud = await CheckRunner.run("yes line | head -c 200000; echo THE-END", in: folder, timeout: 10)
        #expect(loud.output.hasSuffix("THE-END\n") && loud.output.utf8.count < CheckRunner.maxOutputBytes + 100, "a long log keeps its verdict")
        let here = await CheckRunner.run("pwd", in: folder, timeout: 10)
        // /var is a symlink to /private/var, so compare the folder's own name.
        #expect(here.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/" + folder.lastPathComponent), "runs in the project folder")
    }

    @Test func aTimeoutKillsTheWholeProcessGroup() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let result = await CheckRunner.run("sleep 60 & echo $! > child.pid; wait", in: folder, timeout: 0.5)
        #expect(result.timedOut && !result.passed && result.exitCode == 124)
        #expect(Date().timeIntervalSince(started) < 10, "returned at the timeout, not when the sleep ended")
        let pid = try #require(Int32(String(contentsOf: folder.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(pid, 0) != 0, "the sleep the check started is gone too")
    }
}

@Suite struct SummaryTests {
    private func trial(_ id: String, _ n: Int, passed: Bool, turns: Int = 3, calls: Int = 5, seconds: Double = 10, tokens: Int = 1_000,
                       ending: String = "completed", changed: [String] = ["a.py"], protected: [String] = []) -> TrialResult {
        TrialResult(
            taskID: id, trial: n, passed: passed, protectedChanged: protected, checkExitCode: passed ? 0 : 1, checkOutput: "", ending: ending,
            turns: turns, toolCalls: calls, toolErrors: 0, runTestsCalls: 1, inputTokens: tokens, outputTokens: 0, cachedInputTokens: 0,
            compactions: 0, seconds: seconds, changedFiles: changed, finalMessage: "", error: nil)
    }

    @Test func mediansAndFailureReasonsPerTask() {
        let results = [
            trial("a", 1, passed: true, turns: 2), trial("a", 2, passed: true, turns: 8), trial("a", 3, passed: false, turns: 5, changed: []),
            trial("b", 1, passed: false, ending: "step limit"), trial("b", 2, passed: false, protected: ["tests/t.py"]),
        ]
        let summaries = Summary.perTask(results)
        #expect(summaries.map(\.taskID) == ["a", "b"])
        #expect(summaries[0].passes == 2 && summaries[0].trials == 3 && summaries[0].medianTurns == 5)
        #expect(summaries[0].failureReasons == ["no change×1"])
        #expect(Set(summaries[1].failureReasons) == ["step limit×1", "edited tests×1"])
        #expect(Summary.median([1, 2, 3, 4]) == 2.5 && Summary.median([]) == 0)
        #expect(Summary.passRate(results) == 0.4)
        #expect(Summary.failureReason(trial("c", 1, passed: false)) == "tests still fail")
        #expect(Summary.failureReason(trial("c", 1, passed: false, ending: "failed: The model kept writing tool calls that could not be read (x).")) == "unreadable tool call")
        #expect(Summary.failureReason(trial("c", 1, passed: false, ending: "failed: The API rejected the key.")) == "failed: The API rejected the key.")
        #expect(Summary.failureReason(trial("c", 1, passed: false, ending: "failed: " + String(repeating: "x", count: 100))).count == 50, "long messages are cut")
    }

    @Test func theTableNamesTheModelTheTasksAndTheTotal() {
        let report = EvalReport(
            startedAt: Date(), provider: "ollama", model: "m", toolset: "core", runTests: false, trialsPerTask: 2,
            results: [trial("fix-it", 1, passed: true), trial("fix-it", 2, passed: false, changed: [])])
        let text = Summary.render(report)
        #expect(text.hasPrefix("ollama · m · toolset core · no run_tests · 2 trials per task"))
        #expect(text.contains("fix-it") && text.contains("1/2") && text.contains("no change×1"))
        #expect(text.contains("passed 1/2 (50%)"))
    }

    @Test func reportsRoundTripThroughJSON() throws {
        let report = EvalReport(startedAt: Date(timeIntervalSince1970: 0), provider: "p", model: "m", toolset: "full", runTests: true,
                                trialsPerTask: 1, results: [trial("a", 1, passed: true)], tasks: ["a": "A task"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(EvalReport.self, from: encoder.encode(report)) == report)
    }
}

@Suite struct OptionsTests {
    @Test func defaultsAndEveryFlag() throws {
        let defaults = try Options.parse(["run", "--model", "m"])
        #expect(defaults.command == .run && defaults.provider == "ollama" && defaults.trials == 1 && defaults.toolset == .full)
        #expect(defaults.offerRunTests && defaults.jobs == 1 && defaults.maxIterations == 40 && defaults.trialTimeout == 600)

        let all = try Options.parse([
            "run", "--provider", "chat", "--model", "m", "--base-url", "http://x/v1", "--api-key-env", "K", "--trials", "3",
            "--tasks", "a, b", "--task-dir", "/tmp/t", "--toolset", "core", "--no-run-tests", "--max-iterations", "10",
            "--context", "8192", "--reasoning", "low", "--timeout", "30", "--jobs", "4", "--json", "o.json",
            "--transcripts", "tr", "--keep", "--models-dir", "/m",
        ])
        #expect(all.provider == "chat" && all.baseURL == "http://x/v1" && all.apiKeyEnvironment == "K" && all.trials == 3)
        #expect(all.taskIDs == ["a", "b"] && all.taskDirectory?.path == "/tmp/t" && all.toolset == .core && !all.offerRunTests)
        #expect(all.maxIterations == 10 && all.contextWindow == 8192 && all.reasoning == "low" && all.trialTimeout == 30 && all.jobs == 4)
        #expect(all.jsonPath == "o.json" && all.transcriptsPath == "tr" && all.keepSandboxes && all.modelsDirectory?.path == "/m")
    }

    @Test func mistakesAreNamed() {
        #expect(throws: UsageError.self) { try Options.parse(["fly"]) }
        #expect(throws: UsageError.self) { try Options.parse(["run", "--trials", "0"]) }
        #expect(throws: UsageError.self) { try Options.parse(["run", "--trials", "many"]) }
        #expect(throws: UsageError.self) { try Options.parse(["run", "--model"]) }
        #expect(throws: UsageError.self) { try Options.parse(["run", "--toolset", "huge"]) }
        #expect(throws: UsageError.self) { try Options.parse(["run", "--bogus"]) }
        #expect((try? Options.parse([]))?.command == .help)
        #expect((try? Options.parse(["--help"]))?.command == .help)
    }
}

@Suite(.enabled(if: hasPython), .serialized) struct TrialRunnerTests {
    private let configuration = EvalConfiguration(model: "mock", maxIterations: 12, trialTimeout: 30)

    private func task(_ id: String = "fix-off-by-one") throws -> EvalTask { try #require(try builtInTasks(only: [id]).first) }

    private let fixTurns: [MockTurn] = [
        .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"stats.py"}"#)),
        .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"stats.py","old_string":"range(len(values) - window)","new_string":"range(len(values) - window + 1)"}"#)),
        .toolCalls((id: "t", name: "run_tests", arguments: "{}")),
        MockTurn([.textDelta("Fixed the off-by-one."), .usage(TokenUsage(inputTokens: 900, outputTokens: 40, cachedInputTokens: 300)), .finished(.completed)]),
    ]

    @Test func aCorrectFixPassesAndTheMetricsAreCounted() async throws {
        let result = await TrialRunner.run(task: try task(), trial: 1, client: MockLLMClient(turns: fixTurns), configuration: configuration)
        #expect(result.passed, "\(result.checkOutput)")
        #expect(result.ending == "completed" && result.turns == 4 && result.toolCalls == 3 && result.toolErrors == 0)
        #expect(result.runTestsCalls == 1)
        #expect(result.changedFiles == ["stats.py"] && result.protectedChanged.isEmpty)
        #expect(result.inputTokens == 900 && result.outputTokens == 40 && result.cachedInputTokens == 300)
        #expect(result.finalMessage == "Fixed the off-by-one." && result.checkExitCode == 0 && result.error == nil)
    }

    @Test func doingNothingFailsAndEditingTheTestsFailsEvenIfTheyThenPass() async throws {
        let nothing = await TrialRunner.run(task: try task(), trial: 1, client: MockLLMClient(turns: [.text("I looked, all fine.")]), configuration: configuration)
        #expect(!nothing.passed && nothing.changedFiles.isEmpty && Summary.failureReason(nothing) == "no change")

        // Rewrite the test file so everything "passes": the verdict must still be a failure.
        let cheat: [MockTurn] = [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"tests/test_stats.py"}"#)),
            .toolCalls((id: "w", name: "write_file", arguments: #"{"path":"tests/test_stats.py","content":"import unittest\n\nclass T(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(True)\n"}"#)),
            .text("Done."),
        ]
        let cheated = await TrialRunner.run(task: try task(), trial: 1, client: MockLLMClient(turns: cheat), configuration: configuration)
        #expect(cheated.checkExitCode == 0, "the rewritten tests do pass")
        #expect(!cheated.passed && cheated.protectedChanged == ["tests/test_stats.py"])
        #expect(Summary.failureReason(cheated) == "edited tests")
    }

    @Test func theToolsetAndRunTestsSwitchControlWhatTheModelIsOffered() async throws {
        let full = MockLLMClient(turns: [.text("ok")])
        _ = await TrialRunner.run(task: try task(), trial: 1, client: full, configuration: configuration)
        let fullNames = Set(full.requests[0].tools.map(\.name))
        #expect(fullNames == ["read_file", "list_dir", "glob", "grep", "edit_file", "write_file", "apply_patch", "todo", "run_tests"])

        let core = MockLLMClient(turns: [.text("ok")])
        var coreConfiguration = configuration
        coreConfiguration.toolset = .core
        _ = await TrialRunner.run(task: try task(), trial: 1, client: core, configuration: coreConfiguration)
        #expect(Set(core.requests[0].tools.map(\.name)) == ["read_file", "list_dir", "grep", "edit_file", "write_file", "run_tests"])

        let blind = MockLLMClient(turns: [.text("ok")])
        coreConfiguration.offerRunTests = false
        _ = await TrialRunner.run(task: try task(), trial: 1, client: blind, configuration: coreConfiguration)
        #expect(!blind.requests[0].tools.map(\.name).contains("run_tests"))
        #expect(!blind.requests[0].tools.map(\.name).contains("run_command"), "the model never gets a shell")
    }

    @Test func aTrialThatOutrunsItsTimeoutEndsAsTimeoutAndIsStillChecked() async throws {
        let slow = MockLLMClient(turns: [MockTurn([.textDelta("a"), .textDelta("b"), .textDelta("c"), .finished(.completed)], delayPerEvent: .seconds(2))])
        var short = configuration
        short.trialTimeout = 0.4
        let started = Date()
        let result = await TrialRunner.run(task: try task(), trial: 1, client: slow, configuration: short)
        #expect(result.ending == "timeout" && !result.passed)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.checkExitCode != 0, "the check still ran")
    }

    @Test func theSandboxIsRemovedUnlessKeptAndATranscriptIsWritten() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("out/fix-1.txt")
        let kept = await TrialRunner.run(task: try task(), trial: 1, client: MockLLMClient(turns: fixTurns), configuration: configuration, keepSandbox: true, transcript: transcript)
        let line = try #require(kept.finalMessage.components(separatedBy: "[sandbox kept at ").last)
        let path = String(line.dropLast())
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)

        let text = try String(contentsOf: transcript, encoding: .utf8)
        #expect(text.contains("PROMPT:") && text.contains("CALL edit_file") && text.contains("CHECK: exit 0") && text.contains("RESULT: PASS"))
    }
}
