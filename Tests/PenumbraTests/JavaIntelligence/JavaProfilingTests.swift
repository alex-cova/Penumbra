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
            "-XX:StartFlightRecording=name=umbra,filename=/r/recording.jfr,settings=profile,dumponexit=true"
        )
        XCTAssertEqual(
            JavaFlightRecorder.vmArgument(file: "/r/%p.jfr", samplePeriodMilliseconds: 5, jdkFeatureVersion: 21),
            "-XX:StartFlightRecording=name=umbra,filename=/r/%p.jfr,settings=profile,dumponexit=true,jdk.ExecutionSample#period=5ms"
        )
        XCTAssertEqual(
            JavaFlightRecorder.vmArgument(file: "/r/a.jfr", samplePeriodMilliseconds: 5, jdkFeatureVersion: 11),
            "-XX:StartFlightRecording=name=umbra,filename=/r/a.jfr,settings=profile,dumponexit=true",
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
            "-PumbraProfileStackDepth=128", "-PumbraProfileOptions=jdk.ExecutionSample#period=5ms",
            "--no-configuration-cache", "--no-build-cache"
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

final class JavaProfileTimeAndQueryTests: XCTestCase {
    private let symbols = JavaProfileSymbols()

    private func frame(_ className: String, _ name: String) -> Int32 {
        symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: 1)
    }

    func testTimestampsAcrossFormatsAndMidnight() throws {
        let a = try XCTUnwrap(JFRTextParser.parseTimestamp("23:59:46.198 (2026-10-13)"))
        let b = try XCTUnwrap(JFRTextParser.parseTimestamp("00:00:04.491 (2026-10-14)"))
        XCTAssertEqual(b - a, 18_293, "the date rolls over midnight")
        XCTAssertEqual(JFRTextParser.parseTimestamp("2026-10-13T23:59:46.198+02:00"), a)
        XCTAssertEqual(JFRTextParser.parseTimestamp("2026-10-13T23:59:46.198765Z"), a, "extra digits are cut to milliseconds")
        let noMillis = try XCTUnwrap(JFRTextParser.parseTimestamp("23:59:46 (2026-10-13)"))
        XCTAssertEqual(a - noMillis, 198)
        let noDate = try XCTUnwrap(JFRTextParser.parseTimestamp("00:00:01.500"))
        XCTAssertEqual(noDate, 1_500)
        XCTAssertNil(JFRTextParser.parseTimestamp("soon"))
        XCTAssertNil(JFRTextParser.parseTimestamp("25:00:00.000 (2026-10-13)"))
        XCTAssertEqual(JFRTextParser.parseFraction("0.12%"), 0.0012)
        XCTAssertEqual(JFRTextParser.parseFraction("0.5"), 0.5)
    }

    func testRealMixedRecordingKeepsTimesWaitsAndSeries() throws {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "mixed-print.txt"), encoding: .utf8)
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        parser.parse(text) { profile.ingest($0) }

        XCTAssertEqual(profile.cpuSamples, 31)
        XCTAssertEqual(profile.cpuSamplesTable.count, 31)
        let span = try XCTUnwrap(profile.timeSpan)
        XCTAssertGreaterThan(span.upperBound - span.lowerBound, 1_000, "the recording covers seconds")

        // Sleeps, a monitor wait and a socket read are one "waits" tree, with a leaf saying what for.
        let folded = profile.contention.foldedStacks(symbols: profile.symbols).joined(separator: "\n")
        XCTAssertTrue(folded.contains("sleeping"), folded)
        XCTAssertTrue(folded.contains("waiting for java.lang.Object"), folded)
        XCTAssertTrue(folded.contains("socket read localhost"), folded)
        XCTAssertFalse(folded.contains("socket read localhost:"), "the port is left out so connections group")
        XCTAssertGreaterThan(profile.contention.totalSamples, 1_000_000, "µs: 300 ms socket + 400 ms sleep + …")

        XCTAssertEqual(profile.gcPauses.count, 2)
        XCTAssertNotNil(profile.gcPauses.first?.startMilliseconds)
        XCTAssertEqual(profile.cpuLoad.count, 1)
        XCTAssertEqual(profile.cpuLoad[0].machineTotal, 0.062, accuracy: 0.0001)
        XCTAssertEqual(profile.heap.count, 4)
        XCTAssertEqual(profile.heap.filter(\.afterCollection).count, 2)
        XCTAssertEqual(profile.heap.first?.usedBytes, 41_000_000)

        let threads = profile.threads(of: .contention).map(\.name)
        XCTAssertTrue(threads.contains("lock-holder"))
        XCTAssertTrue(threads.contains("lock-waiter"))
        XCTAssertEqual(profile.tree(of: .contention, thread: "lock-waiter", range: nil).foldedStacks(symbols: profile.symbols).count, 1)
    }

    func testReweightedTreeMatchesATreeBuiltFromTheSameSamples() {
        let main = frame("app.Main", "main"), a = frame("app.A", "a"), b = frame("app.B", "b")
        var profile = JavaProfile(symbols: symbols)
        func sample(_ stack: [Int32], thread: String, at time: Int64) {
            profile.ingest(JFRTextEvent(
                type: "jdk.ExecutionSample", thread: thread, frames: stack.reversed(), timeMillis: time
            ))
        }
        sample([main, a], thread: "t1", at: 1_000)
        sample([main, a], thread: "t2", at: 1_100)
        sample([main, a, b], thread: "t1", at: 1_200)
        sample([main], thread: "t2", at: 1_300)

        let all = profile.tree(of: .cpu, thread: nil, range: nil)
        XCTAssertEqual(all.totalSamples, 4)

        // A thread and a range, each and together.
        XCTAssertEqual(profile.tree(of: .cpu, thread: "t1", range: nil).totalSamples, 2)
        XCTAssertEqual(profile.tree(of: .cpu, thread: nil, range: 0...150).totalSamples, 2)
        let both = profile.tree(of: .cpu, thread: "t1", range: 100...400)
        XCTAssertEqual(both.totalSamples, 1)
        XCTAssertEqual(both.foldedStacks(symbols: symbols), ["app.Main.main;app.A.a;app.B.b 1"])

        // A filtered tree lists no empty branches and its methods skip the ones with no samples.
        let mainNode = both.children(of: JavaProfileTree.root)
        XCTAssertEqual(mainNode.count, 1)
        let hot = both.hotMethods(symbols: symbols)
        XCTAssertEqual(hot.count, 3)
        XCTAssertTrue(hot.allSatisfy { $0.totalCount == 1 })
        XCTAssertEqual(profile.tree(of: .cpu, thread: "nobody", range: nil).totalSamples, 0)
        XCTAssertEqual(profile.tree(of: .cpu, thread: "t2", range: 5_000...6_000).children(of: JavaProfileTree.root), [])
    }

    func testEstimatedSamplePeriodComesFromTheBusiestThreadsGaps() {
        var profile = JavaProfile(symbols: symbols)
        let main = frame("app.Main", "main")
        for index in 0..<40 {
            // 20 ms apart, one sample jittered.
            let time = Int64(index * 20 + (index == 7 ? 3 : 0))
            profile.ingest(JFRTextEvent(type: "jdk.ExecutionSample", thread: "main", frames: [main], timeMillis: 5_000 + time))
        }
        XCTAssertEqual(profile.estimatedCPUSamplePeriodMilliseconds(), 20)
        XCTAssertNil(JavaProfile(symbols: symbols).estimatedCPUSamplePeriodMilliseconds())
    }

    func testStackDepthArgumentIsClamped() {
        XCTAssertEqual(JavaFlightRecorder.stackDepthArgument(), "-XX:FlightRecorderOptions=stackdepth=128")
        XCTAssertEqual(JavaFlightRecorder.stackDepthArgument(100_000), "-XX:FlightRecorderOptions=stackdepth=2048")
        XCTAssertEqual(JavaFlightRecorder.stackDepthArgument(0), "-XX:FlightRecorderOptions=stackdepth=1")
    }
}

