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
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: codexCLI))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: claudeCLI))
    }

    func testBothAdaptersCompleteSessionsThroughTheAgentPanel() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "\(prefix)/codex-acp"))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "\(prefix)/claude-agent-acp"))
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
        XCTAssertEqual(codexPreset.recordedLauncher.command, "codex-acp")
        XCTAssertEqual(
            IDEACPDefinition(name: "Codex", command: "codex-acp").resolvedExecutable(pathValue: binPath),
            "\(binPath)/codex-acp")
        XCTAssertEqual(claudePreset.recordedLauncher.command, "claude-agent-acp")
        XCTAssertEqual(
            IDEACPDefinition(name: "Claude Code", command: "claude-agent-acp").resolvedExecutable(pathValue: binPath),
            "\(binPath)/claude-agent-acp")

        try await exercise(settings: settings, codexID: codexID, claudeID: claudeID, root: root, codexDefinition: codexDefinition, claudeDefinition: claudeDefinition)
    }

    /// Opt-in: installs both adapters for real through `IDEACPAdapterManager` into a temporary
    /// folder (a few hundred megabytes each, from the public npm registry, verified by the trust
    /// policy), then runs the same end-to-end flow against the **managed** launches. No path
    /// override, no environment override: the rows are the catalog rows Umbra creates itself.
    func testManagedInstallThenBothAdaptersCompleteSessionsThroughTheAgentPanel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_LIVE_ACP_INSTALL"] == "1")
        let acpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-live-acp-\(UUID().uuidString)", isDirectory: true)
        let saved = IDEACPAdapterManager.shared
        let manager = IDEACPAdapterManager.makeProduction(root: acpRoot)
        IDEACPAdapterManager.shared = manager
        defer {
            IDEACPAdapterManager.shared = saved
            try? FileManager.default.removeItem(at: acpRoot)
        }
        let defaults = UserDefaults(suiteName: "umbra.acp.live.install.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .mlx
        await settings.refreshACPPath()
        await manager.load()
        await manager.refreshNode()
        guard case .found(let node) = manager.node else { return XCTFail("Node.js was not found on the login path") }
        print("LIVE node \(node.node) \(node.version)")

        for id in ["codex-acp", "claude-agent-acp"] {
            let started = Date()
            let proposal = try await manager.prepareInstall(id)
            print("LIVE propose \(proposal.packageName)@\(proposal.version) key=\(proposal.signatureKeyID) publisher=\(proposal.publisher)")
            manager.install(proposal, settings: settings)
            let ready = await waitFor(timeout: 1_500) {
                switch manager.states[id]?.phase {
                case .ready: true
                case .failed: true
                default: false
                }
            }
            XCTAssertTrue(ready, "install timed out: \(String(describing: manager.states[id]?.phase))")
            guard case .ready(let version)? = manager.states[id]?.phase else {
                return XCTFail("install did not finish: \(String(describing: manager.states[id]?.phase)) \(manager.states[id]?.diagnostics ?? "")")
            }
            let manifest = try XCTUnwrap(manager.states[id]?.activeManifest)
            print("LIVE installed \(id)@\(version) in \(Int(Date().timeIntervalSince(started)))s size=\(ByteCountFormatter.string(fromByteCount: manifest.installedBytes, countStyle: .file)) warnings=\(manifest.warnings)")
            XCTAssertNoThrow(try IDEACPAdapterStore.verifyEntry(try XCTUnwrap(manager.activeInstall(for: id))))
        }

        let codexRow = try XCTUnwrap(settings.acpAgents.first { $0.presetID == "codex" })
        let claudeRow = try XCTUnwrap(settings.acpAgents.first { $0.presetID == "claude-code" })
        XCTAssertEqual(codexRow.launchMode, .auto)
        XCTAssertEqual(claudeRow.launchMode, .auto)
        XCTAssertTrue(settings.acpAllowedAgentIDs.contains(codexRow.id) && settings.acpAllowedAgentIDs.contains(claudeRow.id))
        settings.acpActiveAgentID = codexRow.id
        XCTAssertEqual(manager.availability(of: codexRow, settings: settings, isLive: false), .installed)

        // The connection test the Adapters section's button runs.
        let environment = AgentCommandEnvironment.make(javaHome: nil, loginPath: await IDELoginShellPath.shared.entries())
        for row in [codexRow, claudeRow] {
            await manager.testConnection(definition: row, settings: settings, environment: environment)
            print("LIVE test-connection \(row.name): \(String(describing: settings.acpProbes[row.id]?.phase))")
            switch settings.acpProbes[row.id]?.phase {
            case .connected?, .authenticationRequired?: break
            default: XCTFail("\(row.name) connection test: \(String(describing: settings.acpProbes[row.id]?.phase))")
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-acp-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "seed\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["UMBRA_LIVE_ACP_PERMISSIONS_ONLY"] != "1" {
            try await exercise(settings: settings, codexID: codexRow.id, claudeID: claudeRow.id, root: root, codexDefinition: codexRow, claudeDefinition: claudeRow)
        }

        if ProcessInfo.processInfo.environment["UMBRA_LIVE_ACP_PERMISSIONS"] == "1" {
            for (row, askingMode) in [(claudeRow, "default"), (codexRow, "read-only")] {
                let workspace = FileManager.default.temporaryDirectory
                    .appendingPathComponent("umbra-acp-permissions-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: workspace) }
                try await permissions(settings: settings, agentID: row.id, name: row.name, askingMode: askingMode, root: workspace)
            }
        }
    }

    // MARK: Real permission decisions

    /// Approve, reject, Stop while a card waits, and an unanswered card that times out, each in a
    /// fresh chat on the real agent, in a disposable folder. Only the file named "approved" is
    /// ever approved. Every refusal is checked on disk, and again after a pause, so a late write
    /// would be caught.
    private func permissions(
        settings: IDEAgentSettings, agentID: UUID, name: String, askingMode: String, root: URL
    ) async throws {
        print("LIVE permissions \(name) in \(root.path)")
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        func prompt(_ fileName: String) -> String {
            "Create a file named \(fileName) in the current workspace containing exactly ok and a trailing newline. "
                + "Use exactly one file-writing tool call. If that call is rejected or cancelled, do not retry and do not "
                + "try any other way (no shell commands); reply NOT-CREATED and stop."
        }

        // The controller holds its host weakly (a chat must not keep a window alive), so the
        // hosts live here for the whole scenario.
        var hosts: [LiveACPHost] = []

        /// A new chat on the agent, in its asking mode when it offers one. Nil when the chat never
        /// starts (reported as a failure at once rather than after every timeout).
        func chat(timeout: Duration = .seconds(300)) async -> (IDEAgentController, IDEAgentConversation)? {
            let controller = IDEAgentController(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
            let host = LiveACPHost(root: root)
            hosts.append(host)
            controller.attach(host: host)
            controller.selectProvider(.agent(agentID))
            let conversation = controller.selected
            XCTAssertEqual(conversation.resolvedACPAgentID, agentID)
            conversation.acpPermissionTimeout = timeout
            // A first exchange starts the session, so the agent's modes are known.
            conversation.submit(text: "Reply with exactly the single word READY. Do not use tools.")
            let started = await waitFor(timeout: 10) { conversation.entries.contains { $0.kind == .user } }
            guard started else {
                XCTFail("\(name): the chat did not take the message")
                controller.teardown()
                return nil
            }
            _ = await finishWithoutApproving(conversation, timeout: 180)
            XCTAssertTrue(assistantText(conversation).contains("READY"), "\(name) answered: \(conversation.entries.map { "\($0.kind):\($0.text.prefix(60))" })")
            // The header state is read when a run starts; give it a moment after the run.
            _ = await waitFor(timeout: 5) { !conversation.acpAvailableModes.isEmpty || !conversation.acpConfigOptions.isEmpty }
            if let mode = conversation.acpAvailableModes.first(where: { $0.id == askingMode })
                ?? conversation.acpAvailableModes.first(where: { $0.id.localizedCaseInsensitiveContains(askingMode) }) {
                conversation.setACPMode(mode.id)
                _ = await waitFor(timeout: 15) { conversation.acpCurrentModeID == mode.id }
                XCTAssertEqual(conversation.acpCurrentModeID, mode.id, "\(name) switched to its asking mode")
                print("LIVE permissions \(name): mode \(mode.id) (session modes)")
            } else if let option = conversation.acpConfigOptions.first(where: {
                $0.id == "mode" || Self.field($0.raw, "category") == "mode"
            }), let value = Self.optionValues(option).first(where: { $0 == askingMode || $0.localizedCaseInsensitiveContains(askingMode) }) {
                conversation.setACPConfig(id: option.id, value: value)
                _ = await waitFor(timeout: 15) {
                    conversation.acpConfigOptions.first { $0.id == option.id }.flatMap { Self.field($0.raw, "currentValue") } == value
                }
                print("LIVE permissions \(name): mode \(value) (config option \(option.id), now \(conversation.acpConfigOptions.first { $0.id == option.id }.flatMap { Self.field($0.raw, "currentValue") } ?? "?"))")
            } else {
                print("LIVE permissions \(name): no '\(askingMode)' mode; modes=\(conversation.acpAvailableModes.map(\.id)) options=\(conversation.acpConfigOptions.map { "\($0.id)=\(Self.optionValues($0))" }); using the agent's default")
            }
            return (controller, conversation)
        }

        // 1. Approve.
        guard let (approveController, approving) = await chat() else { return }
        approving.submit(text: prompt("approved.txt"))
        let approveCard = await waitForApproval(approving, timeout: 180)
        XCTAssertNotNil(approveCard, "\(name) asked before writing: \(approving.entries.map { "\($0.kind):\($0.text.prefix(60))" })")
        if let approveCard { approving.decide(callID: approveCard, .approve) }
        _ = await finishWithoutApproving(approving, timeout: 180)
        XCTAssertEqual(try? String(contentsOf: file("approved.txt"), encoding: .utf8), "ok\n", "\(name): the approved write happened")
        print("LIVE permissions \(name) approve: card=\(approveCard != nil) file=\(FileManager.default.fileExists(atPath: file("approved.txt").path))")
        approveController.teardown()

        // 2. Reject.
        guard let (rejectController, rejecting) = await chat() else { return }
        rejecting.submit(text: prompt("rejected.txt"))
        var rejectedCards = 0
        let rejectDeadline = Date().addingTimeInterval(240)
        while Date() < rejectDeadline, rejecting.isRunning || rejectedCards == 0 {
            // Every card in this chat is rejected, including any retry the model makes anyway.
            if let card = pendingApproval(rejecting) {
                rejecting.decide(callID: card, .deny(note: nil))
                rejectedCards += 1
            }
            if !rejecting.isRunning, rejectedCards == 0, Date() > rejectDeadline.addingTimeInterval(-180) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertGreaterThan(rejectedCards, 0, "\(name) asked before writing")
        XCTAssertFalse(rejecting.isRunning)
        try? await Task.sleep(for: .seconds(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("rejected.txt").path), "\(name): nothing written after a rejection")
        print("LIVE permissions \(name) reject: cards=\(rejectedCards) file=\(FileManager.default.fileExists(atPath: file("rejected.txt").path)) answer=\(assistantText(rejecting).suffix(80))")
        rejectController.teardown()

        // 3. Stop while the card waits.
        guard let (stopController, stopping) = await chat() else { return }
        stopping.submit(text: prompt("stopped.txt"))
        let stopCard = await waitForApproval(stopping, timeout: 180)
        XCTAssertNotNil(stopCard, "\(name) asked before writing")
        let stopAt = Date()
        stopping.stop()
        let ended = await waitFor(timeout: 30) { !stopping.isRunning }
        XCTAssertTrue(ended, "\(name): Stop ends a run that waits on a card")
        XCTAssertTrue(stopping.entries.contains { $0.kind == .notice && $0.text == "Stopped." },
                      "\(stopping.entries.map { "\($0.kind):\($0.text.prefix(60))" })")
        XCTAssertNil(pendingApproval(stopping), "no card is left waiting after Stop")
        try? await Task.sleep(for: .seconds(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("stopped.txt").path), "\(name): nothing written after Stop")
        print("LIVE permissions \(name) stop: ended in \(String(format: "%.1f", Date().timeIntervalSince(stopAt)))s file=\(FileManager.default.fileExists(atPath: file("stopped.txt").path))")
        stopController.teardown()

        // 4. Nobody answers: the card times out (shortened from 300 s to 8 s for the test).
        guard let (timeoutController, waiting) = await chat(timeout: .seconds(8)) else { return }
        waiting.submit(text: prompt("unanswered.txt"))
        let timeoutCard = await waitForApproval(waiting, timeout: 180)
        XCTAssertNotNil(timeoutCard, "\(name) asked before writing")
        let finished = await waitFor(timeout: 180) { !waiting.isRunning }
        XCTAssertTrue(finished, "\(name): the run ends after the card times out")
        let timedOut = waiting.entries.contains { $0.text.contains("Permission request timed out") }
            || waiting.entries.contains { $0.output?.text.contains("Permission request timed out") ?? false }
        XCTAssertTrue(timedOut, "the transcript says the request timed out: \(waiting.entries.map { "\($0.kind):\($0.text.prefix(60))" })")
        try? await Task.sleep(for: .seconds(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("unanswered.txt").path), "\(name): nothing written after a timeout")
        print("LIVE permissions \(name) timeout: card=\(timeoutCard != nil) noted=\(timedOut) file=\(FileManager.default.fileExists(atPath: file("unanswered.txt").path)) answer=\(assistantText(waiting).suffix(80))")
        timeoutController.teardown()
    }

    /// A string field of a JSON object (AgentKit's own accessor is internal).
    private static func field(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = value, case .string(let text)? = object[key] else { return nil }
        return text
    }

    /// The values a select option offers (`options: [{value, name}]`, possibly grouped).
    private static func optionValues(_ option: ACPConfigOption) -> [String] {
        func values(_ list: JSONValue?) -> [String] {
            guard case .array(let items)? = list else { return [] }
            return items.flatMap { item -> [String] in
                if let value = Self.field(item, "value") { return [value] }
                if case .object(let object) = item { return values(object["options"]) }
                return []
            }
        }
        guard case .object(let object) = option.raw else { return [] }
        return values(object["options"])
    }

    private func pendingApproval(_ conversation: IDEAgentConversation) -> String? {
        // `decide` clears `approval`, so a card that still has one is waiting.
        conversation.entries.last { $0.approval != nil }?.approval?.callID
    }

    private func waitForApproval(_ conversation: IDEAgentConversation, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let card = pendingApproval(conversation) { return card }
            if !conversation.isRunning, conversation.entries.contains(where: { $0.kind == .assistant || $0.kind == .error }) {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// `finish` without answering any card.
    private func finishWithoutApproving(_ conversation: IDEAgentConversation, timeout: TimeInterval) async -> Bool {
        await waitFor(timeout: timeout) { !conversation.isRunning && !conversation.entries.isEmpty }
    }

    private func waitFor(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        return condition()
    }

    private func exercise(
        settings: IDEAgentSettings, codexID: UUID, claudeID: UUID, root: URL,
        codexDefinition: IDEACPDefinition, claudeDefinition: IDEACPDefinition
    ) async throws {
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
            isLive: live)
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
