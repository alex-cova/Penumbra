import JavaIntelligence
import XCTest

final class JFRTextParserTests: XCTestCase {
    private func parse(_ text: String, wanted: Set<String>? = nil) -> (events: [JFRTextEvent], symbols: JavaProfileSymbols) {
        var parser = JFRTextParser(wantedEvents: wanted)
        var events: [JFRTextEvent] = []
        parser.parse(text) { events.append($0) }
        return (events, parser.symbols)
    }

    func testParsesARealPrintOfASpinningProgram() throws {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "spin-print.txt"), encoding: .utf8)
        let (events, symbols) = parse(text)
        XCTAssertEqual(events.count, 17)
        let samples = events.filter { $0.type == "jdk.ExecutionSample" }
        XCTAssertEqual(samples.count, 12)
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.thread, "main")
        XCTAssertEqual(first.threadID, 3)
        XCTAssertFalse(first.isTruncated)
        XCTAssertEqual(first.frames.count, 20)
        let leaf = symbols.method(ofFrame: first.frames[0])
        XCTAssertEqual(leaf.className, "app.Spin")
        XCTAssertEqual(leaf.name, "fib")
        XCTAssertEqual(leaf.parameters, "int")
        XCTAssertEqual(symbols.frame(first.frames[0]).line, 5)
        XCTAssertEqual(symbols.method(ofFrame: first.frames.last!).name, "main")
        XCTAssertEqual(symbols.method(ofFrame: first.frames[18]).name, "lambda$main$0")
        // Every `fib` frame on line 5 is one interned frame, not twenty.
        XCTAssertEqual(first.frames[0], first.frames[1])

        let worker = try XCTUnwrap(samples.first { $0.thread == "worker-1" })
        XCTAssertEqual(worker.threadID, 40)
        XCTAssertEqual(symbols.method(ofFrame: worker.frames.last!).qualifiedNameForTests, "java.lang.Thread.run")

        let allocation = try XCTUnwrap(events.first { $0.type == "jdk.ObjectAllocationSample" })
        XCTAssertEqual(allocation.attributes["objectClass"], "byte[] (classLoader = bootstrap)")
        XCTAssertEqual(allocation.bytes("weight"), 142_900)
        XCTAssertEqual(allocation.thread, "main")

        let gc = try XCTUnwrap(events.first { $0.type == "jdk.GarbageCollection" })
        XCTAssertEqual(gc.attributes["name"], "\"G1New\"")
        XCTAssertEqual(gc.nanoseconds("sumOfPauses"), 841_000)
    }

    func testTruncatedStackAndLambdaAndHiddenClassFrames() {
        let text = """
        jdk.ExecutionSample {
          startTime = 12:51:14.809 (2026-10-13)
          sampledThread = "pool-1-thread-3" (javaThreadId = 31)
          state = "STATE_RUNNABLE"
          stackTrace = [
            com.acme.Order$Line.total(int, String) line: 42
            com.acme.Cart$$Lambda/0x0000000800c03000.apply(Object) line: 0
            java.util.ArrayList.<init>() line: 78
            java.lang.Object.wait0(long) line: -1
            ...
          ]
        }

        """
        let (events, symbols) = parse(text)
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertTrue(event.isTruncated)
        XCTAssertEqual(event.thread, "pool-1-thread-3")
        XCTAssertEqual(event.frames.count, 4)
        let total = symbols.method(ofFrame: event.frames[0])
        XCTAssertEqual(total.className, "com.acme.Order$Line")
        XCTAssertEqual(total.name, "total")
        XCTAssertEqual(total.parameters, "int, String")
        let lambda = symbols.method(ofFrame: event.frames[1])
        XCTAssertEqual(lambda.className, "com.acme.Cart$$Lambda/0x0000000800c03000")
        XCTAssertEqual(lambda.name, "apply")
        XCTAssertEqual(symbols.method(ofFrame: event.frames[2]).name, "<init>")
        XCTAssertEqual(symbols.frame(event.frames[3]).line, 0, "a negative line has none")
    }

    func testNoSamplesAndUnwantedEvents() {
        XCTAssertEqual(parse("").events.count, 0)
        let text = """
        jdk.CPULoad {
          startTime = 12:51:14.809 (2026-10-13)
          jvmUser = 12.50%
          nested = {
            inner = 1
          }
        }

        jdk.ExecutionSample {
          sampledThread = "main" (javaThreadId = 1)
          stackTrace = [
            a.B.c() line: 1
          ]
        }
        """
        let (all, _) = parse(text)
        XCTAssertEqual(all.map(\.type), ["jdk.CPULoad", "jdk.ExecutionSample"])
        let (samplesOnly, _) = parse(text, wanted: ["jdk.ExecutionSample"])
        XCTAssertEqual(samplesOnly.map(\.type), ["jdk.ExecutionSample"])
        XCTAssertEqual(samplesOnly[0].frames.count, 1)
    }

    func testChunkBoundariesInsideALineGiveTheSameEvents() throws {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "spin-print.txt"), encoding: .utf8)
        let bytes = Array(text.utf8)
        var parser = JFRTextParser()
        var count = 0
        var index = 0
        // 7-byte chunks cut lines, and multi-byte characters never occur in the fixture.
        while index < bytes.count {
            let end = min(bytes.count, index + 7)
            parser.feed(Data(bytes[index..<end])) { _ in count += 1 }
            index = end
        }
        parser.finish { _ in count += 1 }
        XCTAssertEqual(count, 17)
    }

    func testValueParsing() {
        XCTAssertEqual(JFRTextParser.parseBytes("142.9 kB"), 142_900)
        XCTAssertEqual(JFRTextParser.parseBytes("1.5 MB"), 1_500_000)
        XCTAssertEqual(JFRTextParser.parseBytes("512 bytes"), 512)
        XCTAssertNil(JFRTextParser.parseBytes("lots"))
        XCTAssertEqual(JFRTextParser.parseNanoseconds("0.841 ms"), 841_000)
        XCTAssertEqual(JFRTextParser.parseNanoseconds("2.5 s"), 2_500_000_000)
        XCTAssertEqual(JFRTextParser.parseNanoseconds("12 us"), 12_000)
        XCTAssertNil(JFRTextParser.parseNanoseconds("12"))
    }

    func testSummaryParser() throws {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "spin-summary.txt"), encoding: .utf8)
        let summary = JFRSummary.parse(text)
        XCTAssertEqual(summary.version, "2.1")
        XCTAssertEqual(summary.chunks, 1)
        XCTAssertEqual(summary.executionSamples, 255)
        XCTAssertEqual(summary.allocationSamples, 252)
        XCTAssertEqual(summary.eventCounts["jdk.GarbageCollection"], 5)
    }
}