final class JavaProfileTransformTests: XCTestCase {
    private let symbols = JavaProfileSymbols()

    private func frame(_ className: String, _ name: String, line: Int32 = 1) -> Int32 {
        symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
    }

    private func method(_ frame: Int32) -> Int32 { symbols.frame(frame).method }

    /// main → a → c (4), main → b → c (1), main → c (2), main (1)
    private func sample() -> (tree: JavaProfileTree, main: Int32, a: Int32, b: Int32, c: Int32) {
        let main = frame("app.Main", "main"), a = frame("app.A", "a"), b = frame("app.B", "b"), c = frame("app.C", "c")
        var tree = JavaProfileTree()
        tree.add(stack: [main, a, c], weight: 4)
        tree.add(stack: [main, b, c], weight: 1)
        tree.add(stack: [main, c], weight: 2)
        tree.add(stack: [main], weight: 1)
        return (tree, main, a, b, c)
    }

    private func node(_ tree: JavaProfileTree, _ path: [Int32]) -> Int {
        var current = JavaProfileTree.root
        for frame in path {
            guard let next = tree.children(of: current).first(where: { tree.frame(of: $0) == frame }) else { return -1 }
            current = next
        }
        return current
    }

    func testFocusOnSubtreeKeepsOnlyThatCall() {
        let (tree, main, a, _, c) = sample()
        let focused = tree.focusingOnSubtree(of: node(tree, [main, a]))
        XCTAssertEqual(focused.totalSamples, 4)
        XCTAssertEqual(focused.foldedStacks(symbols: symbols), ["app.A.a;app.C.c 4"])
        XCTAssertEqual(focused.children(of: JavaProfileTree.root).count, 1)
        _ = c
    }

    func testFocusOnCallShowsTheMethodAndItsCallers() {
        let (tree, _, _, _, c) = sample()
        let focused = tree.focusingOnCall(of: method(c), symbols: symbols)
        XCTAssertEqual(focused.totalSamples, 7)
        XCTAssertEqual(
            focused.foldedStacks(symbols: symbols),
            ["app.Main.main;app.A.a;app.C.c 4", "app.Main.main;app.B.b;app.C.c 1", "app.Main.main;app.C.c 2"]
        )
    }

