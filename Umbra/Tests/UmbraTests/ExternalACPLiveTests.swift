import AgentKit
import Foundation
import XCTest
@testable import Umbra

/// Real Codex and Claude Code ACP sessions through the agent panel's conversation controller.
/// Skipped unless `UMBRA_LIVE_ACP=1` and the isolated adapter binaries are present, so the
/// default suite does not download, spawn, or contact a model.
@MainActor
final class ExternalACPLiveTests: XCTestCase {
    private let prefix = "/tmp/umbra-acp-adapters/prefix/node_modules/.bin"
    private let codexCLI = "/opt/homebrew/bin/codex"
    private let claudeCLI = "/Users/alex/.local/bin/claude"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_LIVE_ACP"] == "1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "\(prefix)/codex-acp"))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "\(prefix)/claude-agent-acp"))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: codexCLI))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: claudeCLI))
    }

    func testBothAdaptersCompleteSessionsThroughTheAgentPanel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-acp-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "seed\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let defaults = UserDefaults(suiteName: "umbra.acp.live.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .mlx
        settings.addACPAgent(name: "Codex", commandLine: "\(prefix)/codex-acp")
        settings.addACPAgent(name: "Claude Code", commandLine: "\(prefix)/claude-agent-acp")
        let codexID = try XCTUnwrap(settings.acpAgents.first { $0.command.hasSuffix("codex-acp") }?.id)
        let claudeID = try XCTUnwrap(settings.acpAgents.first { $0.command.hasSuffix("claude-agent-acp") }?.id)
        settings.acpAgents[settings.acpAgents.firstIndex { $0.id == codexID }!].env["CODEX_PATH"] = codexCLI
        settings.acpAgents[settings.acpAgents.firstIndex { $0.id == claudeID }!].env["CLAUDE_CODE_EXECUTABLE"] = claudeCLI
        settings.setACPAllowed(true, agentID: codexID)
        settings.setACPAllowed(true, agentID: claudeID)
        settings.acpActiveAgentID = codexID

        let codexDefinition = try XCTUnwrap(settings.acpAgents.first { $0.id == codexID })
        let claudeDefinition = try XCTUnwrap(settings.acpAgents.first { $0.id == claudeID })
        XCTAssertNotNil(codexDefinition.resolvedExecutable(pathValue: ""))
        XCTAssertNotNil(claudeDefinition.resolvedExecutable(pathValue: ""))
        XCTAssertEqual(availability(codexDefinition, settings: settings, live: false), .installed)
        XCTAssertEqual(availability(claudeDefinition, settings: settings, live: false), .installed)
        let binPath = prefix
        let codexPreset = try XCTUnwrap(IDEACPRegistry.preset(id: "codex"))
        let claudePreset = try XCTUnwrap(IDEACPRegistry.preset(id: "claude-code"))
        XCTAssertEqual(codexPreset.preferredLaunch(pathValue: binPath).command, "codex-acp")
        XCTAssertFalse(codexPreset.preferredLaunch(pathValue: binPath).downloadsPackage)
        XCTAssertEqual(
            IDEACPDefinition(name: "Codex", command: "codex-acp").resolvedExecutable(pathValue: binPath),
            "\(binPath)/codex-acp")
        XCTAssertEqual(claudePreset.preferredLaunch(pathValue: binPath).command, "claude-agent-acp")
        XCTAssertFalse(claudePreset.preferredLaunch(pathValue: binPath).downloadsPackage)
        XCTAssertEqual(
            IDEACPDefinition(name: "Claude Code", command: "claude-agent-acp").resolvedExecutable(pathValue: binPath),
            "\(binPath)/claude-agent-acp")

        print("LIVE workspace \(root.path)")
        let controller = IDEAgentController(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let host = LiveACPHost(root: root)
        controller.attach(host: host)
        let codexChat = controller.selected
        XCTAssertEqual(codexChat.resolvedACPAgentID, codexID)

        print("LIVE codex ping")
        codexChat.submit(text: "Reply with exactly the single word PONG. Do not use tools.")
        let codexStreamed = await finish(codexChat, timeout: 180)
        XCTAssertFalse(codexChat.isRunning)
        let codexAnswer = assistantText(codexChat)
        XCTAssertTrue(codexAnswer.contains("PONG"), codexAnswer)
        XCTAssertEqual(codexChat.acpLiveState, .connected)
        XCTAssertEqual(availability(codexDefinition, settings: settings, live: true), .connected)

        print("LIVE codex write streamed=\(codexStreamed) answer=\(codexAnswer.prefix(80))")
        codexChat.submit(text: "Create a file named hello.txt in the current workspace containing exactly hello-from-acp and a trailing newline. Do not modify any other file. Do not use the network.")
        let codexWriteStreamed = await finish(codexChat, timeout: 240)
        XCTAssertTrue(codexStreamed || codexWriteStreamed, "Codex should show assistant text while the turn is still running")
        XCTAssertFalse(codexChat.isRunning)
        let hello = root.appendingPathComponent("hello.txt")
        XCTAssertEqual(try String(contentsOf: hello, encoding: .utf8), "hello-from-acp\n")
        let codexTools = codexChat.entries.compactMap { entry -> String? in
            if case .toolCall(let name) = entry.kind { return name }
            return nil
        }
        XCTAssertFalse(codexTools.isEmpty, "Codex should execute a tool, entries: \(codexChat.entries.map(\.kind))")
        let codexChanges = codexChat.entries.filter { $0.kind == .changes }.flatMap(\.fileChanges)
        XCTAssertTrue(codexChanges.contains { $0.path == "hello.txt" && $0.original == nil }, "diff card paths: \(codexChanges.map(\.path))")

        print("LIVE codex cancel")
        let toolsBeforeCancel = codexChat.entries.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }.count
        let cancelStarted = Date()
        codexChat.submit(text: "Run the shell command `sleep 20` in this workspace, then reply DONE. Do not edit files.")
        var didStop = false
        let cancelDeadline = Date().addingTimeInterval(90)
        while Date() < cancelDeadline && codexChat.isRunning {
            approvePending(codexChat)
            let toolCount = codexChat.entries.filter {
                if case .toolCall = $0.kind { return true }
                return false
            }.count
            // Stop once this turn's tool has started. If the model never calls one, stop the prompt anyway.
            if !didStop, toolCount > toolsBeforeCancel || Date().timeIntervalSince(cancelStarted) > 25 {
                codexChat.stop()
                didStop = true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(codexChat.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 70)
        XCTAssertTrue(codexChat.entries.contains { $0.kind == .notice && $0.text == "Stopped." }, "\(codexChat.entries.map { "\($0.kind):\($0.text.prefix(80))" })")

        print("LIVE codex restore")
        codexChat.restartACP()
        codexChat.submit(text: "Reply with exactly the single word RESTORED. Do not use tools.")
        _ = await finish(codexChat, timeout: 180)
        XCTAssertTrue(codexChat.entries.contains { $0.text.contains("Restored the remote session") }, "\(codexChat.entries.map(\.text))")
        XCTAssertTrue(assistantText(codexChat).contains("RESTORED"), assistantText(codexChat))
        XCTAssertEqual(codexChat.entries.filter { $0.kind == .user && $0.text.contains("PONG") }.count, 1)

        controller.selectProvider(.agent(claudeID))
        let claudeChat = controller.selected
        XCTAssertNotEqual(claudeChat.id, codexChat.id)
        XCTAssertEqual(claudeChat.resolvedACPAgentID, claudeID)
        XCTAssertFalse(claudeChat.entries.contains { $0.kind == .user })
        XCTAssertEqual(codexChat.resolvedACPAgentID, codexID)

        print("LIVE claude ping")
        claudeChat.submit(text: "Reply with exactly the single word PING. Do not use tools.")
        let claudeStreamed = await finish(claudeChat, timeout: 180)
        XCTAssertFalse(claudeChat.isRunning)
        if claudeChat.entries.contains(where: { $0.kind == .error }) {
            let error = claudeChat.entries.filter { $0.kind == .error }.map(\.text).joined(separator: "\n")
            XCTFail("Claude Code ACP did not complete the prompt: \(error)")
            return
        }
        XCTAssertTrue(assistantText(claudeChat).contains("PING"), assistantText(claudeChat))
        XCTAssertEqual(claudeChat.acpLiveState, .connected)
        XCTAssertEqual(availability(claudeDefinition, settings: settings, live: true), .connected)

        print("LIVE claude write")
        claudeChat.submit(text: "Create a file named claude.txt in the current workspace containing exactly hello-from-claude and a trailing newline. Do not modify any other file. Do not use the network.")
        let claudeWriteStreamed = await finish(claudeChat, timeout: 240)
        XCTAssertTrue(claudeStreamed || claudeWriteStreamed, "Claude Code should show assistant text while the turn is still running")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("claude.txt"), encoding: .utf8), "hello-from-claude\n")
        let claudeTools = claudeChat.entries.compactMap { entry -> String? in
            if case .toolCall(let name) = entry.kind { return name }
            return nil
        }
        XCTAssertFalse(claudeTools.isEmpty, "Claude Code should execute a tool")
        let claudeChanges = claudeChat.entries.filter { $0.kind == .changes }.flatMap(\.fileChanges)
        XCTAssertTrue(claudeChanges.contains { $0.path == "claude.txt" }, "diff card paths: \(claudeChanges.map(\.path))")
        XCTAssertFalse(claudeChanges.contains { $0.path == "hello.txt" }, "Claude's card must not list Codex's earlier file")

        print("LIVE claude restore")
        claudeChat.restartACP()
        claudeChat.submit(text: "Reply with exactly the single word RESUMED. Do not use tools.")
        _ = await finish(claudeChat, timeout: 180)
        XCTAssertTrue(claudeChat.entries.contains { $0.text.contains("Restored the remote session") })
        XCTAssertTrue(assistantText(claudeChat).contains("RESUMED"), assistantText(claudeChat))
        XCTAssertFalse(claudeChat.entries.contains { $0.kind == .user && $0.text.contains("PONG") })
        XCTAssertFalse(codexChat.entries.contains { $0.kind == .user && $0.text.contains("PING") })

        print("LIVE switch native")
        controller.selectProvider(.native)
        let nativeChat = controller.selected
        XCTAssertNotEqual(nativeChat.id, claudeChat.id)
        XCTAssertNotEqual(nativeChat.id, codexChat.id)
        XCTAssertFalse(nativeChat.isACPConversation)
        XCTAssertNil(nativeChat.resolvedACPAgentID)
        XCTAssertEqual(nativeChat.effectiveChoice.provider, .mlx)
        XCTAssertFalse(nativeChat.entries.contains { $0.kind == .user })
        XCTAssertFalse(nativeChat.entries.contains { $0.text.contains("PONG") || $0.text.contains("PING") })
        XCTAssertEqual(codexChat.resolvedACPAgentID, codexID)
        XCTAssertEqual(claudeChat.resolvedACPAgentID, claudeID)
        XCTAssertTrue(assistantText(codexChat).contains("PONG"))
        XCTAssertTrue(assistantText(claudeChat).contains("PING"))

        controller.selectProvider(.agent(codexID))
        XCTAssertNotEqual(controller.selected.id, codexChat.id)
        XCTAssertNotEqual(controller.selected.id, nativeChat.id)
        XCTAssertEqual(controller.selected.resolvedACPAgentID, codexID)
        XCTAssertFalse(controller.selected.entries.contains { $0.kind == .user })
        XCTAssertEqual(codexChat.resolvedACPAgentID, codexID)

        controller.teardown()
    }

    private func availability(
        _ definition: IDEACPDefinition, settings: IDEAgentSettings, live: Bool
    ) -> IDEACPAvailability {
        IDEACPAvailabilityResolver.resolve(
            isEnabled: definition.isEnabled,
            executableFound: definition.resolvedExecutable(pathValue: settings.acpPathValue) != nil,
            probe: settings.acpProbes[definition.id],
            isLive: live,
            downloadsOnUse: definition.launchesPackageDownload)
    }

    private func assistantText(_ conversation: IDEAgentConversation) -> String {
        conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n")
    }

    private func approvePending(_ conversation: IDEAgentConversation) {
        for entry in conversation.entries {
            if let approval = entry.approval {
                conversation.decide(callID: approval.callID, .approve)
            }
        }
    }

    /// Waits until the run ends. Approves ACP permission cards. Returns whether assistant text
    /// was visible while the run was still going.
    private func finish(_ conversation: IDEAgentConversation, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streamed = false
        while Date() < deadline {
            approvePending(conversation)
            if conversation.isRunning, conversation.entries.contains(where: { $0.kind == .assistant && !$0.text.isEmpty }) {
                streamed = true
            }
            if !conversation.isRunning,
               conversation.entries.contains(where: { $0.kind == .assistant || $0.kind == .error || $0.kind == .notice }) {
                return streamed
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return streamed
    }
}

@MainActor
private final class LiveACPHost: IDEAgentHost {
    var agentProjectRoot: URL?
    init(root: URL) { agentProjectRoot = root }
    func agentUnsavedBuffers() -> [String: String] { [:] }
    func agentEditorContext() -> String { "[Editor state]\n[End editor state]" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {}
    func agentCreateFile(relativePath: String, contents: String) async throws {}
    func agentTrashFile(relativePath: String) async throws {}
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { AgentCommandEnvironment.make(javaHome: nil) }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome { .notStarted("no") }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}
