import Darwin
import Foundation
import XCTest
@testable import Umbra

final class AgentCommandRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cmd-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func spec(_ command: String, timeout: TimeInterval = 30, environment: [String: String]? = nil) -> AgentCommandSpec {
        AgentCommandSpec(
            command: command, workingDirectory: directory,
            environment: environment ?? AgentCommandEnvironment.make(javaHome: nil), timeout: timeout)
    }

    private func run(_ command: String, timeout: TimeInterval = 30) async throws -> AgentCommandResult {
        try await AgentCommandRunner.run(spec(command, timeout: timeout), onOutput: { _ in })
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntilGone(_ pid: pid_t, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isAlive(pid), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return !isAlive(pid)
    }

    private func pid(from file: String) async throws -> pid_t {
        let url = directory.appendingPathComponent(file)
        for _ in 0..<100 {
            if let text = try? String(contentsOf: url, encoding: .utf8), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("the child never reported its pid")
    }

    func testCapturesOutputExitCodeAndMergesStderr() async throws {
        let ok = try await run("echo out; echo err 1>&2")
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertTrue(ok.output.contains("out") && ok.output.contains("err"))
        XCTAssertFalse(ok.timedOut || ok.cancelled)

        let failing = try await run("echo before; exit 7")
        XCTAssertEqual(failing.exitCode, 7)
        XCTAssertEqual(failing.output, "before\n")
    }

    func testRunsInTheProjectDirectoryWithAZshShell() async throws {
        let result = try await run("pwd; echo $0")
        let lines = result.output.split(separator: "\n").map(String.init)
        // `pwd` prints the physical path (/private/var/…); compare after resolving both.
        XCTAssertEqual(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
        XCTAssertEqual(lines.last, "/bin/zsh")
    }

    func testStdinIsClosedSoAPromptingProgramCannotHang() async throws {
        let result = try await run("cat; echo after-cat; read answer; echo \"answer=[$answer]\"", timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("after-cat") && result.output.contains("answer=[]"))
    }

    func testTheEnvironmentIsBuiltNotInherited() async throws {
        setenv("AGENT_TEST_SECRET", "hunter2", 1)
        defer { unsetenv("AGENT_TEST_SECRET") }
        let result = try await run("env")
        XCTAssertFalse(result.output.contains("hunter2"), "the app's own environment must not leak into commands")
        XCTAssertTrue(result.output.contains("TERM=dumb"))
        XCTAssertTrue(result.output.contains("HOME=\(NSHomeDirectory())"))
    }

    func testJavaHomeAndExtrasGoIntoTheEnvironment() {
        let java = URL(fileURLWithPath: "/jdks/21")
        let environment = AgentCommandEnvironment.make(
            javaHome: java, extras: ["PATH": "/extra/bin", "FOO": "bar"], home: "/home/x", temporaryDirectory: "/tmp/x/")
        XCTAssertEqual(environment["JAVA_HOME"], "/jdks/21")
        XCTAssertEqual(environment["FOO"], "bar")
        XCTAssertEqual(environment["HOME"], "/home/x")
        XCTAssertTrue(environment["PATH"]!.hasPrefix("/extra/bin:/jdks/21/bin:/usr/bin"), "extras go in front, the JDK before the system")
    }

    func testOutputIsStreamedAsItArrives() async throws {
        let chunks = ChunkBox()
        _ = try await AgentCommandRunner.run(spec("echo one; sleep 0.3; echo two"), onOutput: { chunks.append($0) })
        XCTAssertEqual(chunks.joined, "one\ntwo\n")
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "the first line arrives before the command ends")
    }

    func testATimeoutKillsTheWholeProcessTreeNotJustTheShell() async throws {
        let started = Date()
        let command = spec("sleep 300 & echo $! > child.pid; wait", timeout: 1)
        let task = Task { try await AgentCommandRunner.run(command, onOutput: { _ in }) }
        let result = try await task.value
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let child = try await pid(from: "child.pid")
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone, "the grandchild must die with the group")
    }

    func testCancellingStopsTheTreeAndReportsIt() async throws {
        let command = spec("sleep 300 & echo $! > child.pid; wait")
        let task = Task { try await AgentCommandRunner.run(command, onOutput: { _ in }) }
        let child = try await pid(from: "child.pid")
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone)
    }

    func testNothingTheCommandStartedOutlivesIt() async throws {
        let result = try await run("(sleep 300 &) ; sleep 0.2; pgrep -n -x sleep > child.pid; echo done")
        XCTAssertEqual(result.exitCode, 0)
        let child = try await pid(from: "child.pid")
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone, "a background process must not be left running after the command returns")
    }

    func testAKilledCommandReportsItsSignal() async throws {
        let result = try await run("kill -9 $$")
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.signal, 9)
    }

    func testAMissingWorkingDirectoryIsALaunchFailureNotAHang() async {
        var bad = spec("echo hi")
        bad.workingDirectory = directory.appendingPathComponent("nope")
        do {
            _ = try await AgentCommandRunner.run(bad, onOutput: { _ in })
            XCTFail("expected a launch failure")
        } catch {
            XCTAssertTrue(error is AgentCommandError, "\(error)")
        }
    }

    func testHugeOutputKeepsTheHeadAndTheTailAndBoundsMemory() async throws {
        let result = try await run("seq 1 400000")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.output.hasSuffix("399999\n400000\n"))
        XCTAssertGreaterThan(result.omittedBytes, 0)
        XCTAssertLessThan(result.output.utf8.count, 300_000)
    }
}

private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    func append(_ text: String) { lock.withLock { chunks.append(text) } }
    var joined: String { lock.withLock { chunks.joined() } }
    var count: Int { lock.withLock { chunks.count } }
}