    func testExcludeSubtreeAndExcludeCalls() {
        let (tree, main, a, _, c) = sample()
        let withoutA = tree.excludingSubtree(of: node(tree, [main, a]))
        XCTAssertEqual(withoutA.totalSamples, 4)
        XCTAssertFalse(withoutA.foldedStacks(symbols: symbols).contains { $0.contains("app.A.a") })

        let withoutC = tree.excludingCalls(of: method(c), symbols: symbols)
        XCTAssertEqual(withoutC.totalSamples, 1)
        XCTAssertEqual(withoutC.foldedStacks(symbols: symbols), ["app.Main.main 1"])
        XCTAssertEqual(tree.totalSamples, 8, "the input is untouched")
    }

    func testCollapsingRecursionMergesBackIntoTheFirstCall() {
        let main = frame("app.Main", "main"), fib5 = frame("app.Fib", "fib", line: 5), fib6 = frame("app.Fib", "fib", line: 6)
        let leaf = frame("app.Leaf", "leaf")
        var tree = JavaProfileTree()
        tree.add(stack: [main, fib5, fib5, fib6, leaf], weight: 3)
        tree.add(stack: [main, fib5], weight: 1)
        let collapsed = tree.collapsingRecursion(symbols: symbols)
        XCTAssertEqual(collapsed.totalSamples, 4)
        XCTAssertEqual(
            collapsed.foldedStacks(symbols: symbols), ["app.Main.main;app.Fib.fib 1", "app.Main.main;app.Fib.fib;app.Leaf.leaf 3"]
        )
    }

    func testHidingFramesAttachesCalleesToTheCaller() {
        let (tree, _, _, _, _) = sample()
        let hidden = tree.hidingFrames(symbols: symbols) { $0.className == "app.A" || $0.className == "app.B" }
        XCTAssertEqual(hidden.totalSamples, 8)
        XCTAssertEqual(hidden.foldedStacks(symbols: symbols), ["app.Main.main 1", "app.Main.main;app.C.c 7"])
    }

    func testBackTraceAndMergedCallees() {
        let (tree, main, a, b, c) = sample()
        let back = tree.backTrace(of: method(c), symbols: symbols)
        XCTAssertEqual(back.totalSamples, 7)
        let top = back.children(of: JavaProfileTree.root)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(back.totalCount(of: top[0]), 7)
        let callers = back.children(of: top[0]).map { symbols.method(ofFrame: back.frame(of: $0)).name }
        XCTAssertEqual(callers, ["a", "main", "b"])

        // Callees of main, merged: c is called from main directly and below a and b.
        let merged = tree.mergedCallees(of: method(main), symbols: symbols)
        XCTAssertEqual(merged.totalSamples, 8)
        XCTAssertEqual(
            merged.foldedStacks(symbols: symbols),
            ["app.Main.main 1", "app.Main.main;app.A.a;app.C.c 4", "app.Main.main;app.B.b;app.C.c 1", "app.Main.main;app.C.c 2"]
        )
        _ = (a, b)
    }

    func testTransformsComposeOnAFilteredTree() {
        let (tree, main, a, _, c) = sample()
        // A reweighted tree (one thread's view) still transforms: empty branches are not visited.
        var selfs = [Int](repeating: 0, count: tree.nodeCount)
        selfs[node(tree, [main, a, c])] = 5
        selfs[node(tree, [main])] = 1
        let filtered = tree.reweighted(selfCounts: selfs)
        XCTAssertEqual(filtered.foldedStacks(symbols: symbols), ["app.Main.main 1", "app.Main.main;app.A.a;app.C.c 5"])
        let back = filtered.backTrace(of: method(c), symbols: symbols)
        XCTAssertEqual(back.totalSamples, 5)
        let focus = filtered.focusingOnCall(of: method(a), symbols: symbols)
        XCTAssertEqual(focus.foldedStacks(symbols: symbols), ["app.Main.main;app.A.a 5"])
    }
}