private extension JavaProfileSymbols.Method {
    var qualifiedNameForTests: String { className.isEmpty ? name : className + "." + name }
}

final class JavaProfileTreeTests: XCTestCase {
    private let symbols = JavaProfileSymbols()

    private func frame(_ className: String, _ name: String, line: Int32 = 1) -> Int32 {
        symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
    }

    func testSelfAndTotalCounts() {
        let main = frame("app.Main", "main"), a = frame("app.A", "a"), b = frame("app.B", "b")
        var tree = JavaProfileTree()
        tree.add(stack: [main, a])
        tree.add(stack: [main, a])
        tree.add(stack: [main, a, b])
        tree.add(stack: [main])
        XCTAssertEqual(tree.totalSamples, 4)
        let mainNode = tree.children(of: JavaProfileTree.root)[0]
        XCTAssertEqual(tree.totalCount(of: mainNode), 4)
        XCTAssertEqual(tree.selfCount(of: mainNode), 1)
        let aNode = tree.children(of: mainNode)[0]
        XCTAssertEqual(tree.totalCount(of: aNode), 3)
        XCTAssertEqual(tree.selfCount(of: aNode), 2)
        XCTAssertEqual(tree.path(to: aNode), [main, a])
    }

    func testHotMethodsMergeLinesAndCountRecursionOnce() {
        let main = frame("app.Main", "main")
        let fib5 = frame("app.Fib", "fib", line: 5)
        let fib6 = frame("app.Fib", "fib", line: 6)
        var tree = JavaProfileTree()
        // Recursion three deep, sampled at two different lines.
        tree.add(stack: [main, fib5, fib5, fib5], weight: 3)
        tree.add(stack: [main, fib5, fib6], weight: 2)
        tree.add(stack: [main], weight: 1)
        let hot = tree.hotMethods(symbols: symbols)
        let fib = symbols.method(ofFrame: fib5)
        let fibID = symbols.frame(fib5).method
        XCTAssertEqual(fib.name, "fib")
        XCTAssertEqual(hot.first, JavaProfileTree.HotMethod(method: fibID, selfCount: 5, totalCount: 5))
        let mainMethod = try! XCTUnwrap(hot.first { symbols.methods[Int($0.method)].name == "main" })
        XCTAssertEqual(mainMethod.selfCount, 1)
        XCTAssertEqual(mainMethod.totalCount, 6)
        XCTAssertEqual(tree.hotMethods(symbols: symbols, limit: 1).count, 1)
    }

