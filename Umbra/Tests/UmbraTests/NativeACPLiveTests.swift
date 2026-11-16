import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
private final class LiveNativeHost: IDEAgentHost {
    var agentProjectRoot: URL?
    let environment: [String: String]
    init(root: URL?, environment: [String: String]) { agentProjectRoot = root; self.environment = environment }
    func agentUnsavedBuffers() -> [String: String] { [:] }
    func agentEditorContext() -> String { "[Editor state]\n[End editor state]" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {}
    func agentCreateFile(relativePath: String, contents: String) async throws {}
    func agentTrashFile(relativePath: String) async throws {}
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { environment }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome { .notStarted("no") }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}

/// The real Kiro, Cursor and Muse CLIs, found the way Umbra finds them (login `PATH` plus the
/// installers' folders, Cursor's identity check). Opt-in:
///
/// - `UMBRA_LIVE_ACP_NATIVE=1`: `initialize` and `session/new` in a temporary folder. Free: no prompt
///   is sent. Passes on a verified state, "connected" or "authentication required".
/// - `UMBRA_LIVE_ACP_NATIVE_PROMPT=1` as well: one short prompt per signed-in agent through a real
///   chat, in Plan mode. This uses the provider account and may count against its quota.
///
/// A CLI that is not installed is skipped by name, never reported as passing.
@MainActor
final class NativeACPLiveTests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        try XCTSkipUnless(Self.env["UMBRA_LIVE_ACP_NATIVE"] == "1",
                          "Starts the real Kiro, Cursor and Muse CLIs; set UMBRA_LIVE_ACP_NATIVE=1 to run")
    }

    private func environment() async -> [String: String] {
        AgentCommandEnvironment.make(javaHome: nil, loginPath: await IDELoginShellPath.shared.entries())
    }

    private func launch(_ presetID: String, environment: [String: String]) throws -> (IDEACPDefinition, IDEACPResolvedLaunch) {
        let preset = try XCTUnwrap(IDEACPRegistry.preset(id: presetID))
        let definition = IDEACPDefinition(
            name: preset.name, command: preset.recordedLauncher.command, args: preset.recordedLauncher.args,
            presetID: presetID, launchMode: .auto)
        switch IDEACPLaunchResolver.resolve(
            definition: definition, entry: definition.adapterEntry, active: nil, pathValue: environment["PATH"] ?? "")
        {
        case .launch(let launch): return (definition, launch)
        case .unavailable(let reason): throw XCTSkip("\(preset.name): \(reason.message)")
        }
    }

    private func handshake(_ presetID: String) async throws {
        let environment = await environment()
        let (definition, launch) = try launch(presetID, environment: environment)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-native-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let phase = await IDEACPConnectionTest.run(
            definition: definition, launch: launch, workingDirectory: folder, environment: environment,
            leases: nil, timeout: .seconds(60))
        print("NATIVE-ACP \(presetID) \(launch.executable) → \(phase)")
        switch phase {
        case .connected(let version, _, _): XCTAssertEqual(version, 1)
        case .authenticationRequired: break
        case .running, .failed: XCTFail("\(presetID): \(phase)")
        }
    }

    func testKiroHandshake() async throws { try await handshake("kiro") }
    func testCursorHandshake() async throws { try await handshake("cursor") }
    func testMuseHandshake() async throws { try await handshake("muse") }

    private func prompt(_ presetID: String) async throws {
        try XCTSkipUnless(Self.env["UMBRA_LIVE_ACP_NATIVE_PROMPT"] == "1",
                          "Sends a prompt on the provider account; set UMBRA_LIVE_ACP_NATIVE_PROMPT=1 to run")
        let environment = await environment()
        _ = try launch(presetID, environment: environment)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-native-live-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.acp.native.live.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let row = settings.materializePreset(try XCTUnwrap(IDEACPRegistry.preset(id: presetID)))
        settings.setACPAllowed(true, agentID: row.id)
        settings.acpActiveAgentID = row.id
        let host = LiveNativeHost(root: root, environment: environment)
        let chat = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        chat.host = host
        defer { chat.teardown() }
        chat.setMode(.plan)
        chat.submit(text: "Reply with the single word READY and nothing else. Do not use any tools.")
        let done = await acpWaitUntil(180) { !chat.isRunning && chat.entries.contains { $0.kind == .assistant || $0.kind == .error } }
        let transcript = chat.entries.map { "\($0.kind):\($0.text.prefix(200))" }.joined(separator: " | ")
        print("NATIVE-ACP-PROMPT \(presetID) \(chat.acpLiveState) models=\(chat.acpAvailableModels.count) modes=\(chat.acpAvailableModes.map(\.id)) options=\(chat.acpConfigOptions.map(\.id)) :: \(transcript)")
        XCTAssertTrue(done, transcript)
        if case .authenticationRequired = chat.acpLiveState { throw XCTSkip("\(presetID) is signed out: \(transcript)") }
        let reply = chat.entries.filter { $0.kind == .assistant }.map(\.text).joined()
        XCTAssertTrue(reply.uppercased().contains("READY"), transcript)
    }

    func testKiroPrompt() async throws { try await prompt("kiro") }
    func testCursorPrompt() async throws { try await prompt("cursor") }
    func testMusePrompt() async throws { try await prompt("muse") }
}