final class JavaProfileTimelineTests: XCTestCase {
    private func mixedProfile() throws -> JavaProfile {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "mixed-print.txt"), encoding: .utf8)
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        parser.parse(text) { profile.ingest($0) }
        return profile
    }

    func testLanesSeriesAndBandsOfARealRecording() throws {
        let profile = try mixedProfile()
        let timeline = try XCTUnwrap(JavaProfileTimeline.build(from: profile, buckets: 100))
        XCTAssertEqual(timeline.bucketCount, 100)
        XCTAssertGreaterThan(timeline.span.upperBound - timeline.span.lowerBound, 1_500)

        let names = timeline.lanes.map(\.name)
        XCTAssertTrue(names.contains("main"))
        XCTAssertTrue(names.contains("lock-holder"))
        let holder = try XCTUnwrap(timeline.lanes.first { $0.name == "lock-holder" })
        // It slept 400 ms of a ~2 s recording: waiting in a fifth of the buckets, never running.
        let waitingBuckets = holder.waiting.filter { $0 > 0.5 }.count
        XCTAssertGreaterThan(waitingBuckets, 10)
        XCTAssertLessThan(waitingBuckets, 40)
        XCTAssertEqual(holder.maxRunning, 0)
        XCTAssertGreaterThan(holder.waiting.filter { $0 > 0.99 }.count, 5, "a wait fills the buckets it spans")

        let main = try XCTUnwrap(timeline.lanes.first { $0.name == "main" })
        XCTAssertGreaterThan(main.running.reduce(0, +), 5)
        XCTAssertLessThanOrEqual(main.maxRunning, 1)
        XCTAssertEqual(timeline.gcBands.count, 2)
        XCTAssertEqual(timeline.heap.count, 4)
        XCTAssertEqual(timeline.cpuLoad.count, 1)
        // Busiest lane first.
        XCTAssertEqual(timeline.lanes.map(\.activity), timeline.lanes.map(\.activity).sorted(by: >))
    }

    func testLaneCapKeepsTheBusiestAndCountsTheRest() throws {
        let timeline = try XCTUnwrap(JavaProfileTimeline.build(from: mixedProfile(), buckets: 50, maximumLanes: 2))
        XCTAssertEqual(timeline.lanes.count, 2)
        XCTAssertGreaterThan(timeline.omittedLanes, 0)
    }

    func testBucketMappingRoundTrips() throws {
        let timeline = try XCTUnwrap(JavaProfileTimeline.build(from: mixedProfile(), buckets: 100))
        XCTAssertEqual(timeline.bucket(at: timeline.span.lowerBound), 0)
        XCTAssertEqual(timeline.bucket(at: timeline.span.upperBound), 99)
        XCTAssertEqual(timeline.bucket(at: timeline.time(ofBucket: 40)), 40)
        XCTAssertEqual(timeline.bucket(at: timeline.span.upperBound + 10_000), 99)
    }

    func testNoTimestampsMeansNoTimeline() {
        var profile = JavaProfile()
        profile.ingest(JFRTextEvent(type: "jdk.ExecutionSample", thread: "main", frames: []))
        XCTAssertNil(JavaProfileTimeline.build(from: profile))
    }

    func testNearestSampleFindsAWaitWhileItLasts() throws {
        let profile = try mixedProfile()
        let timeline = try XCTUnwrap(JavaProfileTimeline.build(from: profile, buckets: 100))
        let holder = try XCTUnwrap(timeline.lanes.first { $0.name == "lock-holder" })
        let bucket = try XCTUnwrap(holder.waiting.indices.first { holder.waiting[$0] > 0.9 })
        let hit = try XCTUnwrap(profile.nearestSample(
            thread: "lock-holder", time: timeline.time(ofBucket: bucket) + 5, tolerance: 20
        ))
        XCTAssertEqual(hit.kind, .contention)
        let stack = profile.contention.foldedStacks(symbols: profile.symbols)
        XCTAssertTrue(stack.contains { $0.contains("sleeping") })
        XCTAssertNil(profile.nearestSample(thread: "no-such-thread", time: 0, tolerance: 1_000_000))
    }
}

final class JavaProfileComparisonTests: XCTestCase {
    /// Each profile has a symbol table of its own, as two recordings do; the frames differ in line.
    private func build(_ stacks: [([(String, String, Int32)], Int)]) -> (JavaProfileTree, JavaProfileSymbols) {
        let symbols = JavaProfileSymbols()
        var tree = JavaProfileTree()
        // Interning in a different order than the other profile makes the ids disagree.
        for (frames, weight) in stacks {
            let ids = frames.map { spec in
                symbols.internFrame(
                    method: symbols.internMethod(className: spec.0, name: spec.1, parameters: ""), line: spec.2
                )
            }
            tree.add(stack: ids, weight: weight)
        }
        return (tree, symbols)
    }

    private func node(_ comparison: JavaProfileComparison, _ names: [String]) -> Int? {
        var current = JavaProfileTree.root
        for name in names {
            guard let next = comparison.tree.children(of: current).first(where: {
                comparison.symbols.method(ofFrame: comparison.tree.frame(of: $0)).name == name
            }) else { return nil }
            current = next
        }
        return current
    }

    func testIdenticalProfilesShowNoChange() {
        let stacks: [([(String, String, Int32)], Int)] = [
            ([("app.M", "main", 1), ("app.A", "a", 5)], 6), ([("app.M", "main", 1)], 2)
        ]
        let (b, bs) = build(stacks)
        let (t, ts) = build(stacks.reversed())
        let comparison = JavaProfileComparison.compare(baseline: b, baselineSymbols: bs, target: t, targetSymbols: ts)
        for index in 1..<comparison.tree.nodeCount { XCTAssertEqual(comparison.change(ofNode: index), 0, accuracy: 1e-9) }
        XCTAssertEqual(comparison.rows.map(\.method.name).sorted(), ["a", "main"])
        XCTAssertTrue(comparison.rows.allSatisfy { $0.baselineSelf == $0.targetSelf })
    }