    func testCallersAndCallees() {
        let main = frame("app.Main", "main"), a = frame("app.A", "a"), b = frame("app.B", "b"), c = frame("app.C", "c")
        var tree = JavaProfileTree()
        tree.add(stack: [main, a, c], weight: 4)
        tree.add(stack: [main, b, c], weight: 1)
        tree.add(stack: [main, c], weight: 2)
        let cID = symbols.frame(c).method
        let callers = tree.callers(of: cID, symbols: symbols)
        XCTAssertEqual(callers.map { symbols.methods[Int($0.method)].name }, ["a", "main", "b"])
        XCTAssertEqual(callers.map(\.count), [4, 2, 1])
        let callees = tree.callees(of: symbols.frame(main).method, symbols: symbols)
        XCTAssertEqual(callees.map { symbols.methods[Int($0.method)].name }, ["a", "c", "b"])
    }

    func testNodeCapFoldsTheRestIntoOther() {
        var tree = JavaProfileTree(nodeLimit: 6)
        let frames = (0..<20).map { frame("app.K", "m\($0)") }
        tree.add(stack: [frames[0], frames[1]])           // 2 nodes + root = 3
        tree.add(stack: [frames[0], frames[2]])           // 4
        tree.add(stack: [frames[3], frames[4]])           // 6: at the limit
        tree.add(stack: [frames[5], frames[6], frames[7]]) // would need 3 more: folded
        tree.add(stack: [frames[0], frames[1]])           // an existing path still counts
        XCTAssertTrue(tree.isTruncated)
        XCTAssertEqual(tree.foldedSamples, 1)
        XCTAssertEqual(tree.totalSamples, 5)
        let other = tree.children(of: JavaProfileTree.root).first { tree.isOther($0) }
        XCTAssertEqual(other.map { tree.selfCount(of: $0) }, 1)
        XCTAssertLessThanOrEqual(tree.nodeCount, 7)
    }

    func testFoldedStacks() {
        let main = frame("app.Main", "main"), a = frame("app.A", "a")
        var tree = JavaProfileTree()
        tree.add(stack: [main, a], weight: 3)
        tree.add(stack: [main], weight: 1)
        XCTAssertEqual(tree.foldedStacks(symbols: symbols), ["app.Main.main 1", "app.Main.main;app.A.a 3"])
    }

    func testProfileIngestKindsAndPerThreadTrees() {
        var profile = JavaProfile(symbols: symbols)
        let a = frame("app.A", "a"), main = frame("app.Main", "main")
        func sample(thread: String, truncated: Bool = false) -> JFRTextEvent {
            JFRTextEvent(type: "jdk.ExecutionSample", thread: thread, threadID: 1, frames: [a, main], isTruncated: truncated, attributes: [:])
        }
        profile.ingest(sample(thread: "main"))
        profile.ingest(sample(thread: "worker", truncated: true))
        profile.ingest(sample(thread: "main"))
        XCTAssertEqual(profile.cpuSamples, 3)
        XCTAssertEqual(profile.truncatedSamples, 1)
        XCTAssertEqual(profile.cpuTree(thread: "main").totalSamples, 2)
        XCTAssertEqual(profile.cpuTree(thread: "worker").totalSamples, 1)
        XCTAssertEqual(profile.cpuTree(thread: "nobody").totalSamples, 0)

        profile.ingest(JFRTextEvent(
            type: "jdk.ObjectAllocationSample", thread: "main", threadID: 1, frames: [main], isTruncated: false,
            attributes: ["weight": "2 kB", "objectClass": "byte[] (classLoader = bootstrap)"]
        ))
        XCTAssertEqual(profile.allocation.totalSamples, 2000)
        XCTAssertEqual(profile.allocation.foldedStacks(symbols: profile.symbols), ["app.Main.main;new byte[] 2000"])

        profile.ingest(JFRTextEvent(
            type: "jdk.GarbageCollection", thread: nil, threadID: nil, frames: [], isTruncated: false,
            attributes: ["name": "\"G1New\"", "cause": "\"G1 Evacuation Pause\"", "sumOfPauses": "0.5 ms", "gcId": "7"]
        ))
        XCTAssertEqual(profile.gcPauses, [JavaGCPause(gcID: 7, name: "G1New", cause: "G1 Evacuation Pause", nanoseconds: 500_000)])
        XCTAssertFalse(profile.isEmpty)
    }

