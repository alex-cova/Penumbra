import AgentEvalKit
import AgentKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let options: Options
do { options = try Options.parse(Array(CommandLine.arguments.dropFirst())) } catch {
    fail("\(error)\n\nRun `agent-eval help` for usage.")
}

let taskDirectory = options.taskDirectory ?? TaskLibrary.defaultDirectory()

switch options.command {
case .help:
    print(Options.usage)

case .list:
    do {
        for task in try TaskLibrary.load(from: taskDirectory) {
            print("\(task.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(task.difficulty.padding(toLength: 7, withPad: " ", startingAt: 0)) \(task.title)")
        }
    } catch { fail("\(error)") }

case .validate:
    do {
        let tasks = try TaskLibrary.load(from: taskDirectory, only: options.taskIDs)
        var invalid = 0
        for task in tasks {
            let result = try await TaskValidator.validate(task)
            let verdict = result.isValid ? "ok" : "INVALID"
            var notes: [String] = []
            if !result.pristineFails { notes.append("passes before any change") }
            if result.solutionPasses == nil { notes.append("no solution/ folder") }
            if result.solutionPasses == false { notes.append("reference solution fails") }
            if result.protectedUntouchedBySolution == false { notes.append("reference solution edits protected files") }
            print("\(task.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(verdict)\(notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")")")
            if !result.isValid { invalid += 1 }
        }
        exit(invalid == 0 ? 0 : 1)
    } catch { fail("\(error)") }

case .run:
    let tasks: [EvalTask]
    let setup: ProviderSetup
    do {
        tasks = try TaskLibrary.load(from: taskDirectory, only: options.taskIDs)
        setup = try await Providers.make(options)
    } catch { fail("\(error)") }

    let model = options.model ?? ""
    let configuration = EvalConfiguration(
        model: model, reasoningEffort: options.reasoning, maxIterations: options.maxIterations,
        contextWindow: setup.contextWindow, trialTimeout: options.trialTimeout, toolset: options.toolset,
        offerRunTests: options.offerRunTests)
    // Local models share one GPU; parallel trials would only slow each other and skew the timings.
    let jobs = setup.isLocal ? 1 : options.jobs
    let transcripts = options.transcriptsPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let work = tasks.flatMap { task in (1...options.trials).map { (task, $0) } }
    print("\(setup.label) · toolset \(options.toolset.rawValue) · \(tasks.count) tasks × \(options.trials) trial(s)\n")

    let started = Date()
    var results: [TrialResult] = []
    var finished = 0
    await withTaskGroup(of: TrialResult.self) { group in
        var next = 0
        func launch() {
            guard next < work.count else { return }
            let (task, trial) = work[next]
            next += 1
            group.addTask {
                await TrialRunner.run(
                    task: task, trial: trial, client: setup.client, configuration: configuration, keepSandbox: options.keepSandboxes,
                    transcript: transcripts?.appendingPathComponent("\(task.id)-\(trial).txt"))
            }
        }
        for _ in 0..<min(jobs, work.count) { launch() }
        while let result = await group.next() {
            finished += 1
            results.append(result)
            let why = result.passed ? "" : "  (\(Summary.failureReason(result)))"
            print("[\(finished)/\(work.count)] \(result.taskID) #\(result.trial)  \(result.passed ? "PASS" : "FAIL")  \(result.turns) turns, \(result.toolCalls) calls, \(Int(result.seconds.rounded())) s\(why)")
            fflush(stdout)
            launch()
        }
    }

    results.sort { ($0.taskID, $0.trial) < ($1.taskID, $1.trial) }
    let report = EvalReport(
        startedAt: started, provider: options.provider, model: model, toolset: options.toolset.rawValue,
        runTests: options.offerRunTests, trialsPerTask: options.trials, results: results,
        tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) }))
    print("\n" + Summary.render(report))
    if let path = options.jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(report).write(to: URL(fileURLWithPath: path)) } catch { fail("Could not write \(path): \(error.localizedDescription)") }
        print("results written to \(path)")
    }
}