    func testAddedAndRemovedFramesAndMovedLines() throws {
        // Baseline: main→a→c ×4, main→b ×2. Target (a longer run, so shares matter): main→a→c ×2 (line moved),
        // main→b ×2, main→d ×4 is new.
        let (b, bs) = build([
            ([("app.M", "main", 1), ("app.A", "a", 5), ("app.C", "c", 9)], 4), ([("app.M", "main", 1), ("app.B", "b", 3)], 2)
        ])
        let (t, ts) = build([
            ([("app.M", "main", 2), ("app.A", "a", 7), ("app.C", "c", 12)], 4), ([("app.M", "main", 2), ("app.B", "b", 4)], 4),
            ([("app.M", "main", 2), ("app.D", "d", 1)], 12)
        ])
        let comparison = JavaProfileComparison.compare(baseline: b, baselineSymbols: bs, target: t, targetSymbols: ts)
        XCTAssertEqual(comparison.baselineSamples, 6)
        XCTAssertEqual(comparison.targetSamples, 20)

        let d = try XCTUnwrap(node(comparison, ["main", "d"]))
        XCTAssertEqual(comparison.change(ofNode: d), 1, accuracy: 1e-9, "only in the target")
        XCTAssertEqual(comparison.baselineCounts[d], 0)
        XCTAssertEqual(comparison.targetCounts[d], 12)

        // c: 4/6 of the baseline, 4/20 of the target: shrank by (0.2-0.667)/0.667 = -0.7
        let c = try XCTUnwrap(node(comparison, ["main", "a", "c"]))
        XCTAssertEqual(comparison.change(ofNode: c), (0.2 - 4.0 / 6) / (4.0 / 6), accuracy: 1e-9)
        XCTAssertEqual(comparison.targetCounts[c], 4)

        // Matched across different lines: one `main`, not two.
        XCTAssertEqual(comparison.tree.children(of: JavaProfileTree.root).count, 1)
        let main = try XCTUnwrap(node(comparison, ["main"]))
        XCTAssertEqual(comparison.baselineCounts[main], 6)
        XCTAssertEqual(comparison.targetCounts[main], 20)
        XCTAssertEqual(comparison.change(ofNode: main), 0, accuracy: 1e-9, "everything is under main in both")

        // The widest side wins, and children fit under their parent.
        for index in 1..<comparison.tree.nodeCount {
            let children = comparison.tree.children(of: index).reduce(0) { $0 + comparison.tree.totalCount(of: $1) }
            XCTAssertLessThanOrEqual(children, comparison.tree.totalCount(of: index))
        }

        // The table: d is new, c fell; biggest change in self share first.
        XCTAssertEqual(comparison.rows.first?.method.name, "d")
        let rowD = try XCTUnwrap(comparison.rows.first { $0.method.name == "d" })
        XCTAssertEqual(rowD.baselineSelf, 0)
        XCTAssertEqual(rowD.targetSelf, 12)
    }

    func testAbsoluteBasisKeepsRawCounts() throws {
        let (b, bs) = build([([("app.M", "main", 1)], 3)])
        let (t, ts) = build([([("app.M", "main", 1)], 9)])
        let comparison = JavaProfileComparison.compare(
            baseline: b, baselineSymbols: bs, target: t, targetSymbols: ts, basis: .absolute
        )
        XCTAssertEqual(comparison.tree.totalSamples, 9)
        XCTAssertEqual(comparison.change(ofNode: try XCTUnwrap(node(comparison, ["main"]))), 0, accuracy: 1e-9,
                       "the same share, since change is by share")
    }

    func testEmptySideIsAllNewOrAllGone() throws {
        let (t, ts) = build([([("app.M", "main", 1)], 5)])
        let empty = JavaProfileTree()
        let comparison = JavaProfileComparison.compare(
            baseline: empty, baselineSymbols: JavaProfileSymbols(), target: t, targetSymbols: ts
        )
        XCTAssertEqual(comparison.baselineSamples, 0)
        let main = try XCTUnwrap(node(comparison, ["main"]))
        XCTAssertEqual(comparison.change(ofNode: main), 1, accuracy: 1e-9)
    }
}

final class JavaFlightRecorderOptionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testOptionsBecomeVMArgumentsAndGateEventSettingsByJava17() throws {
        let options = JavaFlightRecorderOptions(
            template: .standard, samplePeriodMilliseconds: 5, stackDepth: 256,
            allocationSamplesPerSecond: 500, waitThresholdMilliseconds: 2
        )
        let java21 = try XCTUnwrap(JavaFlightRecorder.vmArguments(file: "/r/a.jfr", options: options, jdkFeatureVersion: 21))
        XCTAssertEqual(java21.count, 2)
        XCTAssertTrue(java21[0].hasPrefix("-XX:StartFlightRecording=name=umbra,filename=/r/a.jfr,settings=default,dumponexit=true"))
        XCTAssertTrue(java21[0].contains("jdk.ExecutionSample#period=5ms"))
        XCTAssertTrue(java21[0].contains("jdk.ObjectAllocationSample#throttle=500/s"))
        XCTAssertTrue(java21[0].contains("jdk.ThreadSleep#threshold=2ms"))
        XCTAssertTrue(java21[0].contains("jdk.SocketRead#threshold=2ms"))
        XCTAssertEqual(java21[1], "-XX:FlightRecorderOptions=stackdepth=256")

