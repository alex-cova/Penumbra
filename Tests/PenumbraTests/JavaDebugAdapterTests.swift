import Foundation
import JavaIntelligence
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
        /// `breakpointVerified` and `breakpointRemoved`, kept apart from stops.
        private var bookkeeping: [[String: Any]] = []
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
                        } else if let name = json["event"] as? String, name.hasPrefix("breakpoint") {
                            bookkeeping.append(json)
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

        /// Every `breakpointVerified` / `breakpointRemoved` event received so far.
        var breakpointEvents: [[String: Any]] {
            condition.lock()
            defer { condition.unlock() }
            return bookkeeping
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
    private var loop: URL!
    private var thrower: URL!
    private var workers: URL!
    private var smart: URL!
    private var streams: URL!
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

        loop = sources.appendingPathComponent("Loop.java")
        try """
        public class Loop {
            public static void main(String[] args) throws Exception {
                String name = "abc";
                for (int i = 0; i < 6; i++) {
                    int square = i * i; // LOOP
                    System.out.println("square " + square);
                }
                Thread.sleep(30000);
            }
        }
        """.write(to: loop, atomically: true, encoding: .utf8)
        thrower = sources.appendingPathComponent("Thrower.java")
        try """
        public class Thrower {
            static int compute(int n) {
                return n * 3; // COMPUTE
            }

            public static void main(String[] args) throws Exception {
                int total = compute(2);
                try {
                    throw new IllegalStateException("boom " + total); // THROW
                } catch (IllegalStateException e) {
                    System.out.println(e.getMessage());
                }
                Thread.sleep(30000);
            }
        }
        """.write(to: thrower, atomically: true, encoding: .utf8)
        workers = sources.appendingPathComponent("Workers.java")
        try """
        public class Workers {
            static volatile long ticks;

            public static void main(String[] args) throws Exception {
                Thread worker = new Thread(() -> {
                    while (true) {
                        ticks++;
                        try { Thread.sleep(2); } catch (InterruptedException e) { return; }
                    }
                }, "worker");
                worker.setDaemon(true);
                worker.start();
                Thread.sleep(300);
                int marker = 1; // MAIN
                Thread.sleep(30000);
            }
        }
        """.write(to: workers, atomically: true, encoding: .utf8)
        smart = sources.appendingPathComponent("Smart.java")
        try """
        public class Smart {
            static int a() {
                return 1; // A
            }

            static int b(int x) {
                return x + 1; // B
            }

            public static void main(String[] args) throws Exception {
                int r = b(a()); // CALL
                System.out.println(r);
                Thread.sleep(30000);
            }
        }
        """.write(to: smart, atomically: true, encoding: .utf8)

        streams = sources.appendingPathComponent("Streams.java")
        try """
        import java.util.*;
        import java.util.stream.*;

        public class Streams {
            public static void main(String[] args) throws Exception {
                List<Integer> numbers = List.of(5, 1, 4, 2);
                int limit = 1;
                List<Integer> out = numbers.stream().filter(n -> n > limit).map(n -> n * 10).sorted().collect(Collectors.toList()); // TRACE
                System.out.println(out);
                Thread.sleep(30000);
            }
        }
        """.write(to: streams, atomically: true, encoding: .utf8)

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
                             hello.path, util.path, probe.path, noise.path, loop.path, thrower.path, workers.path, smart.path, streams.path]
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
        XCTAssertTrue(error(adapter, "nope").hasPrefix("Cannot find 'nope'"))
        XCTAssertTrue(error(adapter, "numbers[9]").contains("out of bounds"))
        XCTAssertTrue(error(adapter, "p.next.next.x").contains("of null"))
        XCTAssertTrue(error(adapter, "p.missing").contains("no field 'missing'"))
        XCTAssertTrue(error(adapter, "i / 0").contains("Division by zero"))
        XCTAssertTrue(error(adapter, "p.nothing()").contains("no method 'nothing'"))
        XCTAssertTrue(error(adapter, "text.charAt(\"x\")").contains("No charAt()"))
        XCTAssertTrue(error(adapter, "Nope.value").contains("Cannot find 'Nope'"))
        XCTAssertEqual(error(adapter, "   "), "Enter an expression.")
        _ = adapter.send("disconnect")
    }

    func testEvaluateOperatorsCallsAndConstruction() throws {
        let adapter = try stoppedInProbe()
        XCTAssertEqual(value(adapter, "i + 1"), "2")
        XCTAssertEqual(value(adapter, "i * 10 + numbers[2]"), "40")
        XCTAssertEqual(value(adapter, "-numbers[0] % 7"), "-3")
        XCTAssertEqual(value(adapter, "(double) p.x / 2"), "1.5")
        XCTAssertEqual(value(adapter, "p.x / 2"), "1")
        XCTAssertEqual(value(adapter, "1L << 40"), "1099511627776")
        XCTAssertEqual(value(adapter, "p.x == 3 && p.next != null"), "true")
        XCTAssertEqual(value(adapter, "p.next.next == null || nope"), "true", "|| stops before the right side")
        XCTAssertEqual(value(adapter, "i > 0 ? \"pos\" : \"neg\""), "\"pos\"")
        XCTAssertEqual(value(adapter, "greeting + \" \" + i + 'c' + 1.5"), "\"hi 1c1.5\"")
        XCTAssertEqual(value(adapter, "\"n=\" + noisy"), "\"n=noisy\"", "concatenation calls toString()")
        XCTAssertEqual(value(adapter, "boxed == 42 && boxed + 1 == 43"), "true", "a box unboxes")
        XCTAssertEqual(value(adapter, "text.length() > 2"), "true")
        XCTAssertEqual(value(adapter, "text.substring(1, 2)"), "\"\\\"\"")
        XCTAssertEqual(value(adapter, "Math.max(i, 5)"), "5")
        XCTAssertEqual(value(adapter, "Math.abs(-2.5)"), "2.5", "the double overload, not int")
        XCTAssertEqual(value(adapter, "String.valueOf(i)"), "\"1\"")
        XCTAssertEqual(value(adapter, "String.format(\"%d-%s\", i, greeting)"), "\"1-hi\"", "varargs, with boxing")
        XCTAssertEqual(value(adapter, "java.util.List.of(1, 2).size()"), "2")
        XCTAssertEqual(value(adapter, "color == Color.GREEN"), "true", "a nested enum by its simple name")
        XCTAssertEqual(value(adapter, "p instanceof Probe.Point"), "true")
        XCTAssertEqual(value(adapter, "new StringBuilder(\"a\").append(i).toString()"), "\"a1\"")
        XCTAssertEqual(value(adapter, "new int[] {4, 5}[1]"), "5")
        XCTAssertEqual(value(adapter, "new Point().y"), "4")
        _ = adapter.send("disconnect")
    }

    func testSetValueChangesLocalsFieldsAndElements() throws {
        let adapter = try stoppedInProbe()
        XCTAssertEqual(adapter.send("setValue", ["target": "i", "value": "5"])["ok"] as? Bool, true)
        XCTAssertEqual(value(adapter, "i"), "5")
        XCTAssertEqual(value(adapter, "p.x = p.x * 3"), "9")
        XCTAssertEqual(value(adapter, "p.x"), "9")
        XCTAssertEqual(adapter.send("setValue", ["target": "numbers[0]", "value": "i + 2"])["ok"] as? Bool, true)
        XCTAssertEqual(value(adapter, "numbers[0]"), "7")
        XCTAssertEqual(value(adapter, "counter += 1"), "8")
        let wrong = adapter.send("setValue", ["target": "i", "value": "\"text\""])
        XCTAssertEqual(wrong["ok"] as? Bool, false)
        XCTAssertTrue((wrong["error"] as? String ?? "").contains("cannot be assigned"), "\(wrong)")
        _ = adapter.send("disconnect")
    }

    func testLambdasAndStreamsCompileIntoTheTarget() throws {
        let adapter = try stoppedInProbe()
        XCTAssertEqual(value(adapter, "java.util.Arrays.stream(numbers).map(n -> n * 2).sum()"), "120")
        // `counter` is a field of `this`: rewritten to the frame's object, package access included.
        XCTAssertEqual(value(adapter, "java.util.stream.IntStream.range(0, 3).map(k -> k + counter).sum()"), "24")
        XCTAssertEqual(value(adapter, "java.util.stream.Stream.of(\"b\", \"a\").sorted().map(String::toUpperCase).toList().toString()"),
                       "\"[A, B]\"")
        // The same expression again reuses the compiled class.
        XCTAssertEqual(value(adapter, "java.util.Arrays.stream(numbers).map(n -> n * 2).sum()"), "120")
        let broken = error(adapter, "java.util.stream.Stream.of(1).map(x -> x.nope())")
        XCTAssertTrue(broken.hasPrefix("Cannot compile"), broken)
        XCTAssertEqual(value(adapter, "i"), "1", "the frame is still usable")
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

    // MARK: - Breakpoint properties

    /// The next stop event, failing the test when none comes.
    private func nextStop(_ adapter: Adapter, _ description: String, timeout: TimeInterval = 15,
                          file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let event = try XCTUnwrap(adapter.nextEvent(timeout: timeout), "\(description): no stop", file: file, line: line)
        XCTAssertEqual(event["event"] as? String, "stopped", description, file: file, line: line)
        return event
    }

    private func breakpoint(_ adapter: Adapter, _ spec: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let reply = adapter.send("setBreakpoint", spec)
        XCTAssertEqual(reply["ok"] as? Bool, true, "setBreakpoint \(spec): \(reply)", file: file, line: line)
    }

    private func logLines(_ adapter: Adapter) -> [String] {
        adapter.outputLines.filter { $0.stream == "log" }.map(\.text)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func testConditionStopsOnlyOnTheMatchingHit() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "c", "file": loop.path, "line": line, "condition": "i == 3 && name.startsWith(\"a\")"])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        let stop = try nextStop(adapter, "the condition holds")
        XCTAssertEqual(stop["line"] as? Int, line)
        XCTAssertEqual(stop["breakpointId"] as? String, "c")
        XCTAssertEqual(value(adapter, "i"), "3")
        XCTAssertEqual(adapter.breakpointEvents.first?["verified"] as? Bool, true)
        let overhead = adapter.send("overhead")["breakpoints"] as? [[String: Any]]
        XCTAssertEqual(overhead?.first?["hits"] as? Int, 4, "every hit counts, not only the one that stopped")
        _ = adapter.send("disconnect")
    }

    func testLogOnlyBreakpointNeverStops() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "log", "file": loop.path, "line": line, "suspendPolicy": "none",
                             "logMessage": true, "logExpression": "\"i=\" + i"])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        XCTAssertTrue(waitFor { logLines(adapter).filter { $0.hasPrefix("i=") }.count == 6 }, "\(logLines(adapter))")
        XCTAssertEqual(logLines(adapter).filter { $0.hasPrefix("i=") }, (0..<6).map { "i=\($0)" })
        XCTAssertTrue(logLines(adapter).contains { $0.hasPrefix("Breakpoint reached at Loop.main(Loop.java:\(line))") })
        XCTAssertNil(adapter.nextEvent(timeout: 0.3), "suspend off never stops")
        _ = adapter.send("disconnect")
    }

    func testPassCountAndRemoveOnceHit() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "p", "file": loop.path, "line": line, "passCount": 4, "removeOnceHit": true])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "the fourth hit")
        XCTAssertEqual(value(adapter, "i"), "3")
        XCTAssertTrue(waitFor { adapter.breakpointEvents.contains { $0["event"] as? String == "breakpointRemoved" } })
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        XCTAssertNil(adapter.nextEvent(timeout: 1), "removed once hit")
        _ = adapter.send("disconnect")
    }

    func testAConditionThatFailsStopsAndSaysWhy() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "bad", "file": loop.path, "line": line, "condition": "missing > 1"])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        let stop = try nextStop(adapter, "a failing condition")
        XCTAssertEqual(stop["reason"] as? String, "conditionError")
        XCTAssertTrue((stop["message"] as? String ?? "").contains("Cannot find 'missing'"), "\(stop)")
        _ = adapter.send("disconnect")
    }

    func testChangingAndClearingABreakpointDuringTheSession() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "b", "file": loop.path, "line": line])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "first hit")
        XCTAssertEqual(value(adapter, "i"), "0")
        // The same id replaces it: now with a condition.
        breakpoint(adapter, ["breakpointId": "b", "file": loop.path, "line": line, "condition": "i == 4"])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "the new condition")
        XCTAssertEqual(value(adapter, "i"), "4")
        XCTAssertEqual(adapter.send("clearBreakpoint", ["breakpointId": "b"])["ok"] as? Bool, true)
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        XCTAssertNil(adapter.nextEvent(timeout: 1))
        _ = adapter.send("disconnect")
    }

    func testMutedBreakpointsDoNotStop() throws {
        let adapter = try launch(mainClass: "Loop")
        let line = try line(of: "// LOOP", in: loop)
        breakpoint(adapter, ["breakpointId": "m", "file": loop.path, "line": line])
        XCTAssertEqual(adapter.send("muteBreakpoints", ["muted": true])["ok"] as? Bool, true)
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        XCTAssertTrue(waitFor { adapter.outputLines.contains { $0.text == "square 25" } })
        XCTAssertNil(adapter.nextEvent(timeout: 0.3))
        _ = adapter.send("disconnect")
    }

    func testMethodAndExceptionBreakpoints() throws {
        let adapter = try launch(mainClass: "Thrower")
        breakpoint(adapter, ["breakpointId": "m", "kind": "method", "className": "Thrower", "methodName": "compute"])
        breakpoint(adapter, ["breakpointId": "e", "kind": "exception", "className": "java.lang.IllegalStateException",
                             "caught": true, "uncaught": true])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        let method = try nextStop(adapter, "method entry")
        XCTAssertEqual(method["reason"] as? String, "method")
        XCTAssertEqual(method["line"] as? Int, try line(of: "// COMPUTE", in: thrower))
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        let exception = try nextStop(adapter, "the throw")
        XCTAssertEqual(exception["reason"] as? String, "exception")
        XCTAssertEqual(exception["line"] as? Int, try line(of: "// THROW", in: thrower))
        XCTAssertEqual(exception["message"] as? String, "java.lang.IllegalStateException: boom 6")
        _ = adapter.send("disconnect")
    }

    func testThreadPolicyLeavesOtherThreadsRunning() throws {
        for (policy, workerSuspended) in [("thread", false), ("all", true)] {
            let adapter = try launch(mainClass: "Workers")
            let line = try line(of: "// MAIN", in: workers)
            breakpoint(adapter, ["breakpointId": "w", "file": workers.path, "line": line, "suspendPolicy": policy])
            XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
            let stop = try nextStop(adapter, "main stops (\(policy))")
            XCTAssertEqual(stop["threadName"] as? String, "main")
            XCTAssertEqual(stop["suspendsAll"] as? Bool, policy == "all")
            let threads = try XCTUnwrap(adapter.send("threads")["threads"] as? [[String: Any]])
            let main = try XCTUnwrap(threads.first { $0["name"] as? String == "main" })
            let worker = try XCTUnwrap(threads.first { $0["name"] as? String == "worker" })
            XCTAssertEqual(main["suspended"] as? Bool, true)
            XCTAssertEqual(main["current"] as? Bool, true)
            XCTAssertEqual(worker["suspended"] as? Bool, workerSuspended, policy)
            if policy == "thread" {
                let before = value(adapter, "Workers.ticks")
                Thread.sleep(forTimeInterval: 0.2)
                XCTAssertNotEqual(value(adapter, "Workers.ticks"), before, "the worker keeps running")
            }
            // Another suspended thread can be inspected.
            let workerID = try XCTUnwrap(worker["id"] as? Int)
            if workerSuspended {
                XCTAssertEqual(adapter.send("selectThread", ["threadId": workerID])["ok"] as? Bool, true)
                XCTAssertNotNil(adapter.send("stackFrames")["frames"] as? [[String: Any]])
            } else {
                XCTAssertEqual(adapter.send("selectThread", ["threadId": workerID])["ok"] as? Bool, false)
            }
            _ = adapter.send("disconnect")
        }
    }

    // MARK: - Stepping

    func testRunToCursorThenDropFrameAndForceStepInto() throws {
        let adapter = try launch()
        breakpoint(adapter, ["breakpointId": "h", "file": hello.path, "line": 17])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 17, reason: "breakpoint", "first line of main")
        XCTAssertEqual(adapter.send("runToCursor", ["file": hello.path, "line": 19])["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 19, reason: "runToCursor", "at the cursor")

        XCTAssertEqual(adapter.send("stepInto")["ok"] as? Bool, true)
        stopped(adapter, file: util, line: 5, reason: "step", "into Util.twice")
        XCTAssertEqual(adapter.send("dropFrame", ["frameIndex": 0])["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 19, reason: "dropFrame", "back at the call")

        XCTAssertEqual(adapter.send("stepOver")["ok"] as? Bool, true)
        stopped(adapter, line: 20, reason: "step", "on println")
        XCTAssertEqual(adapter.send("forceStepInto")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "inside the JDK")
        let frames = try XCTUnwrap(adapter.send("stackFrames")["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.first?["className"] as? String, "java.io.PrintStream")
        XCTAssertEqual(frames.first?["library"] as? Bool, true)
        XCTAssertEqual(frames.last?["library"] as? Bool, false)
        _ = adapter.send("disconnect")
    }

    func testForceReturnHandsBackAValueToTheCaller() throws {
        let adapter = try launch()
        breakpoint(adapter, ["breakpointId": "add", "file": hello.path, "line": 5])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 5, reason: "breakpoint", "in add")
        let wrong = adapter.send("forceReturn", ["expression": "\"text\""])
        XCTAssertEqual(wrong["ok"] as? Bool, false, "an int method cannot return a string")
        XCTAssertEqual(adapter.send("forceReturn", ["expression": "a * 100"])["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 18, reason: "step", "back in main")
        XCTAssertEqual(adapter.send("stepOver")["ok"] as? Bool, true)
        stopped(adapter, file: hello, line: 19, reason: "step", "past the assignment")
        XCTAssertEqual(value(adapter, "y"), "100")
        _ = adapter.send("disconnect")
    }

    func testSmartStepIntoSkipsTheOtherCallsOnTheLine() throws {
        let adapter = try launch(mainClass: "Smart")
        let call = try line(of: "// CALL", in: smart)
        breakpoint(adapter, ["breakpointId": "s", "file": smart.path, "line": call])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "at the call")
        XCTAssertEqual(adapter.send("smartStepInto", ["methodName": "b"])["ok"] as? Bool, true)
        stopped(adapter, file: smart, line: try line(of: "// B", in: smart), reason: "step", "into b, not a")
        _ = adapter.send("disconnect")
    }

    // MARK: - Memory

    func testInstanceCountsAndInstances() throws {
        let adapter = try stoppedInProbe()
        let classes = try XCTUnwrap(adapter.send("instanceCounts")["classes"] as? [[String: Any]])
        let point = try XCTUnwrap(classes.first { $0["className"] as? String == "Probe$Point" })
        XCTAssertEqual(point["count"] as? Int, 2)
        let instances = try XCTUnwrap(adapter.send("instances", ["className": "Probe$Point"])["instances"] as? [[String: Any]])
        XCTAssertEqual(instances.count, 2)
        let expression = try XCTUnwrap(instances.first?["expression"] as? String)
        XCTAssertTrue(expression.hasPrefix("#"))
        XCTAssertEqual(value(adapter, expression + ".y"), "4", "a listed instance opens by its id")
        _ = adapter.send("disconnect")
    }

    // MARK: - Stream trace

    func testTracingAStreamChainRecordsEveryStage() throws {
        let adapter = try launch(mainClass: "Streams")
        let line = try line(of: "// TRACE", in: streams)
        breakpoint(adapter, ["breakpointId": "t", "file": streams.path, "line": line])
        XCTAssertEqual(adapter.send("resume")["ok"] as? Bool, true)
        _ = try nextStop(adapter, "at the chain")

        let source = try String(contentsOf: streams, encoding: .utf8)
        let chain = try XCTUnwrap(JavaStreamChain.chains(onLine: line, in: source).first)
        let reply = adapter.send("traceStream", [
            "expression": chain.tracedExpression(),
            "imports": JavaDebugSession.imports(inSource: source)
        ], timeout: 60)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let stages = try XCTUnwrap(reply["stages"] as? [[String: Any]]).map { stage in
            (stage["values"] as? [[String: Any]] ?? []).map {
                JavaStreamTraceElement(time: ($0["time"] as? NSNumber)?.int64Value ?? 0, value: $0["value"] as? String ?? "",
                                       identity: $0["identity"] as? String ?? "")
            }
        }
        XCTAssertEqual(stages.map { $0.map(\.value) }, [["5", "1", "4", "2"], ["5", "4", "2"], ["50", "40", "20"], ["20", "40", "50"]])
        XCTAssertEqual(chain.links(from: stages[0], to: stages[1], operation: "filter"), [0, 2, 3])
        XCTAssertEqual(chain.links(from: stages[1], to: stages[2], operation: "map"), [0, 1, 2])
        XCTAssertEqual(chain.links(from: stages[2], to: stages[3], operation: "sorted"), [2, 1, 0])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["type"] as? String, "java.util.ArrayList")
        _ = adapter.send("disconnect")
    }
}