    func testSyntheticRecordingParsesAndBuildsWithinBounds() {
        // 30 000 samples over 40 distinct stacks of depth 60: memory follows the stacks.
        var text = ""
        for index in 0..<30_000 {
            text += "jdk.ExecutionSample {\n  sampledThread = \"main\" (javaThreadId = 1)\n  stackTrace = [\n"
            let variant = index % 40
            text += "    app.Leaf\(variant).run() line: \(variant)\n"
            for depth in 0..<59 { text += "    app.Layer.call\(depth)(int) line: \(depth)\n" }
            text += "  ]\n}\n\n"
        }
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        parser.parse(text) { profile.ingest($0) }
        XCTAssertEqual(profile.cpuSamples, 30_000)
        XCTAssertEqual(profile.cpu.nodeCount, 1 + 59 + 40)
        XCTAssertEqual(profile.symbols.frames.count, 59 + 40)
    }
}

final class JavaFlightRecorderTests: XCTestCase {
    func testVMArgument() {
        XCTAssertEqual(
            JavaFlightRecorder.vmArgument(file: "/r/recording.jfr"),
            "-XX:StartFlightRecording=filename=/r/recording.jfr,settings=profile,dumponexit=true"
        )
        XCTAssertEqual(
            JavaFlightRecorder.vmArgument(file: "/r/%p.jfr", samplePeriodMilliseconds: 5, jdkFeatureVersion: 21),
            "-XX:StartFlightRecording=filename=/r/%p.jfr,settings=profile,dumponexit=true,jdk.ExecutionSample#period=5ms"
        )
        XCTAssertEqual(
            JavaFlightRecorder.vmArgument(file: "/r/a.jfr", samplePeriodMilliseconds: 5, jdkFeatureVersion: 11),
            "-XX:StartFlightRecording=filename=/r/a.jfr,settings=profile,dumponexit=true",
            "the period option needs Java 17"
        )
        XCTAssertNil(JavaFlightRecorder.vmArgument(file: "/r/a,b.jfr"))
    }

    func testUnsupportedReason() {
        XCTAssertNotNil(JavaFlightRecorder.unsupportedReason(featureVersion: 8))
        XCTAssertNil(JavaFlightRecorder.unsupportedReason(featureVersion: 11))
        XCTAssertNil(JavaFlightRecorder.unsupportedReason(featureVersion: nil))
    }

    func testPrintInvocationAlwaysPassesTheStackDepth() {
        let call = JavaFlightRecorder.printInvocation(
            jfr: URL(fileURLWithPath: "/jdk/bin/jfr"), recording: URL(fileURLWithPath: "/r/rec.jfr"),
            events: ["jdk.ExecutionSample", "jdk.ObjectAllocationSample"]
        )
        XCTAssertEqual(call.arguments, [
            "print", "--events", "jdk.ExecutionSample,jdk.ObjectAllocationSample", "--stack-depth", "128", "/r/rec.jfr"
        ])
    }

    func testDetectorByMagicAndExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renamed = directory.appendingPathComponent("heap.bin")
        try Data([0x46, 0x4C, 0x52, 0x00, 0x00, 0x02]).write(to: renamed)
        let textNamedJFR = directory.appendingPathComponent("notes.jfr")
        try "just words".write(to: textNamedJFR, atomically: true, encoding: .utf8)
        let missing = directory.appendingPathComponent("gone.jfr")