        let java11 = try XCTUnwrap(JavaFlightRecorder.vmArguments(file: "/r/a.jfr", options: options, jdkFeatureVersion: 11))
        XCTAssertFalse(java11[0].contains("#"), "event settings are not taken on the command line before Java 17")
        XCTAssertEqual(java11[1], "-XX:FlightRecorderOptions=stackdepth=256")
    }

    func testCustomSettingsFileAndUnsafePaths() throws {
        let options = JavaFlightRecorderOptions(template: .custom(path: "/p/My Profile.jfc"))
        let args = try XCTUnwrap(JavaFlightRecorder.vmArguments(file: "/r/a.jfr", options: options, jdkFeatureVersion: 17))
        XCTAssertTrue(args[0].contains("settings=/p/My Profile.jfc"))
        XCTAssertNil(JavaFlightRecorder.vmArguments(
            file: "/r/a.jfr", options: JavaFlightRecorderOptions(template: .custom(path: "/p/a,b.jfc")), jdkFeatureVersion: 17
        ))
        XCTAssertNil(JavaFlightRecorder.vmArguments(file: "/r/a,b.jfr", options: .init(), jdkFeatureVersion: 17))
        XCTAssertEqual(JavaFlightRecorderOptions.Template(settingsValue: "default"), .standard)
        XCTAssertEqual(JavaFlightRecorderOptions.Template(settingsValue: "/x.jfc"), .custom(path: "/x.jfc"))
    }

    func testOptionsRoundTripThroughJSONAndSummarise() throws {
        let options = JavaFlightRecorderOptions(template: .custom(path: "/p/mine.jfc"), samplePeriodMilliseconds: 4, stackDepth: 64)
        let decoded = try JSONDecoder().decode(JavaFlightRecorderOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(options.summary, "mine.jfc · 4 ms · depth 64")
        XCTAssertEqual(JavaFlightRecorderOptions().summary, "profile · depth 128")
    }

    func testGradleArgumentsCarryOptionsAndTheScriptNamesTheRecording() {
        let args = JavaProfileGradleScript.arguments(
            scriptURL: URL(fileURLWithPath: "/r/p.gradle"), recordingDirectory: URL(fileURLWithPath: "/r/jfr"),
            options: JavaFlightRecorderOptions(template: .standard, stackDepth: 200, waitThresholdMilliseconds: 5),
            jdkFeatureVersion: 21
        )
        XCTAssertTrue(args.contains("-PumbraProfileSettings=default"))
        XCTAssertTrue(args.contains("-PumbraProfileStackDepth=200"))
        let options = args.first { $0.hasPrefix("-PumbraProfileOptions=") }
        XCTAssertNotNil(options)
        XCTAssertTrue(options?.contains("jdk.JavaMonitorEnter#threshold=5ms") == true)
        XCTAssertTrue(JavaProfileGradleScript.source.contains("name=umbra"))
    }

    func testRunInfoRoundTripAndRecentListing() throws {
        let artifacts = JavaRunArtifacts(root: root)
        let older = try artifacts.allocate(kind: .profile, projectHash: "abc", now: Date(timeIntervalSinceNow: -7_200))
        let newer = try artifacts.allocate(kind: .profile, projectHash: "abc", now: Date(timeIntervalSinceNow: -60))
        let empty = try artifacts.allocate(kind: .profile, projectHash: "abc", now: Date(timeIntervalSinceNow: -10))
        for (run, age) in [(older, 7_200.0), (newer, 60.0)] {
            try Data([0x46, 0x4C, 0x52, 0x00]).write(to: run.directory.appendingPathComponent("recording.jfr"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: run.directory.path
            )
        }
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try JavaProfileRunInfo(
            label: "Spin", startedAt: started, jdkFeatureVersion: 21, settings: "profile · depth 128", tasks: [":run"],
            finishedAt: started.addingTimeInterval(12.5), recordingCount: 1, recordingBytes: 4
        ).write(to: newer.directory)
        // Writing the record touched the folder; the listing sorts by that date.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: newer.directory.path
        )

        let info = try XCTUnwrap(JavaProfileRunInfo.read(from: newer.directory))
        XCTAssertEqual(info.label, "Spin")
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertNil(JavaProfileRunInfo.read(from: older.directory))
        try Data("not json".utf8).write(to: older.directory.appendingPathComponent("run.json"))
        XCTAssertNil(JavaProfileRunInfo.read(from: older.directory), "a damaged record is no record")

        // Writing the damaged record touched the older folder; the listing sorts by that date.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: older.directory.path
        )
        let recent = JavaRecentProfile.list(artifacts: artifacts, projectHash: "abc")
        XCTAssertEqual(recent.map(\.run.id), [newer.id, older.id], "newest first, a run with no recording left out")
        XCTAssertFalse(recent.contains { $0.run.id == empty.id })
        XCTAssertEqual(recent[0].title, "Spin")
        XCTAssertEqual(JavaRecentProfile.list(artifacts: artifacts, projectHash: "abc", limit: 1).count, 1)
    }
}

