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
                        if json["event"] != nil {
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
                while let index = events.firstIndex(where: { $0["event"] as? String != "output" }) {
                    return events.remove(at: index)
                }
                events.removeAll { $0["event"] as? String == "output" }
                if !condition.wait(until: deadline) { return nil }
            }
        }
    }

    private var directory: URL!
    private var hello: URL!
    private var util: URL!
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

        let compile = Process()
        compile.executableURL = javac
        // Java 17 bytecode, so it runs on whichever JDK the test machine has.
        compile.arguments = ["--release", "17", "-g", "-d", directory.appendingPathComponent("classes").path,
                             hello.path, util.path]
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, "javac failed")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func launch() throws -> Adapter {
        let adapter = try Adapter(java: java, jar: adapterJar)
        let reply = adapter.send("launch", [
            "java": java.path,
            "classpath": directory.appendingPathComponent("classes").path,
            "mainClass": "Hello",
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
}
