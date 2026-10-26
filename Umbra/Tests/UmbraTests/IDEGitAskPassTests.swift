import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// The credential channel between a git child process and the app: prompt classification, the
/// socket protocol with its token and session checks, and the environment git is started with.
final class IDEGitAskPassTests: XCTestCase {
    private var sessions: [String] = []

    override func tearDown() {
        for session in sessions { IDEGitAskPassServer.shared.unregister(session: session) }
        sessions = []
    }

    private func register(_ handler: @escaping IDEGitAskPassServer.Handler) -> String {
        let session = "test-\(UUID().uuidString)"
        sessions.append(session)
        IDEGitAskPassServer.shared.register(session: session, handler: handler)
        XCTAssertTrue(IDEGitAskPassServer.shared.startIfNeeded())
        return session
    }

    /// The helper side blocks, so tests run it off the cooperative pool.
    private func ask(_ request: IDEGitAskPassRequest) async -> IDEGitAskPassReply? {
        let path = IDEGitAskPassServer.shared.socketPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: IDEGitAskPassClient.ask(request, socketPath: path))
            }
        }
    }

    func testPromptsAreClassifiedByTheirWording() {
        XCTAssertEqual(IDEGitCredentialPromptKind.classify("Username for 'https://github.com': "), .username)
        XCTAssertEqual(IDEGitCredentialPromptKind.classify("Password for 'https://me@github.com': "), .secret)
        XCTAssertEqual(IDEGitCredentialPromptKind.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': "), .secret)
        XCTAssertEqual(
            IDEGitCredentialPromptKind.classify("The authenticity of host 'h' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "),
            .confirmation)
        XCTAssertEqual(IDEGitCredentialPromptKind.classify("Something else: "), .text)
    }

    func testAnAnswerTravelsFromTheHandlerToTheHelper() async throws {
        let seen = Box<String>()
        let session = register { prompt in
            seen.value = prompt
            return IDEGitAskPassReply(answer: "hunter2", cancelled: false)
        }

        let reply = await ask(IDEGitAskPassRequest(
            token: IDEGitAskPassServer.shared.token, session: session, prompt: "Password for 'https://x@h': "))

        XCTAssertEqual(reply, IDEGitAskPassReply(answer: "hunter2", cancelled: false))
        XCTAssertEqual(seen.value, "Password for 'https://x@h': ")
    }

    func testAWrongTokenOrAnUnknownSessionIsCancelledWithoutAskingAnyone() async throws {
        let asked = Box<Bool>()
        let session = register { _ in
            asked.value = true
            return IDEGitAskPassReply(answer: "x", cancelled: false)
        }

        let badToken = await ask(IDEGitAskPassRequest(token: "wrong", session: session, prompt: "Password: "))
        let unknown = await ask(IDEGitAskPassRequest(
            token: IDEGitAskPassServer.shared.token, session: "no-such-session", prompt: "Password: "))

        XCTAssertEqual(badToken, .cancel)
        XCTAssertEqual(unknown, .cancel)
        XCTAssertNil(asked.value)
    }

    func testTheHelperPrintsTheAnswerAndExitsZero() async throws {
        let session = register { _ in IDEGitAskPassReply(answer: "s3cret", cancelled: false) }
        let environment = [
            IDEGitAskPassEnvironment.socket: IDEGitAskPassServer.shared.socketPath,
            IDEGitAskPassEnvironment.token: IDEGitAskPassServer.shared.token,
            IDEGitAskPassEnvironment.session: session
        ]

        let (status, printed) = await runHelper(arguments: ["Umbra", "Password for", "'https://h':"], environment: environment)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(printed, "s3cret\n")
    }

    func testACancelledPromptMakesTheHelperExitOne() async throws {
        let session = register { _ in .cancel }
        let environment = [
            IDEGitAskPassEnvironment.socket: IDEGitAskPassServer.shared.socketPath,
            IDEGitAskPassEnvironment.token: IDEGitAskPassServer.shared.token,
            IDEGitAskPassEnvironment.session: session
        ]

        let (status, printed) = await runHelper(arguments: ["Umbra", "Password: "], environment: environment)

        XCTAssertEqual(status, 1)
        XCTAssertEqual(printed, "")
    }

    func testAMisconfiguredHelperExitsTwoAndAnUnreachableAppExitsOne() async {
        let (missing, _) = await runHelper(arguments: ["Umbra", "x"], environment: [:])
        XCTAssertEqual(missing, 2)
        let (unreachable, _) = await runHelper(arguments: ["Umbra", "x"], environment: [
            IDEGitAskPassEnvironment.socket: "/tmp/umbra-no-such-socket",
            IDEGitAskPassEnvironment.token: "t"
        ])
        XCTAssertEqual(unreachable, 1)
    }

    func testTheEnvironmentPointsGitAndSshAtTheHelper() throws {
        let environment = IDEGitAskPassServer.shared.environment(session: "abc")
        let variables = environment.variables
        XCTAssertEqual(variables["GIT_ASKPASS"], Bundle.main.executableURL?.path)
        XCTAssertEqual(variables["SSH_ASKPASS"], variables["GIT_ASKPASS"])
        XCTAssertEqual(variables["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(variables["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(variables[IDEGitAskPassEnvironment.session], "abc")
        XCTAssertFalse(environment.failsInsteadOfPrompting, "the helper answers, so ssh must not be forced into batch mode")
    }

    func testTheSocketIsOnlyReachableByTheUser() throws {
        XCTAssertTrue(IDEGitAskPassServer.shared.startIfNeeded())
        let path = IDEGitAskPassServer.shared.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// Git runs `$GIT_ASKPASS <prompt>` and reads stdout. This pins that contract on this machine's git
    /// with a stand-in helper (a shell script), so the argument handling above matches what git sends.
    func testGitPassesThePromptAsTheOnlyArgument() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askpass-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("prompts.txt")
        let script = directory.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(log.path)'\nprintf 'answer\\n'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = try await SystemGitRunner().run(
            ["-c", "credential.helper=", "credential", "fill"], in: directory,
            stdin: Data("protocol=https\nhost=example.com\n\n".utf8),
            environment: ["GIT_ASKPASS": script.path, "GIT_TERMINAL_PROMPT": "0"])

        XCTAssertTrue(output.text.contains("username=answer"), output.text)
        XCTAssertTrue(output.text.contains("password=answer"), output.text)
        let prompts = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(IDEGitCredentialPromptKind.classify(prompts[0]), .username, prompts[0])
        XCTAssertEqual(IDEGitCredentialPromptKind.classify(prompts[1]), .secret, prompts[1])
    }

    // MARK: - Helpers

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func runHelper(arguments: [String], environment: [String: String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var printed = ""
                let status = IDEGitAskPassClient.run(arguments: arguments, environment: environment) { printed += $0 }
                continuation.resume(returning: (status, printed))
            }
        }
    }
}