final class JavaLiveMetricsParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", name), encoding: .utf8)
    }

    private let kib = 1_024

    func testG1OfJava21() throws {
        let heap = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-G1.txt")))
        XCTAssertEqual(heap.usedBytes, 37_931 * kib)
        XCTAssertEqual(heap.committedBytes, 524_288 * kib)
        XCTAssertEqual(heap.maxBytes, 0x20000000, "the address range of the reservation")
    }

    func testG1OfJava26SaysReservedAndCommitted() throws {
        let heap = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-G1-26.txt")))
        XCTAssertEqual(heap.usedBytes, 33_313 * kib)
        XCTAssertEqual(heap.committedBytes, 43_008 * kib)
        XCTAssertEqual(heap.maxBytes, 524_288 * kib)
    }

    func testParallelAndSerialAreTheSumOfTheirGenerations() throws {
        let parallel = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-Parallel.txt")))
        XCTAssertEqual(parallel.usedBytes, (41_135 + 1_067) * kib)
        XCTAssertEqual(parallel.committedBytes, (153_088 + 349_696) * kib)
        XCTAssertEqual(parallel.maxBytes, 0x160800000 - 0x155d80000 + (0x155d80000 - 0x140800000))

        let serial = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-Serial.txt")))
        XCTAssertEqual(serial.usedBytes, (41_606 + 1_067) * kib)
        XCTAssertEqual(serial.committedBytes, (157_248 + 349_568) * kib)
    }

    func testZGCOfBothJDKs() throws {
        let z21 = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-Z.txt")))
        XCTAssertEqual(z21, JavaLiveHeap(usedBytes: 36 * kib * kib, committedBytes: 512 * kib * kib, maxBytes: 512 * kib * kib))
        let z26 = try XCTUnwrap(JavaLiveMetricsParser.parseHeapInfo(fixture("heap-info-Z-26.txt")))
        XCTAssertEqual(z26.usedBytes, 40 * kib * kib)
        XCTAssertEqual(z26.maxBytes, 512 * kib * kib)
    }

    func testShenandoahShapeAndUnknownOutput() {
        let shenandoah = """
        1234:
         Shenandoah Heap
          65536K max, 8192K soft max, 32768K committed, 3000K used
          1024 x 64K regions
        """
        let heap = JavaLiveMetricsParser.parseHeapInfo(shenandoah)
        XCTAssertEqual(heap, JavaLiveHeap(usedBytes: 3_000 * kib, committedBytes: 32_768 * kib, maxBytes: 65_536 * kib))
        XCTAssertNil(JavaLiveMetricsParser.parseHeapInfo("1234:\nCould not attach to process\n"))
        XCTAssertNil(JavaLiveMetricsParser.parseHeapInfo(""))
    }

    func testPerfCounters() throws {
        let counters = JavaLiveMetricsParser.parsePerfCounters(try fixture("perfcounter-threads-G1-26.txt"))
        XCTAssertEqual(counters.liveThreads, 7)
        XCTAssertEqual(counters.daemonThreads, 6)
        XCTAssertEqual(counters.peakThreads, 7)
        XCTAssertEqual(counters.metaspaceUsedBytes, 163_168)
        XCTAssertEqual(JavaLiveMetricsParser.parsePerfCounters("nothing useful\n"), JavaLivePerfCounters())
    }
}

final class JavaLiveCommandsTests: XCTestCase {
    func testInvocationsAreArgumentVectors() {
        let jcmd = URL(fileURLWithPath: "/jdk/bin/jcmd")
        XCTAssertEqual(JavaLiveCommands.heapInfo(jcmd: jcmd, pid: 42).arguments, ["42", "GC.heap_info"])
        XCTAssertEqual(JavaLiveCommands.perfCounters(jcmd: jcmd, pid: 42).arguments, ["42", "PerfCounter.print"])
        XCTAssertEqual(JavaLiveCommands.collectGarbage(jcmd: jcmd, pid: 42).arguments, ["42", "GC.run"])
        XCTAssertEqual(
            JavaLiveCommands.dumpRecording(jcmd: jcmd, pid: 42, file: URL(fileURLWithPath: "/r/snap 1.jfr")).arguments,
            ["42", "JFR.dump", "name=umbra", "filename=/r/snap 1.jfr"]
        )
        XCTAssertEqual(JavaLiveCommands.listJVMs(jps: URL(fileURLWithPath: "/jdk/bin/jps")).arguments, ["-v"])
    }

