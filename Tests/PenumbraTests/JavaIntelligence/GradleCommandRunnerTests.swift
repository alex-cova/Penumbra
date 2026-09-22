import XCTest
@testable import JavaIntelligence

final class GradleCommandRunnerTests: XCTestCase {
    // MARK: - Executable resolution

    func testResolverPrefersExecutableGradlewOverPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutableFile(at: dir.appendingPathComponent("gradlew"))

        let resolver = GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/opt/homebrew/bin/gradle\n"))
        let resolved = try XCTUnwrap(resolver.resolve(projectDirectory: dir))
        XCTAssertEqual(resolved.executable, dir.appendingPathComponent("gradlew"))
        XCTAssertEqual(resolved.leadingArguments, [])
    }

    func testResolverRunsNonExecutableGradlewThroughShell() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrapper = dir.appendingPathComponent("gradlew")
        try "echo hi".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrapper.path)

        let resolver = GradleExecutableResolver(processRunner: FakeProcessRunner(output: ""))
        let resolved = try XCTUnwrap(resolver.resolve(projectDirectory: dir))
        XCTAssertEqual(resolved.executable, URL(fileURLWithPath: "/bin/sh"))
        XCTAssertEqual(resolved.leadingArguments, [wrapper.path])
    }

    func testResolverFallsBackToGradleOnPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/opt/homebrew/bin/gradle\n"))
        let resolved = try XCTUnwrap(resolver.resolve(projectDirectory: dir))
        XCTAssertEqual(resolved.executable, URL(fileURLWithPath: "/opt/homebrew/bin/gradle"))
        XCTAssertEqual(resolved.leadingArguments, [])
    }

    func testResolverReturnsNilWhenNothingFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = GradleExecutableResolver(processRunner: FakeProcessRunner(output: ""))
        XCTAssertNil(resolver.resolve(projectDirectory: dir))
    }

    // MARK: - Trust store

    func testTrustStoreRoundTripsThroughFile() throws {
        let storeURL = try makeTempDir().appendingPathComponent("trust.json")
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let trustedRoot = URL(fileURLWithPath: "/tmp/some-project")
        let declinedRoot = URL(fileURLWithPath: "/tmp/other-project")

        let store = GradleTrustStore(storeURL: storeURL)
        XCTAssertNil(store.decision(for: trustedRoot))
        store.setTrusted(true, for: trustedRoot)
        store.setTrusted(false, for: declinedRoot)

        let reloaded = GradleTrustStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.decision(for: trustedRoot), true)
        XCTAssertTrue(reloaded.isTrusted(trustedRoot))
        XCTAssertEqual(reloaded.decision(for: declinedRoot), false)
        XCTAssertFalse(reloaded.isTrusted(declinedRoot))
    }

    func testTrustStoreTrustOverridesEarlierDecline() {
        let store = GradleTrustStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let root = URL(fileURLWithPath: "/tmp/flip-flop")
        store.setTrusted(false, for: root)
        XCTAssertEqual(store.decision(for: root), false)
        store.setTrusted(true, for: root)
        XCTAssertEqual(store.decision(for: root), true)
    }

    // MARK: - GradleCommandRunner: trust gate + command construction

    func testRunRefusesUntrustedRoot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        let launcher = RecordingLauncher(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = GradleCommandRunner(
            trustStore: store,
            launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/usr/bin/gradle"))
        )

        do {
            _ = try await runner.run(projectDirectory: dir, tasks: ["tasks"], javaHome: nil)
            XCTFail("expected untrusted error")
        } catch GradleCommandError.untrusted(let root) {
            XCTAssertEqual(root, dir)
        }
        let launchCount = await launcher.launchCount
        XCTAssertEqual(launchCount, 0, "launcher should never be invoked for an untrusted root")
    }

    func testRunBuildsCommandWithTasksArgumentsAndJavaHome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutableFile(at: dir.appendingPathComponent("gradlew"))

        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = RecordingLauncher(result: .init(exitCode: 0, stdout: "ok", stderr: ""))
        let runner = GradleCommandRunner(trustStore: store, launcher: launcher, resolver: GradleExecutableResolver())

        let javaHome = URL(fileURLWithPath: "/fake/jdk-21")
        let result = try await runner.run(
            projectDirectory: dir,
            tasks: ["umbraProjectModel"],
            arguments: ["-PoutputFile=/tmp/model.json"],
            javaHome: javaHome
        )
        XCTAssertEqual(result.stdout, "ok")

        let capturedCommand = await launcher.lastCommand
        let command = try XCTUnwrap(capturedCommand)
        XCTAssertEqual(command.executable, dir.appendingPathComponent("gradlew"))
        XCTAssertEqual(command.currentDirectory, dir)
        XCTAssertEqual(command.arguments, ["--console=plain", "-PoutputFile=/tmp/model.json", "umbraProjectModel"])
        XCTAssertEqual(command.environment["JAVA_HOME"], javaHome.path)
    }

    // MARK: - SystemGradleProcessLauncher: real process behavior (no Gradle needed)

    func testSystemLauncherCapturesStdoutStderrAndExitCode() async throws {
        let command = GradleCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'; echo err-marker >&2; exit 3"],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )
        let result = try await SystemGradleProcessLauncher().launch(command, timeout: .seconds(30))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout.count, 300_000, "large stdout should be fully drained, not deadlocked on a full pipe")
        XCTAssertTrue(result.stderr.contains("err-marker"))
    }

    func testSystemLauncherTimesOutAndKillsProcess() async throws {
        let command = GradleCommand(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )
        let start = Date()
        do {
            _ = try await SystemGradleProcessLauncher().launch(command, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch GradleCommandError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 10, "should not wait for the full sleep duration")
        }
    }

    func testSystemLauncherHonorsTaskCancellation() async throws {
        let command = GradleCommand(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )
        let expectation = expectation(description: "cancelled")
        let task = Task {
            do {
                _ = try await SystemGradleProcessLauncher().launch(command, timeout: .seconds(30))
                XCTFail("expected cancellation")
            } catch GradleCommandError.cancelled {
                expectation.fulfill()
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await fulfillment(of: [expectation], timeout: 10)
    }

    func testSystemLauncherThrowsExecutableNotFound() async throws {
        let command = GradleCommand(
            executable: URL(fileURLWithPath: "/does/not/exist/gradlew"),
            arguments: [],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )
        do {
            _ = try await SystemGradleProcessLauncher().launch(command, timeout: .seconds(5))
            XCTFail("expected executableNotFound")
        } catch GradleCommandError.executableNotFound {
            // expected
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutableFile(at url: URL) throws {
        try "#!/bin/sh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct FakeProcessRunner: ProcessRunning {
    let output: String
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        output
    }
}

private actor RecordingLauncher: GradleProcessLaunching {
    private let result: GradleCommandResult
    private(set) var lastCommand: GradleCommand?
    private(set) var launchCount = 0

    init(result: GradleCommandResult) {
        self.result = result
    }

    func launch(_ command: GradleCommand, timeout: Duration) async throws -> GradleCommandResult {
        lastCommand = command
        launchCount += 1
        return result
    }
}
