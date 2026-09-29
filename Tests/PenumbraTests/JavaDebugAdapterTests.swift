import Foundation
import XCTest
@testable import Umbra

/// Drives the real JDI adapter (`Example/Umbra/Tools/JavaDebugAdapter`) against a real JVM. Needs
/// a JDK and the built adapter jar; without them the tests skip rather than fail.
final class JavaDebugAdapterTests: XCTestCase {
    /// One adapter process, talked to over its JSON-lines protocol.
    private final class Adapter {
        private let process = Process()
        private let input = Pipe()
        private let condition = NSCondition()
        private var replies: [Int: [String: Any]] = [:]
        private var events: [[String: Any]] = []
        private var outputEvents: [[String: Any]] = []
        private var nextID = 1

        init(java: URL, jar: URL) throws {
            process.executableURL = java
            process.arguments = ["-jar", jar.path]
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let handle = output.fileHandleForReading
            Thread.detachNewThread { [self] in
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer = Data(buffer[buffer.index(after: newline)...])
                        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        condition.lock()
                        if json["event"] as? String == "output" {
                            outputEvents.append(json)
                        } else if json["event"] != nil {
                            events.append(json)
                        } else if let id = json["id"] as? Int {
                            replies[id] = json
                        }
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            }
        }

        deinit {
            if process.isRunning { process.terminate() }
        }

        func send(_ command: String, _ parameters: [String: Any] = [:], timeout: TimeInterval = 20) -> [String: Any] {
            condition.lock()
            let id = nextID
            nextID += 1
            condition.unlock()
            var body = parameters
            body["id"] = id
            body["command"] = command
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            input.fileHandleForWriting.write(data + Data([0x0A]))
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while replies[id] == nil {
                if !condition.wait(until: deadline) { return ["ok": false, "error": "timeout"] }
            }
            return replies.removeValue(forKey: id) ?? [:]
        }