    func testFindsTheRunsJVMsByMarkerOnly() {
        let output = """
        70666 Live -Dumbra.profile.run=abc123 -XX:StartFlightRecording=name=umbra,filename=live.jfr
        70700 Live -Dumbra.profile.run=abc1234 -Xmx1g
        70701 GradleDaemon -Xmx512m -Dfoo=bar
        70702 Worker -Dumbra.profile.run=abc123
        70703 Jps -Dapplication.home=/jdk
        garbage line
        """
        XCTAssertEqual(JavaLiveCommands.pids(inJPSOutput: output, runID: "abc123"), [70702, 70666])
        XCTAssertEqual(JavaLiveCommands.pids(inJPSOutput: output, runID: "abc1234"), [70700])
        XCTAssertEqual(JavaLiveCommands.pids(inJPSOutput: output, runID: "nope"), [])
    }

    func testGradleArgumentsMarkTheRun() {
        let args = JavaProfileGradleScript.arguments(
            scriptURL: URL(fileURLWithPath: "/r/p.gradle"), recordingDirectory: URL(fileURLWithPath: "/r"),
            options: .init(), jdkFeatureVersion: 21, runID: "20261014-ab12cd"
        )
        XCTAssertTrue(args.contains("-PumbraProfileRun=20261014-ab12cd"))
        XCTAssertTrue(JavaProfileGradleScript.source.contains("-Dumbra.profile.run="))
    }
}

final class JavaLineProfileTests: XCTestCase {
    private let symbols = JavaProfileSymbols()

    private func frame(_ className: String, _ name: String, _ line: Int32) -> Int32 {
        symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
    }

    func testCallLinesCarryTheirCalleesAndSelfLinesTheirOwn() {
        let main = frame("app.Main", "main", 10)          // calls work() on line 10
        let work = frame("app.Main", "work", 20)          // calls Util.hot() on line 20
        let hot = frame("app.Util", "hot", 5)
        let other = frame("app.Main", "other", 30)
        var tree = JavaProfileTree()
        tree.add(stack: [main, work, hot], weight: 6)
        tree.add(stack: [main, work], weight: 2)
        tree.add(stack: [main, other], weight: 1)
        let profile = JavaLineProfile.build(from: tree, symbols: symbols)
        XCTAssertEqual(profile.totalSamples, 9)

        let mainLines = profile.lines(ofClass: "app.Main")
        XCTAssertEqual(mainLines[10], .init(selfCount: 0, totalCount: 9), "main's line covers all of it")
        XCTAssertEqual(mainLines[20], .init(selfCount: 2, totalCount: 8))
        XCTAssertEqual(mainLines[30], .init(selfCount: 1, totalCount: 1))
        XCTAssertEqual(profile.lines(ofClass: "app.Util")[5], .init(selfCount: 6, totalCount: 6))
        XCTAssertEqual(profile.lines(ofClass: "app.Missing"), [:])
    }

    func testRecursionAndSameLineFramesCountOnce() {
        let fib = frame("app.Fib", "fib", 5)
        let main = frame("app.Fib", "main", 12)
        var tree = JavaProfileTree()
        tree.add(stack: [main, fib, fib, fib, fib], weight: 7)
        let line = JavaLineProfile.build(from: tree, symbols: symbols).lines(ofClass: "app.Fib")[5]
        XCTAssertEqual(line, .init(selfCount: 7, totalCount: 7), "four nested frames of one line are one cost, not 28")
    }

    func testNestedAnonymousAndLambdaClassesBelongToTheirFile() {
        let main = frame("app.Order", "main", 3)
        let inner = frame("app.Order$Line", "total", 40)
        let lambda = frame("app.Order$$Lambda/0x0000000800c03000", "run", 55)
        var tree = JavaProfileTree()
        tree.add(stack: [main, inner], weight: 2)
        tree.add(stack: [main, lambda], weight: 3)
        let profile = JavaLineProfile.build(from: tree, symbols: symbols)
        XCTAssertEqual(profile.classNames, ["app.Order"])
        XCTAssertEqual(profile.lines(ofClass: "app.Order")[40]?.totalCount, 2)
        XCTAssertEqual(profile.lines(ofClass: "app.Order")[55]?.totalCount, 3)
        XCTAssertEqual(JavaLineProfile.topLevelClass(of: "app.Order$Line$1"), "app.Order")
    }

    func testFramesWithoutALineOrClassAreSkippedAndFilteredTreesWork() {
        let noLine = frame("app.Main", "native0", 0)
        let marker = frame("", "sleeping", 0)
        let work = frame("app.Main", "work", 8)
        var tree = JavaProfileTree()
        tree.add(stack: [work, noLine, marker], weight: 4)
        let profile = JavaLineProfile.build(from: tree, symbols: symbols)
        XCTAssertEqual(profile.lines(ofClass: "app.Main").keys.sorted(), [8])
        XCTAssertEqual(profile.lines(ofClass: "app.Main")[8]?.totalCount, 4)

        // A reweighted (filtered) tree: lines of emptied branches are absent.
        var selfs = [Int](repeating: 0, count: tree.nodeCount)
        selfs[0] = 0
        let empty = tree.reweighted(selfCounts: selfs)
        XCTAssertTrue(JavaLineProfile.build(from: empty, symbols: symbols).lines(ofClass: "app.Main").isEmpty)
    }
}
