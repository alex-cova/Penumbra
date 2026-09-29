import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// The debug console fed by a real JVM through the real adapter. Skips without a JDK and adapter jar.
@MainActor
final class JavaDebugSessionConsoleTests: XCTestCase {
    private var directory: URL!
    private var java: URL!

    override func setUpWithError() throws {
        let jdk = try XCTUnwrap(TestJDK.discovered, "No JDK installed")
        java = jdk.home.appendingPathComponent("bin/java")
        let javac = jdk.home.appendingPathComponent("bin/javac")
        guard FileManager.default.isExecutableFile(atPath: javac.path) else { throw XCTSkip("No javac in the JDK") }
        guard JavaDebugProcessLauncher().adapterJarURL() != nil else { throw XCTSkip("Adapter jar not built") }

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("debug-console-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("Chatty.java")
        try """
        public class Chatty {
            public static void main(String[] args) throws Exception {
                int count = Integer.parseInt(args[0]);
                for (int i = 0; i < count; i++) System.out.println("line " + i);
                System.err.println("trouble");
                System.exit(Integer.parseInt(args[1]));
            }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
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

    private func run(_ session: JavaDebugSession, lines: Int, exitCode: Int) async throws {
        let launch = JavaManagedLaunch(
            javaExecutable: java,
            vmArguments: [],
            classpath: [directory.appendingPathComponent("classes")],
            mainClass: "Chatty",
            programArguments: ["\(lines)", "\(exitCode)"],
            environment: [:],
            jdwpPort: JavaDebugPortPicker.pickPort(preferred: nil),
            suspendOnStart: true
        )
        await session.start(launch: launch, breakpoints: [], sourceRoots: [])
        for _ in 0..<300 {
            if case .terminated = session.state, session.console.chunks.last?.text.hasPrefix("Process finished") == true { return }
            if case .failed(let message) = session.state { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("the program never finished: \(session.state)")
    }

    func testTheConsoleFillsFromTheProgramAndEndsWithItsExitCode() async throws {
        let session = JavaDebugSession()
        try await run(session, lines: 50, exitCode: 4)

        let chunks = session.console.chunks
        XCTAssertEqual(chunks.first?.stream, .note)
        XCTAssertEqual(chunks.first?.text, "Launching Chatty…")
        let out = chunks.filter { $0.stream == .out && $0.text.hasPrefix("line ") }.map(\.text)
        XCTAssertEqual(out, (0..<50).map { "line \($0)" })
        XCTAssertEqual(chunks.filter { $0.stream == .err }.map(\.text), ["trouble"])
        XCTAssertEqual(chunks.last?.stream, .note)
        XCTAssertEqual(chunks.last?.text, "Process finished with exit code 4")
        XCTAssertTrue(session.console.hasUnread)
    }

    func testAHugeOutputStaysBoundedAndCountsWhatWasDropped() async throws {
        let session = JavaDebugSession()
        let lines = IDEDebugConsoleLog.maxChunks + IDEDebugConsoleLog.trimSlack + 1_500
        try await run(session, lines: lines, exitCode: 0)

        let console = session.console
        XCTAssertLessThanOrEqual(console.chunks.count, IDEDebugConsoleLog.maxChunks + IDEDebugConsoleLog.trimSlack)
        XCTAssertGreaterThan(console.droppedCount, 0)
        XCTAssertEqual(console.chunks.first?.sequence, console.droppedCount)
        let lastLine = console.chunks.last { $0.text.hasPrefix("line ") }
        XCTAssertEqual(lastLine?.text, "line \(lines - 1)", "The newest output is what is kept")
        XCTAssertEqual(console.chunks.last?.text, "Process finished with exit code 0")
    }

    func testStartingAgainClearsTheConsole() async throws {
        let session = JavaDebugSession()
        try await run(session, lines: 5, exitCode: 0)
        let firstRun = session.console.runID
        try await run(session, lines: 2, exitCode: 1)

        XCTAssertNotEqual(session.console.runID, firstRun)
        let out = session.console.chunks.filter { $0.text.hasPrefix("line ") }.map(\.text)
        XCTAssertEqual(out, ["line 0", "line 1"], "Nothing from the first run is left")
        XCTAssertEqual(session.console.chunks.last?.text, "Process finished with exit code 1")
    }

    func testAGradleAttachSessionSaysWhereItsOutputIs() async throws {
        let session = JavaDebugSession()
        try await session.prepareAdapter(javaHome: java.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(session.console.chunks.map(\.text), ["The program's output is in the Gradle tab."])
        session.stop()
    }
}