        /// The next event that is not target output, or nil after `timeout`.
        func nextEvent(timeout: TimeInterval = 15) -> [String: Any]? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if !events.isEmpty { return events.removeFirst() }
                if !condition.wait(until: deadline) { return nil }
            }
        }

        /// Every `output` event received so far.
        var output: [[String: Any]] {
            condition.lock()
            defer { condition.unlock() }
            return outputEvents
        }

        /// The lines of every `output` event received so far, in arrival order.
        var outputLines: [(stream: String, text: String, partial: Bool)] {
            output.flatMap { event -> [(stream: String, text: String, partial: Bool)] in
                (event["lines"] as? [[String: Any]] ?? []).map {
                    ($0["stream"] as? String ?? "", $0["text"] as? String ?? "", $0["partial"] as? Bool ?? false)
                }
            }
        }
    }

    private var directory: URL!
    private var hello: URL!
    private var util: URL!
    private var probe: URL!
    private var noise: URL!
    private var java: URL!
    private var adapterJar: URL!

    override func setUpWithError() throws {
        let jdk = try XCTUnwrap(TestJDK.discovered, "No JDK installed")
        java = jdk.home.appendingPathComponent("bin/java")
        let javac = jdk.home.appendingPathComponent("bin/javac")
        guard FileManager.default.isExecutableFile(atPath: javac.path) else { throw XCTSkip("No javac in the JDK") }
        guard let jar = JavaDebugProcessLauncher().adapterJarURL() else { throw XCTSkip("Adapter jar not built") }
        adapterJar = jar

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("debug-adapter-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("demo"), withIntermediateDirectories: true)
        hello = sources.appendingPathComponent("Hello.java")
        util = sources.appendingPathComponent("demo/Util.java")
        try """
        import demo.Util;

        public class Hello {
            static int add(int a, int b) {
                int sum = a + b;
                return sum;
            }

            static void spin() throws Exception {
                long end = System.currentTimeMillis() + 30000;
                while (System.currentTimeMillis() < end) {
                    Thread.sleep(20);
                }
            }

            public static void main(String[] args) throws Exception {
                int x = 1;
                int y = add(x, 2);
                int z = Util.twice(y);
                System.out.println(z);
                spin();
            }
        }
        """.write(to: hello, atomically: true, encoding: .utf8)
        try """
        package demo;

        public class Util {
            public static int twice(int n) {
                int result = n * 2;
                return result;
            }
        }
        """.write(to: util, atomically: true, encoding: .utf8)

        probe = sources.appendingPathComponent("Probe.java")
        try """
        public class Probe {
            static class Point {
                int x = 3;
                int y = 4;
                String label = "origin";
                Point next;
            }

            static class Noisy {
                public String toString() {
                    return "noisy"; // NOISY
                }
            }

            enum Color { RED, GREEN }

            int counter = 7;
            static String greeting = "hi";

            void run() throws Exception {
                int[] numbers = {10, 20, 30};
                Point p = new Point();
                p.next = new Point();
                Integer boxed = 42;
                Color color = Color.GREEN;
                String text = "a\\"b";
                Noisy noisy = new Noisy();
                int i = 1;
                System.out.println(i + text + noisy + boxed + color + numbers.length); // BREAK
                Thread.sleep(30000);
            }

            public static void main(String[] args) throws Exception {
                new Probe().run();
            }
        }
        """.write(to: probe, atomically: true, encoding: .utf8)

        noise = sources.appendingPathComponent("Noise.java")
        try """
        public class Noise {
            public static void main(String[] args) throws Exception {
                for (int i = 0; i < 5000; i++) System.out.println("out " + i);
                for (int i = 0; i < 200; i++) System.err.println("err " + i);
                System.out.print("Enter name: ");
                System.out.flush();
                Thread.sleep(400);
                System.out.println("done");
                System.exit(3);
            }
        }
        """.write(to: noise, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = javac
        // Java 17 bytecode, so it runs on whichever JDK the test machine has.
        compile.arguments = ["--release", "17", "-g", "-d", directory.appendingPathComponent("classes").path,
                             hello.path, util.path, probe.path, noise.path]
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, "javac failed")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func launch(mainClass: String = "Hello") throws -> Adapter {
        let adapter = try Adapter(java: java, jar: adapterJar)
        let reply = adapter.send("launch", [
            "java": java.path,
            "classpath": directory.appendingPathComponent("classes").path,
            "mainClass": mainClass,
            "programArgs": "",
            "vmArgs": "",
            "port": JavaDebugPortPicker.pickPort(preferred: nil),
            "suspend": true,
            "sourceRoots": [directory.appendingPathComponent("src").path]
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "launch: \(reply)")
        return adapter
    }

    private func stopped(_ adapter: Adapter, file: URL? = nil, line: Int, reason: String,
                         _ description: String, testFile: StaticString = #filePath, testLine: UInt = #line) {
        guard let event = adapter.nextEvent() else {
            return XCTFail("\(description): no stop event", file: testFile, line: testLine)
        }
        XCTAssertEqual(event["event"] as? String, "stopped", description, file: testFile, line: testLine)
        XCTAssertEqual(event["line"] as? Int, line, description, file: testFile, line: testLine)
        XCTAssertEqual(event["reason"] as? String, reason, description, file: testFile, line: testLine)
        if let file {
            XCTAssertEqual((event["file"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           file.resolvingSymlinksInPath().path, description, file: testFile, line: testLine)
        }
    }

    // MARK: - Tests

    func testTargetOutputArrivesBatchedPerStreamInOrderWithTheExitCode() throws {
        let adapter = try launch(mainClass: "Noise")
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        let terminated = try XCTUnwrap(adapter.nextEvent(timeout: 30), "no terminated event")
        XCTAssertEqual(terminated["event"] as? String, "terminated")
        XCTAssertEqual(terminated["exitCode"] as? Int, 3)

        let lines = adapter.outputLines
        let out = lines.filter { $0.stream == "out" && $0.text.hasPrefix("out ") }.map(\.text)
        let err = lines.filter { $0.stream == "err" }.map(\.text)
        XCTAssertEqual(out, (0..<5000).map { "out \($0)" }, "no line lost or reordered on stdout")
        XCTAssertEqual(err, (0..<200).map { "err \($0)" }, "stderr is its own stream, in order")
        XCTAssertLessThan(adapter.output.count, 300, "5,200 lines must not become 5,200 events")
        XCTAssertLessThanOrEqual(lines.count, 5_205)
        for event in adapter.output {
            XCTAssertLessThanOrEqual((event["lines"] as? [Any])?.count ?? 0, 200, "A batch holds at most 200 lines")
        }
    }

    func testALineWithoutANewlineIsFlushedAsPartialAndCompletedLater() throws {
        let adapter = try launch(mainClass: "Noise")
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try XCTUnwrap(adapter.nextEvent(timeout: 30))

        // The JDWP agent announces its port on stdout; that line is real console output too.
        let tail = adapter.outputLines.filter {
            $0.stream == "out" && !$0.text.hasPrefix("out ") && !$0.text.hasPrefix("Listening for transport")
        }
        XCTAssertEqual(tail.map(\.text), ["Enter name: ", "done"])
        XCTAssertEqual(tail.map(\.partial), [true, false], "The prompt goes out open, the rest of its line closes it")
    }

    func testBreakpointBeforeTheClassLoadsThenStepIntoOutAndOver() throws {
        let adapter = try launch()
        // The program has not started, so `Hello` is not loaded: the breakpoint has to wait for it.
        XCTAssertEqual(adapter.send("setBreakpoint", ["file": hello.path, "line": 18])["ok"] as? Bool, true)
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 18, reason: "breakpoint", "breakpoint in main")

        XCTAssertEqual(adapter.send("stepInto")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 5, reason: "step", "into add")
        let frames = adapter.send("stackFrames")["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.compactMap { $0["name"] as? String }, ["add", "main"])

        XCTAssertEqual(adapter.send("stepOut")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 18, reason: "step", "out to main")

        XCTAssertEqual(adapter.send("stepOver")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 19, reason: "step", "over the call")

        // A class in a package: its path comes from the source roots, not from a breakpoint.
        XCTAssertEqual(adapter.send("stepInto")["ok"] as? Bool, true)
        stopped(adapter, file: util, line: 5, reason: "step", "into Util")

        _ = adapter.send("disconnect")
    }

    func testPauseStopsARunningProgramAndRefusesASecondPause() throws {
        let adapter = try launch()
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        // Give main time to reach the busy loop in spin().
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertEqual(adapter.send("pause")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 12, reason: "pause", "paused in spin")
        let frames = adapter.send("stackFrames")["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.last?["name"] as? String, "main")

        let again = adapter.send("pause")
        XCTAssertEqual(again["ok"] as? Bool, false)
        XCTAssertEqual(again["error"] as? String, "already paused")

        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = adapter.send("disconnect")
    }

    func testStepWithoutAStopIsRejected() throws {
        let adapter = try launch()
        let reply = adapter.send("stepInto")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        _ = adapter.send("disconnect")
    }

    // MARK: - Evaluate

    private func line(of marker: String, in file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        let index = try XCTUnwrap(text.components(separatedBy: "\n").firstIndex { $0.contains(marker) })
        return index + 1
    }

    /// Runs `Probe` to its breakpoint and hands back the adapter, stopped there.
    private func stoppedInProbe() throws -> Adapter {
        let adapter = try launch(mainClass: "Probe")
        let line = try line(of: "// BREAK", in: probe)
        XCTAssertEqual(adapter.send("setBreakpoint", ["file": probe.path, "line": line])["ok"] as? Bool, true)
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        stopped(adapter, file: probe, line: line, reason: "breakpoint", "breakpoint in Probe.run")
        return adapter
    }

    private func evaluate(_ adapter: Adapter, _ expression: String) -> [String: Any] {
        adapter.send("evaluate", ["expression": expression, "frameIndex": 0])
    }

    private func result(_ adapter: Adapter, _ expression: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let reply = evaluate(adapter, expression)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(expression): \(reply)", file: file, line: line)
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func value(_ adapter: Adapter, _ expression: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        result(adapter, expression, file: file, line: line)["value"] as? String
    }

    private func error(_ adapter: Adapter, _ expression: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let reply = evaluate(adapter, expression)
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(expression) should fail: \(reply)", file: file, line: line)
        return reply["error"] as? String ?? ""
    }

    func testEvaluateReadsLocalsFieldsAndArrayElements() throws {
        let adapter = try stoppedInProbe()
        XCTAssertEqual(value(adapter, "i"), "1")
        XCTAssertEqual(value(adapter, "numbers[i]"), "20")
        XCTAssertEqual(value(adapter, "numbers.length"), "3")
        XCTAssertEqual(value(adapter, "p.x"), "3")
        XCTAssertEqual(value(adapter, "p.next.label"), "\"origin\"")
        // A field of `this`, with and without the receiver, and a static field.
        XCTAssertEqual(value(adapter, "this.counter"), "7")
        XCTAssertEqual(value(adapter, "counter"), "7")
        XCTAssertEqual(value(adapter, "greeting"), "\"hi\"")
        // Boxes and enums show their value; strings are quoted and escaped.
        XCTAssertEqual(value(adapter, "boxed"), "42")
        XCTAssertEqual(value(adapter, "color"), "GREEN")
        XCTAssertEqual(value(adapter, "text"), "\"a\\\"b\"")
        _ = adapter.send("disconnect")
    }

    func testEvaluateLiteralsAndTheTypeOfAResult() throws {
        let adapter = try stoppedInProbe()
        XCTAssertEqual(value(adapter, "5"), "5")
        XCTAssertEqual(value(adapter, "-7L"), "-7")
        XCTAssertEqual(value(adapter, "1.5"), "1.5")
        XCTAssertEqual(value(adapter, "true"), "true")
        XCTAssertEqual(value(adapter, "null"), "null")
        XCTAssertEqual(value(adapter, "\"lit\""), "\"lit\"")
        XCTAssertEqual(value(adapter, "'c'"), "'c'")
        XCTAssertEqual(result(adapter, "numbers")["type"] as? String, "int[]")
        XCTAssertEqual(value(adapter, "numbers"), "int[3] {10, 20, 30}")
        _ = adapter.send("disconnect")
    }

    func testEvaluateExpandsObjectsAndArraysOneLevelAtATime() throws {
        let adapter = try stoppedInProbe()
        let point = result(adapter, "p")
        XCTAssertEqual(point["hasChildren"] as? Bool, true)
        let children = try XCTUnwrap(point["children"] as? [[String: Any]])
        XCTAssertEqual(children.compactMap { $0["name"] as? String }, ["x", "y", "label", "next"])
        XCTAssertEqual(children.compactMap { $0["expression"] as? String }, ["p.x", "p.y", "p.label", "p.next"])
        // A child says it can be opened, and opening it is another evaluation of its expression.
        XCTAssertEqual(children.last?["hasChildren"] as? Bool, true)
        XCTAssertNil(children.last?["children"])
        let next = result(adapter, "p.next")
        XCTAssertEqual((next["children"] as? [[String: Any]])?.count, 4)

        let numbers = try XCTUnwrap(result(adapter, "numbers")["children"] as? [[String: Any]])
        XCTAssertEqual(numbers.compactMap { $0["value"] as? String }, ["10", "20", "30"])
        XCTAssertEqual(numbers.compactMap { $0["expression"] as? String }, ["numbers[0]", "numbers[1]", "numbers[2]"])
        _ = adapter.send("disconnect")
    }

    func testEvaluateCallsToStringWithoutStoppingAtABreakpointInsideIt() throws {
        let adapter = try stoppedInProbe()
        // A breakpoint inside toString() would hang the invoking thread if it were live.
        let inside = try line(of: "// NOISY", in: probe)
        XCTAssertEqual(adapter.send("setBreakpoint", ["file": probe.path, "line": inside])["ok"] as? Bool, true)
        XCTAssertEqual(value(adapter, "noisy.toString()"), "\"noisy\"")
        XCTAssertEqual(value(adapter, "text.toString()"), "\"a\\\"b\"")
        XCTAssertTrue(try XCTUnwrap(value(adapter, "p.toString()")).hasPrefix("\"Probe$Point@"))
        // The frame is still usable after the invocation, and the breakpoint is live again.
        XCTAssertEqual(value(adapter, "i"), "1")
        XCTAssertNil(adapter.nextEvent(timeout: 0.5), "the evaluation must not report a stop")
        _ = adapter.send("disconnect")
    }

    func testEvaluateSaysWhatItCannotDo() throws {
        let adapter = try stoppedInProbe()
        XCTAssertTrue(error(adapter, "i + 1").hasPrefix("Not supported"))
        XCTAssertTrue(error(adapter, "numbers.clone()").contains("toString()"))
        let staticCall = error(adapter, "Math.max(1, 2)")
        XCTAssertTrue(staticCall.hasPrefix("Cannot find 'Math'") && staticCall.contains("Static members"), staticCall)
        XCTAssertTrue(error(adapter, "nope").hasPrefix("Cannot find 'nope'"))
        XCTAssertTrue(error(adapter, "numbers[9]").contains("out of bounds"))
        XCTAssertTrue(error(adapter, "p.next.next.x").contains("of null"))
        XCTAssertTrue(error(adapter, "p.missing").contains("no field 'missing'"))
        XCTAssertEqual(error(adapter, "   "), "Enter an expression.")
        _ = adapter.send("disconnect")
    }

    func testEvaluateNeedsAPausedProgram() throws {
        let adapter = try launch()
        XCTAssertEqual(adapter.send("evaluate", ["expression": "1"])["ok"] as? Bool, false)
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(adapter.send("evaluate", ["expression": "1"])["ok"] as? Bool, false)
        _ = adapter.send("disconnect")
    }
}
