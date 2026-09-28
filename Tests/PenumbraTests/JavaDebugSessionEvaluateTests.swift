import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// `JavaDebugSession.evaluate` against the real adapter and a real JVM: the Swift side of the
/// protocol (state gating, frame selection, result decoding). Skips without a JDK and adapter jar.
@MainActor
final class JavaDebugSessionEvaluateTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var java: URL!
    private var javaHome: URL!
    private var breakLine = 0

    override func setUpWithError() throws {
        let jdk = try XCTUnwrap(TestJDK.discovered, "No JDK installed")
        javaHome = jdk.home
        java = jdk.home.appendingPathComponent("bin/java")
        let javac = jdk.home.appendingPathComponent("bin/javac")
        guard FileManager.default.isExecutableFile(atPath: javac.path) else { throw XCTSkip("No javac in the JDK") }
        guard JavaDebugProcessLauncher().adapterJarURL() != nil else { throw XCTSkip("Adapter jar not built") }

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("debug-session-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        source = sources.appendingPathComponent("Session.java")
        let text = """
        public class Session {
            static class Box { int width = 2; int[] cells = {5, 6}; }

            static void inner() throws Exception {
                Box box = new Box();
                String name = "umbra";
                System.out.println(name + box.width); // BREAK
                Thread.sleep(30000);
            }

            public static void main(String[] args) throws Exception {
                inner();
            }
        }
        """
        try text.write(to: source, atomically: true, encoding: .utf8)
        breakLine = try XCTUnwrap(text.components(separatedBy: "\n").firstIndex { $0.contains("// BREAK") }) + 1

        let compile = Process()
        compile.executableURL = javac
        compile.arguments = ["--release", "17", "-g", "-d", directory.appendingPathComponent("classes").path, source.path]
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, "javac failed")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntilStopped(_ session: JavaDebugSession) async throws {
        for _ in 0..<200 {
            if case .stopped = session.state, !session.stackFrames.isEmpty { return }
            if case .failed(let message) = session.state { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("the program never stopped: \(session.state)")
    }

    private func start(_ session: JavaDebugSession) async throws {
        let launch = JavaManagedLaunch(
            javaExecutable: java,
            vmArguments: [],
            classpath: [directory.appendingPathComponent("classes")],
            mainClass: "Session",
            programArguments: [],
            environment: [:],
            jdwpPort: JavaDebugPortPicker.pickPort(preferred: nil),
            suspendOnStart: true
        )
        await session.start(
            launch: launch,
            breakpoints: [JavaBreakpoint(filePath: source.path, line: breakLine)],
            sourceRoots: [source.deletingLastPathComponent()]
        )
        try await waitUntilStopped(session)
    }

    func testEvaluateReadsTheSelectedFrameAndRecordsTheHistory() async throws {
        let session = JavaDebugSession()
        try await start(session)
        defer { session.stop() }

        guard case .value(let name) = await session.evaluate("name") else { return XCTFail("name did not evaluate") }
        XCTAssertEqual(name.value, "\"umbra\"")
        XCTAssertEqual(name.type, "java.lang.String")
        XCTAssertFalse(name.hasChildren)

        guard case .value(let box) = await session.evaluate("box") else { return XCTFail("box did not evaluate") }
        XCTAssertTrue(box.hasChildren)
        XCTAssertEqual(box.children?.map(\.name), ["width", "cells"])
        XCTAssertEqual(box.children?.first?.value, "2")
        XCTAssertEqual(box.children?.last?.expression, "box.cells")

        // Opening a child is another evaluation of its expression.
        guard case .value(let cells) = await session.evaluate("box.cells", record: false) else { return XCTFail("cells") }
        XCTAssertEqual(cells.children?.map(\.value), ["5", "6"])

        // Newest first, and the unrecorded one is absent.
        XCTAssertEqual(session.evaluations.map(\.expression), ["box", "name"])

        // Frame 1 is main: no `name` there, but its own `args`.
        session.selectFrame(1)
        if case .failure(let message) = await session.evaluate("name", record: false) {
            XCTAssertTrue(message.hasPrefix("Cannot find 'name'"), message)
        } else {
            XCTFail("name should not exist in main")
        }
        guard case .value(let args) = await session.evaluate("args.length", record: false) else { return XCTFail("args") }
        XCTAssertEqual(args.value, "0")

        // The next stop goes back to the innermost frame.
        XCTAssertEqual(session.selectedFrameIndex, 1)
        session.resume()
        try await Task.sleep(for: .milliseconds(500))
        session.pause()
        try await waitUntilStopped(session)
        XCTAssertEqual(session.selectedFrameIndex, 0)
    }

    func testEvaluateReportsAnUnsupportedExpressionAndRefusesWhileRunning() async throws {
        let session = JavaDebugSession()
        try await start(session)
        defer { session.stop() }

        guard case .failure(let message) = await session.evaluate("box.width + 1") else { return XCTFail("should fail") }
        XCTAssertTrue(message.hasPrefix("Not supported"), message)

        session.resume()
        guard case .failure(let running) = await session.evaluate("name") else { return XCTFail("should fail while running") }
        XCTAssertEqual(running, "The program is not paused.")
    }

    func testStoppingClearsTheHistory() async throws {
        let session = JavaDebugSession()
        try await start(session)
        await session.evaluate("name")
        XCTAssertEqual(session.evaluations.count, 1)
        session.stop()
        XCTAssertTrue(session.evaluations.isEmpty)
    }
}
