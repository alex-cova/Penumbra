import JavaIntelligence
import XCTest
@testable import Umbra

/// The Run tool window's session against a stand-in for `java`: a shell script in a throwaway JDK
/// home, so the pipes, input, exit codes and Stop are the real thing without needing a JDK.
@MainActor
final class IDERunSessionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("run-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("jdk/bin"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A launch whose "java" runs `script`.
    private func launch(_ script: String, redirectInput: URL? = nil) throws -> JavaProcessLaunch {
        let java = scratch.appendingPathComponent("jdk/bin/java")
        try "#!/bin/sh\n\(script)\n".write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        return JavaProcessLaunch(
            executable: java, arguments: [], workingDirectory: scratch,
            environment: ["PATH": "/usr/bin:/bin"], redirectInput: redirectInput, displayCommand: "java"
        )
    }

    private func makeSession() -> IDERunSession {
        IDERunSession(configuration: JavaRunConfiguration(name: "Demo", target: .singleFile(path: "/x/Demo.java")))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testOutputErrorsAndTheExitCodeAreRecorded() async throws {
        let session = makeSession()
        session.start(try launch("echo out; echo oops >&2; exit 3"))
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.state, .exited(3))
        let segments = session.log.segments
        XCTAssertTrue(segments.contains { $0.stream == .stdout && $0.text.contains("out") })
        XCTAssertTrue(segments.contains { $0.stream == .stderr && $0.text.contains("oops") })
        XCTAssertTrue(segments.last?.text.contains("exit code 3") == true)
        XCTAssertNotNil(session.finishedAt)
        XCTAssertFalse(session.acceptsInput)
    }

    func testAPromptWithoutANewlineShowsAndTypedInputIsEchoedAndSent() async throws {
        let session = makeSession()
        session.start(try launch(#"printf 'Name: '; read name; echo "Hello, $name!""#))
        let prompted = await waitUntil { session.log.plainText.contains("Name: ") }
        XCTAssertTrue(prompted, "a half-written line is shown while the program waits")
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.acceptsInput)

        session.sendInput("Ada")
        let greeted = await waitUntil { session.log.plainText.contains("Hello, Ada!") }
        XCTAssertTrue(greeted)
        XCTAssertTrue(session.log.segments.contains { $0.stream == .input && $0.text == "Ada\n" })
        _ = await waitUntil { !session.isActive }
        XCTAssertEqual(session.state, .exited(0))
    }

    func testClosingInputLetsAProgramThatReadsToTheEndFinish() async throws {
        let session = makeSession()
        session.start(try launch("cat >/dev/null; echo done"))
        session.sendInput("one")
        session.closeInput()
        XCTAssertFalse(session.acceptsInput)
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended)
        XCTAssertTrue(session.log.plainText.contains("done"))
    }

    func testStopEndsAProgramThatIsWaiting() async throws {
        let session = makeSession()
        session.start(try launch("echo started; sleep 30"))
        _ = await waitUntil { session.log.plainText.contains("started") }
        let begun = Date()
        session.stop()
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended)
        XCTAssertLessThan(Date().timeIntervalSince(begun), 5)
        guard case .stopped = session.state else { return XCTFail("expected stopped, got \(session.state)") }
        XCTAssertTrue(session.log.plainText.contains("Process stopped"))
    }

    func testStopReachesWhatTheProgramStarted() async throws {
        let pidFile = scratch.appendingPathComponent("child.pid")
        let session = makeSession()
        session.start(try launch("sleep 60 & echo $! > '\(pidFile.path)'; wait"))
        _ = await waitUntil { (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty == false }
        let child = try XCTUnwrap(pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0)
        session.stop()
        _ = await waitUntil { !session.isActive }
        let gone = await waitUntil { kill(child, 0) != 0 }
        XCTAssertTrue(gone, "the program's own child must not outlive Stop")
    }

    func testStoppingBeforeItStartedEndsThePreparingSession() {
        let session = makeSession()
        XCTAssertEqual(session.state, .preparing)
        session.stop()
        XCTAssertEqual(session.state, .stopped(nil))
        XCTAssertTrue(session.wasStopped)
        session.stop()  // a second Stop is harmless
    }

    func testAFailureBeforeTheProgramStartsIsShownInTheConsole() {
        let session = makeSession()
        session.fail("No JDK found")
        XCTAssertEqual(session.state, .failed("No JDK found"))
        XCTAssertTrue(session.log.plainText.contains("No JDK found"))
        session.fail("again")  // only the first reason counts
        XCTAssertEqual(session.state, .failed("No JDK found"))
    }

    func testRedirectedInputIsFedToTheProgram() async throws {
        let input = scratch.appendingPathComponent("in.txt")
        try "first\nsecond\n".write(to: input, atomically: true, encoding: .utf8)
        let session = makeSession()
        session.start(try launch(#"while read l; do echo "line:$l"; done"#, redirectInput: input))
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended)
        XCTAssertTrue(session.log.plainText.contains("line:first"))
        XCTAssertTrue(session.log.plainText.contains("line:second"))
        XCTAssertEqual(session.state, .exited(0))
    }

    func testAnArgFileIsDeletedWhenTheRunEnds() async throws {
        let argFile = scratch.appendingPathComponent("umbra.args")
        try "-cp x".write(to: argFile, atomically: true, encoding: .utf8)
        var launch = try launch("exit 0")
        launch.temporaryFiles = [argFile]
        let session = makeSession()
        session.start(launch)
        _ = await waitUntil { !session.isActive }
        XCTAssertFalse(FileManager.default.fileExists(atPath: argFile.path))
    }

    func testAMissingExecutableFailsInsteadOfThrowing() {
        let session = makeSession()
        session.start(JavaProcessLaunch(
            executable: scratch.appendingPathComponent("jdk/bin/nothing"), arguments: [], workingDirectory: scratch, environment: [:]
        ))
        guard case .failed = session.state else { return XCTFail("expected failed, got \(session.state)") }
    }

    func testMultibyteTextSplitAcrossReadsIsDecodedWhole() async throws {
        let session = makeSession()
        // printf writes the three bytes of "€" one at a time.
        session.start(try launch(#"printf '\342'; sleep 0.1; printf '\202'; sleep 0.1; printf '\254'; echo"#))
        _ = await waitUntil { !session.isActive }
        XCTAssertTrue(session.log.plainText.contains("€"), session.log.plainText)
        XCTAssertFalse(session.log.plainText.contains("\u{FFFD}"))
    }

    // MARK: - Log and list

    func testTheLogDropsOldChunksPastItsLimitButKeepsTheNewest() {
        var log = IDERunConsoleLog()
        let big = String(repeating: "x", count: IDERunConsoleLog.maxCharacters / 2 + 1)
        log.append(big, stream: .stdout)
        log.append(big, stream: .stdout)
        XCTAssertEqual(log.droppedCount, 1)
        XCTAssertEqual(log.segments.count, 1)
        XCTAssertEqual(log.totalCount, 2)
        log.append(String(repeating: "y", count: IDERunConsoleLog.maxCharacters * 2), stream: .stderr)
        XCTAssertEqual(log.segments.count, 1, "an oversized newest chunk is kept whole")
        let before = log.generation
        log.clear()
        XCTAssertNotEqual(log.generation, before)
        XCTAssertTrue(log.isEmpty)
    }

    func testARerunTakesTheTabOfTheRunItReplaces() {
        let runs = IDERunSessions()
        let a = makeSession()
        let b = IDERunSession(configuration: JavaRunConfiguration(name: "Other", target: .singleFile(path: "/x/O.java")))
        runs.add(a)
        runs.add(b)
        let again = makeSession()
        runs.add(again, replacing: a)
        XCTAssertEqual(runs.sessions.map(\.id), [again.id, b.id])
        XCTAssertEqual(runs.selected?.id, again.id)
    }

    func testFinishedSessionsAreTrimmedButRunningOnesNever() {
        let runs = IDERunSessions()
        let running = makeSession()
        runs.add(running)
        for _ in 0..<(IDERunSessions.maxFinished + 4) {
            let done = makeSession()
            done.fail("x")
            runs.add(done)
        }
        XCTAssertTrue(runs.sessions.contains { $0.id == running.id })
        XCTAssertEqual(runs.sessions.filter { !$0.isActive }.count, IDERunSessions.maxFinished)
    }

    func testClosingARunningSessionStopsIt() {
        let runs = IDERunSessions()
        let session = makeSession()
        runs.add(session)
        runs.close(session.id)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(runs.hasContent)
        XCTAssertNil(runs.selected)
    }

    func testTwoRunsOfOneConfigurationAreNumbered() {
        let runs = IDERunSessions()
        let first = makeSession()
        let second = makeSession()
        runs.add(first)
        runs.add(second)
        XCTAssertEqual(runs.title(for: first), "Demo")
        XCTAssertEqual(runs.title(for: second), "Demo (2)")
        XCTAssertEqual(runs.latest(forConfiguration: second.configurationID)?.id, second.id)
    }
}