        XCTAssertTrue(JavaFlightRecordingDetector.isRecording(at: renamed), "a renamed recording is found by its magic")
        XCTAssertFalse(JavaFlightRecordingDetector.isRecording(at: textNamedJFR), "a text file named .jfr is not one")
        XCTAssertTrue(JavaFlightRecordingDetector.hasRecordingExtension(textNamedJFR))
        XCTAssertTrue(JavaFlightRecordingDetector.looksLikeRecording(renamed))
        XCTAssertFalse(JavaFlightRecordingDetector.isRecording(at: missing))
        XCTAssertTrue(JavaFlightRecordingDetector.hasMagic([0x46, 0x4C, 0x52, 0x00]))
        XCTAssertFalse(JavaFlightRecordingDetector.hasMagic([0x46, 0x4C]))
    }

    func testProfileGradleScriptArguments() {
        let arguments = JavaProfileGradleScript.arguments(
            scriptURL: URL(fileURLWithPath: "/r/profile.init.gradle"), recordingDirectory: URL(fileURLWithPath: "/r/jfr"),
            samplePeriodMilliseconds: 5, jdkFeatureVersion: 21
        )
        XCTAssertEqual(arguments, [
            "--init-script", "/r/profile.init.gradle", "-PumbraProfileDir=/r/jfr", "-PumbraProfileSettings=profile",
            "-PumbraProfilePeriodMs=5", "--no-configuration-cache", "--no-build-cache"
        ])
    }
}

final class JavaRunArtifactsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRun(_ artifacts: JavaRunArtifacts, kind: JavaRunArtifacts.Kind, age: TimeInterval, bytes: Int = 10) throws -> JavaRunArtifacts.Run {
        let date = Date(timeIntervalSinceNow: -age)
        let run = try artifacts.allocate(kind: kind, projectHash: "abc", now: date)
        try Data(count: bytes).write(to: run.directory.appendingPathComponent("data.bin"))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: run.directory.path)
        return run
    }

    func testAllocateListsNewestFirstAndKeepsProjectsApart() throws {
        let artifacts = JavaRunArtifacts(root: root)
        let older = try makeRun(artifacts, kind: .coverage, age: 3600)
        let newer = try makeRun(artifacts, kind: .coverage, age: 60)
        _ = try artifacts.allocate(kind: .coverage, projectHash: "other")
        XCTAssertEqual(artifacts.runs(kind: .coverage, projectHash: "abc").map(\.id), [newer.id, older.id])
        XCTAssertEqual(artifacts.runs(kind: .coverage, projectHash: "other").count, 1)
        XCTAssertEqual(artifacts.runs(kind: .profile, projectHash: "abc").count, 0)
        XCTAssertTrue(older.directory.path.contains("/Coverage/abc/"))
    }

    func testPruneKeepsTheNewestAndRespectsProtection() throws {
        let artifacts = JavaRunArtifacts(root: root)
        var runs: [JavaRunArtifacts.Run] = []
        for index in 0..<7 { runs.append(try makeRun(artifacts, kind: .coverage, age: Double(7 - index) * 100)) }
        // runs[6] is the newest; the oldest two go with keep = 5, unless protected.
        let removed = artifacts.prune(kind: .coverage, projectHash: "abc", keep: 5, protecting: [runs[0].id])
        XCTAssertEqual(removed.map(\.id), [runs[1].id])
        let left = artifacts.runs(kind: .coverage, projectHash: "abc").map(\.id)
        XCTAssertEqual(left.count, 6)
        XCTAssertTrue(left.contains(runs[0].id))
        XCTAssertFalse(left.contains(runs[1].id))
    }

    func testPruneBySizeDropsOldestFirstAndKeepsOne() throws {
        let artifacts = JavaRunArtifacts(root: root)
        let oldest = try makeRun(artifacts, kind: .profile, age: 300, bytes: 200_000)
        _ = try makeRun(artifacts, kind: .profile, age: 200, bytes: 200_000)
        let newest = try makeRun(artifacts, kind: .profile, age: 100, bytes: 200_000)
        let removed = artifacts.prune(kind: .profile, projectHash: "abc", maximumBytes: 250_000)
        XCTAssertTrue(removed.contains { $0.id == oldest.id })
        let left = artifacts.runs(kind: .profile, projectHash: "abc")
        XCTAssertTrue(left.contains { $0.id == newest.id })
        XCTAssertGreaterThanOrEqual(left.count, 1)
    }

    func testProjectHashIsStableAndShort() {
        let url = URL(fileURLWithPath: "/Users/me/project")
        XCTAssertEqual(JavaRunArtifacts.projectHash(for: url), JavaRunArtifacts.projectHash(for: URL(fileURLWithPath: "/Users/me/project/")))
        XCTAssertEqual(JavaRunArtifacts.projectHash(for: url).count, 16)
        XCTAssertNotEqual(JavaRunArtifacts.projectHash(for: url), JavaRunArtifacts.projectHash(for: URL(fileURLWithPath: "/Users/me/other")))
    }
}

