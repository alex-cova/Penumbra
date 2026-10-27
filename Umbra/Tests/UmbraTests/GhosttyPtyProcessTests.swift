import XCTest
@testable import Umbra

/// PTY contract tests for `GhosttyPtyProcess` (plan Step 3): a real login
/// shell through a real PTY — argv[0], cwd, TERM, window size, SIGHUP
/// semantics, and exactly-once exit reporting.
final class GhosttyPtyProcessTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private(set) var exitCodes: [Int32] = []
        func append(_ data: Data) {
            lock.withLock { buffer.append(data) }
        }
        func recordExit(_ code: Int32) {
            lock.withLock { exitCodes.append(code) }
        }
        func text() -> String {
            lock.withLock { String(decoding: buffer, as: UTF8.self) }
        }
    }

    private var homedir: String!
    private var zdotdir: String!
    private var workdir: String!

    /// Isolated HOME so the developer's zshrc never loads inside test shells.
    private var shellEnv: [String: String] {
        ["ZDOTDIR": zdotdir!, "HOME": homedir!]
    }

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-pty-tests-\(UUID().uuidString)")
        homedir = base.appendingPathComponent("home").path
        zdotdir = homedir!
        workdir = base.appendingPathComponent("work").path
        try? FileManager.default.createDirectory(atPath: homedir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base = zdotdir.map({ ($0 as NSString).deletingLastPathComponent }) {
            try? FileManager.default.removeItem(atPath: base)
        }
        super.tearDown()
    }

    private func startedProcess(
        sink: Sink,
        cwd: String? = nil,
        cols: Int = 80,
        rows: Int = 24
    ) -> GhosttyPtyProcess {
        let process = GhosttyPtyProcess()
        process.onOutput = { [weak sink] in sink?.append($0) }
        process.onExit = { [weak sink] in sink?.recordExit($0) }
        let started = process.start(
            executable: "/bin/zsh",
            execName: "-zsh",
            currentDirectory: cwd ?? workdir!,
            environment: shellEnv,
            cols: cols,
            rows: rows
        )
        XCTAssertTrue(started, "shell must spawn")
        XCTAssertTrue(process.running)
        XCTAssertGreaterThan(process.shellPid, 0)
        return process
    }

    @discardableResult
    private func waitForOutput(_ sink: Sink, containing needle: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.text().contains(needle) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        fputs("TIMEOUT waiting for \(needle.debugDescription); sink tail: \(sink.text().suffix(600).debugDescription)\n", stderr)
        return false
    }

    private func waitForExit(_ sink: Sink, timeout: TimeInterval = 15) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let code = sink.exitCodes.first { return code }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    func testEchoRoundTrip() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        defer { process.terminate() }
        process.write(Data("echo PTY-MARKER-1\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "PTY-MARKER-1"), "shell output missing")
    }

    func testLoginShellArgv0() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        defer { process.terminate() }
        process.write(Data("echo $0\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "-zsh"), "$0 should be the login argv[0]")
    }

    func testCwdPassedThrough() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        defer { process.terminate() }
        process.write(Data("pwd\r".utf8))
        XCTAssertTrue(
            waitForOutput(sink, containing: workdir!),
            "shell should start in the requested directory"
        )
    }

    func testTermSet() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        defer { process.terminate() }
        process.write(Data("echo $TERM\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "xterm-256color"))
    }

    func testStdinIsATty() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        defer { process.terminate() }
        process.write(Data("test -t 0 && echo TTY-YES\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "TTY-YES"), "shell stdin must be a tty")
    }

    func testWindowSizePropagated() {
        let sink = Sink()
        let process = startedProcess(sink: sink, cols: 99, rows: 7)
        defer { process.terminate() }
        process.write(Data("stty size\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "7 99"), "stty should see the PTY window size")
        process.setWindowSize(cols: 100, rows: 30)
        process.write(Data("stty size\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "30 100"), "TIOCSWINSZ must resize the PTY")
    }

    func testExitCommandFiresOnce() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        process.write(Data("exit\r".utf8))
        XCTAssertEqual(waitForExit(sink), 0, "clean shell exit reports code 0")
        XCTAssertFalse(process.running)
        XCTAssertEqual(sink.exitCodes.count, 1, "exit must fire exactly once")
    }

    func testTerminateSendsSIGHUP() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        let pid = process.shellPid
        XCTAssertTrue(waitForOutput(sink, containing: "%"), "shell should reach a prompt")
        process.terminate()
        // Interactive login zsh maps SIGHUP/tty-hangup death to status 1
        // (observed); the contract is death + exactly-once callback.
        XCTAssertEqual(waitForExit(sink), 1, "terminated shell must report")
        XCTAssertFalse(process.running)
        XCTAssertEqual(sink.exitCodes.count, 1, "exit must fire exactly once")
        XCTAssertEqual(kill(pid, 0), -1, "shell process must be gone after terminate")
    }

    func testTerminateEndsForegroundJob() {
        let sink = Sink()
        let process = startedProcess(sink: sink)
        XCTAssertTrue(waitForOutput(sink, containing: "%"), "shell should reach a prompt")
        process.write(Data("sleep 300\r".utf8))
        Thread.sleep(forTimeInterval: 1.0)
        process.terminate()
        XCTAssertNotNil(waitForExit(sink), "shell must exit after terminate with a foreground job")
        XCTAssertFalse(process.running)
    }

    func testDoubleStartAndTerminateBeforeStartAreNoOps() {
        let sink = Sink()
        let process = GhosttyPtyProcess()
        process.onOutput = { [weak sink] in sink?.append($0) }
        process.onExit = { [weak sink] in sink?.recordExit($0) }
        process.terminate()
        XCTAssertTrue(sink.exitCodes.isEmpty, "terminate-before-start must not fire exit")
        XCTAssertTrue(process.start(
            executable: "/bin/zsh",
            execName: "-zsh",
            currentDirectory: workdir!,
            environment: shellEnv
        ))
        let firstPid = process.shellPid
        XCTAssertFalse(
            process.start(
                executable: "/bin/zsh",
                execName: "-zsh",
                currentDirectory: workdir!,
                environment: shellEnv
            ),
            "double start must be a no-op"
        )
        XCTAssertEqual(process.shellPid, firstPid, "double start must keep the original shell")
        process.terminate()
        XCTAssertNotNil(waitForExit(sink))
        process.terminate()
        XCTAssertEqual(sink.exitCodes.count, 1, "second terminate must not refire exit")
    }

    func testPtyOutputFlowsThroughVtParser() {
        let sink = Sink()
        let process = GhosttyPtyProcess()
        process.onOutput = { [weak sink] in sink?.append($0) }
        process.onExit = { [weak sink] in sink?.recordExit($0) }
        XCTAssertTrue(process.start(
            executable: "/bin/zsh",
            execName: "-zsh",
            currentDirectory: workdir!,
            environment: shellEnv
        ))
        defer { process.terminate() }
        // End-to-end serial-queue path: PTY bytes straight into the parser,
        // the way the host view will wire process and terminal together.
        guard let vt = GhosttyVtTerminal(cols: 80, rows: 24) else {
            XCTFail("terminal must be created")
            return
        }
        process.write(Data("echo VT-FLOW-9\r".utf8))
        XCTAssertTrue(waitForOutput(sink, containing: "VT-FLOW-9"))
        vt.write(Data(sink.text().utf8))
        XCTAssertTrue(vt.plainText()?.contains("VT-FLOW-9") ?? false)
    }
}