final class JavaRunInstrumentationTests: XCTestCase {
    func testOldFilesDecodeWithNoInstrumentation() throws {
        let json = #"{"target":{"singleFile":{"path":"/p/Main.java"}},"programArguments":"","vmArguments":""}"#
        let configuration = try JSONDecoder().decode(JavaRunConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.instrumentation, .none)
    }

    func testRoundTripAndUnknownValueFromANewerBuild() throws {
        var configuration = JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/p/Main.java"))
        configuration.instrumentation = .profile
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(JavaRunConfiguration.self, from: data).instrumentation, .profile)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["instrumentation"] = "memoryLeakHunt"
        let newer = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(JavaRunConfiguration.self, from: newer)
        XCTAssertEqual(decoded.instrumentation, .none)
        XCTAssertEqual(decoded.target, configuration.target)
    }

    func testDebugDoesNotCombineWithInstrumentation() {
        var configuration = JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/p/Main.java"))
        XCTAssertTrue(configuration.supportsInstrumentation)
        configuration.launchMode = .debug
        XCTAssertFalse(configuration.supportsInstrumentation)
        configuration.instrumentation = .coverage
        let problems = JavaRunConfigurationValidator.problems(
            for: configuration, context: .init(fileExists: { _ in true }, directoryExists: { _ in true })
        )
        XCTAssertTrue(problems.contains { $0.field == .instrumentation && $0.message.contains("debugger") })
    }

    func testSingleFileCoverageIsRefusedAndProfilingIsNot() {
        var configuration = JavaRunConfiguration(target: .singleFile(path: "/p/Main.java"))
        configuration.instrumentation = .coverage
        let context = JavaRunConfigurationValidator.Context(fileExists: { _ in true }, directoryExists: { _ in true })
        XCTAssertEqual(
            JavaRunConfigurationValidator.problems(for: configuration, context: context).first { $0.field == .instrumentation }?.message,
            "Run with Coverage needs a compiled class."
        )
        configuration.instrumentation = .profile
        XCTAssertNil(JavaRunConfigurationValidator.problems(for: configuration, context: context).first { $0.field == .instrumentation })
    }

    func testProfilingNeedsJava11() {
        var configuration = JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/p/Main.java"))
        configuration.instrumentation = .profile
        let old = JavaRunConfigurationValidator.Context(jdkFeatureVersion: 8, fileExists: { _ in true }, directoryExists: { _ in true })
        XCTAssertTrue(JavaRunConfigurationValidator.problems(for: configuration, context: old).contains { $0.message.contains("Java 11") })
        let current = JavaRunConfigurationValidator.Context(jdkFeatureVersion: 21, fileExists: { _ in true }, directoryExists: { _ in true })
        XCTAssertTrue(JavaRunConfigurationValidator.problems(for: configuration, context: current).isEmpty)
    }

    func testProcessLaunchPutsExtraVMArgumentsBeforeTheUsers() throws {
        var configuration = JavaRunConfiguration(
            target: .classpathMain(className: "app.Main", sourceFile: "/p/src/Main.java"), vmArguments: "-Xmx64m"
        )
        configuration.instrumentation = .coverage
        let launch = try XCTUnwrap(JavaLaunchCommand.makeProcessLaunch(
            configuration: configuration,
            javaHome: URL(fileURLWithPath: "/jdk"),
            runtimeClasspath: [URL(fileURLWithPath: "/p/build/classes")],
            projectRoot: URL(fileURLWithPath: "/p"),
            jdkFeatureVersion: 21,
            extraVMArguments: ["-javaagent:/res/jacocoagent.jar=destfile=/r/a.exec,append=true,output=file"],
            baseEnvironment: [:]
        ))
        XCTAssertEqual(launch.arguments, [
            "-javaagent:/res/jacocoagent.jar=destfile=/r/a.exec,append=true,output=file",
            "-Xmx64m", "-cp", "/p/build/classes", "app.Main"
        ])
    }
}
