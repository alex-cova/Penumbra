import AgentKit
import Foundation
import XCTest
@testable import Umbra

/// Discovery, presets, binding and provider switching. Nothing here starts a process:
/// executable checks go through an injected closure or a file that is never launched.
@MainActor
final class IDEACPRegistryTests: XCTestCase {
    func testPathResolutionUsesTheGivenPathAndDoesNotSearchWhenTheCommandIsAPath() {
        var looked: [String] = []
        let bare = IDEACPDefinition(name: "Codex", command: "codex-acp")
        let found = bare.resolvedExecutable(pathValue: "/missing:/opt/bin:/usr/bin", isExecutable: { path in
            looked.append(path)
            return path == "/opt/bin/codex-acp"
        })
        XCTAssertEqual(found, "/opt/bin/codex-acp")
        XCTAssertEqual(looked, ["/missing/codex-acp", "/opt/bin/codex-acp"])

        looked.removeAll()
        let absolute = IDEACPDefinition(name: "Codex", command: "/tmp/no-such-acp-agent")
        XCTAssertNil(absolute.resolvedExecutable(pathValue: "/usr/bin", isExecutable: { path in
            looked.append(path)
            return false
        }))
        XCTAssertEqual(looked, ["/tmp/no-such-acp-agent"])
    }

    func testPresetsUseAVerifiedAdapterOrNativeCLIAndNeverInventAnNpxCommand() {
        let claude = IDEACPRegistry.preset(id: "claude-code")!
        let codex = IDEACPRegistry.preset(id: "codex")!
        let gemini = IDEACPRegistry.preset(id: "gemini")!
        let opencode = IDEACPRegistry.preset(id: "opencode")!
        let none: (String) -> Bool = { _ in false }
        let npxOnly: (String) -> Bool = { $0.hasSuffix("/npx") }
        let adapter: (String) -> Bool = { $0.hasSuffix("/claude-agent-acp") || $0.hasSuffix("/codex-acp") }
        let rightPackage: (String) -> String? = { $0.hasSuffix("claude-agent-acp") ? "@agentclientprotocol/claude-agent-acp" : "@agentclientprotocol/codex-acp" }
        let otherPackage: (String) -> String? = { _ in "some-other-tool" }

        // A system adapter counts only when its package.json names the expected package.
        XCTAssertEqual(
            claude.resolution(active: nil, pathValue: "/bin", isExecutable: adapter, systemPackageName: rightPackage).launch?.source,
            .systemAdapter)
        XCTAssertEqual(
            claude.resolution(active: nil, pathValue: "/bin", isExecutable: adapter, systemPackageName: otherPackage),
            .unavailable(.notInstalled("Claude Code")))
        XCTAssertEqual(
            codex.resolution(active: nil, pathValue: "/bin", isExecutable: adapter, systemPackageName: rightPackage).launch?.executable,
            "/bin/codex-acp")
        // npx on its own is never an adapter, and nothing falls back to it.
        XCTAssertEqual(
            claude.resolution(active: nil, pathValue: "/bin", isExecutable: npxOnly, systemPackageName: rightPackage),
            .unavailable(.notInstalled("Claude Code")))
        XCTAssertEqual(
            codex.resolution(active: nil, pathValue: "/bin", isExecutable: none, systemPackageName: rightPackage),
            .unavailable(.notInstalled("Codex")))
        for preset in IDEACPRegistry.presets {
            XCTAssertFalse(preset.launchers.contains { $0.command == "npx" }, preset.id)
        }

        // Native CLIs run their documented ACP mode, and only when the CLI is there.
        let geminiLaunch = gemini.resolution(active: nil, pathValue: "/bin", isExecutable: { $0 == "/bin/gemini" })
        XCTAssertEqual(geminiLaunch.launch?.args, ["--acp"])
        XCTAssertEqual(geminiLaunch.launch?.source, .nativeCLI)
        XCTAssertEqual(
            gemini.resolution(active: nil, pathValue: "/bin", isExecutable: npxOnly), .unavailable(.cliMissing("gemini")))
        XCTAssertEqual(
            opencode.resolution(active: nil, pathValue: "/bin", isExecutable: { $0 == "/bin/opencode" }).launch?.args, ["acp"])
        XCTAssertEqual(opencode.launchers.count, 1)
    }

    func testMaterializeCreatesACatalogRowAndDoesNotAllowOrStart() {
        let settings = makeSettings()
        let claude = settings.materializePreset(IDEACPRegistry.preset(id: "claude-code")!)
        XCTAssertEqual(claude.command, "claude-agent-acp")
        XCTAssertEqual(claude.launchMode, .auto)
        XCTAssertEqual(claude.presetID, "claude-code")
        XCTAssertFalse(settings.acpAllowedAgentIDs.contains(claude.id))
        XCTAssertNil(settings.activeACPAgent)
        XCTAssertEqual(settings.materializePreset(IDEACPRegistry.preset(id: "claude-code")!).id, claude.id)

        let gemini = settings.materializePreset(IDEACPRegistry.preset(id: "gemini")!)
        XCTAssertEqual(gemini.command, "gemini")
        XCTAssertEqual(gemini.args, ["--acp"])
        XCTAssertNil(gemini.resolvedExecutable(pathValue: "/nonexistent-umbra-path"))
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: false, probe: nil, isLive: false),
            .notInstalled)
    }

    func testStatusPrecedence() {
        let auth = IDEACPProbe(phase: .authenticationRequired("Sign in"), checkedAt: Date())
        let failed = IDEACPProbe(phase: .failed("connection reset"), checkedAt: Date())
        let handshake = IDEACPProbe(
            phase: .connected(protocolVersion: 1, agentName: "Codex", loadSession: true), checkedAt: Date())
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: false, executableFound: true, probe: handshake, isLive: true),
            .disabled)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: failed, isLive: true),
            .connected)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: auth, isLive: false),
            .authenticationRequired("Sign in"))
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: false, probe: failed, isLive: false),
            .notInstalled)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: failed, isLive: false),
            .failed("connection reset"))
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: handshake, isLive: false),
            .installed)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: false, probe: nil, isLive: false),
            .notInstalled)
        // An agent Umbra can install, with nothing to launch yet.
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(
                isEnabled: true, executableFound: false, probe: nil, isLive: false, installable: true),
            .adapterMissing)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(
                isEnabled: true, executableFound: false, probe: failed, isLive: false, installable: true),
            .adapterMissing)
    }

    func testAvailabilityClassifiesProtocolDisconnectAndAMissingAdapter() {
        let message = "The agent requires ACP protocol version 99, which this client does not support."
        let mismatch = IDEACPProbe(phase: .failed(message), checkedAt: Date())
        let dropped = IDEACPProbe(phase: .failed("The ACP agent disconnected."), checkedAt: Date())
        let handshake = IDEACPProbe(
            phase: .connected(protocolVersion: 1, agentName: "Codex", loadSession: true), checkedAt: Date())
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: mismatch, isLive: false),
            .incompatibleProtocol(message))
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(isEnabled: true, executableFound: true, probe: dropped, isLive: false),
            .disconnected)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(
                isEnabled: true, executableFound: true, probe: handshake, isLive: false, installable: true),
            .installed)
        XCTAssertEqual(
            IDEACPAvailabilityResolver.resolve(
                isEnabled: true, executableFound: false, probe: nil, isLive: false, installable: false),
            .notInstalled)
        XCTAssertEqual(IDEACPAvailability.adapterMissing.title, "Adapter not installed")
        XCTAssertFalse(IDEACPDefinition(name: "A", command: "/tmp/missing-agent").missingExecutableMessage.contains("on PATH"))
        XCTAssertTrue(IDEACPDefinition(name: "A", command: "missing-agent").missingExecutableMessage.contains("on PATH"))
    }

    func testSessionResumePlanFollowsTheLiveCapability() {
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: "s", agentSupportsLoad: true, hasEarlierTranscript: true),
            .load("s"))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: "s", agentSupportsLoad: false, hasEarlierTranscript: false),
            .create(notice: IDEACPSessionResume.unsupportedNotice))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: nil, agentSupportsLoad: true, hasEarlierTranscript: true),
            .create(notice: IDEACPSessionResume.freshHistoryNotice))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: "", agentSupportsLoad: true, hasEarlierTranscript: true),
            .create(notice: IDEACPSessionResume.freshHistoryNotice))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: nil, agentSupportsLoad: false, hasEarlierTranscript: false),
            .create(notice: nil))
        XCTAssertNil(IDEACPSessionResume.normalizedSessionID("   \n"))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: " \t ", agentSupportsLoad: true, hasEarlierTranscript: true),
            .create(notice: IDEACPSessionResume.freshHistoryNotice))
        XCTAssertEqual(
            IDEACPSessionResume.plan(savedSessionID: "  remote-1  ", agentSupportsLoad: true, hasEarlierTranscript: false),
            .load("remote-1"))
        let noisy = String(repeating: "line\n", count: 20) + "token=sk-abcdefghijklmnop"
        let detail = IDEACPDiagnostics.detail(noisy)
        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.contains("sk-") ?? true)
        XCTAssertTrue(detail?.contains("[redacted]") ?? false)
        XCTAssertLessThanOrEqual(detail?.count ?? 0, IDEACPDiagnostics.maxCharacters + 1)
    }

    func testBindingPrefersTheModelChoiceThenThePinThenTheDefault() {
        let pinned = UUID()
        let chosen = UUID()
        let fallback = UUID()
        let nativeChoice = IDEAIModelChoice(provider: .mlx, model: "local")
        let externalChoice = IDEAIModelChoice(provider: .mlx, model: "local", acpAgentID: chosen)
        XCTAssertEqual(
            IDEACPBindingResolver.agentID(pin: .agent(pinned), modelChoice: externalChoice, defaultID: fallback),
            chosen)
        XCTAssertNil(IDEACPBindingResolver.agentID(pin: .agent(pinned), modelChoice: nativeChoice, defaultID: fallback))
        XCTAssertEqual(
            IDEACPBindingResolver.agentID(pin: .agent(pinned), modelChoice: nil, defaultID: fallback),
            pinned)
        XCTAssertNil(IDEACPBindingResolver.agentID(pin: .native, modelChoice: nil, defaultID: fallback))
        XCTAssertEqual(IDEACPBindingResolver.agentID(pin: nil, modelChoice: nil, defaultID: fallback), fallback)
    }

    func testSwitchPlanRebindsAnEmptyChatAndPreservesOneWithContent() {
        let agent = UUID()
        let selected = IDEACPChatRef(
            id: UUID(), isEmpty: true, isRunning: false, pin: nil, hasModelChoice: false, modelACPAgentID: nil)
        XCTAssertEqual(
            IDEACPProviderSwitch.plan(selected: selected, chats: [selected], target: .agent(agent), defaultID: nil),
            .rebind(selected.id))
        XCTAssertEqual(
            IDEACPProviderSwitch.plan(selected: selected, chats: [selected], target: .native, defaultID: nil),
            .stay)

        let filled = IDEACPChatRef(
            id: UUID(), isEmpty: false, isRunning: true, pin: .agent(agent), hasModelChoice: false, modelACPAgentID: nil)
        let emptyNative = IDEACPChatRef(
            id: UUID(), isEmpty: true, isRunning: false, pin: .native, hasModelChoice: false, modelACPAgentID: nil)
        XCTAssertEqual(
            IDEACPProviderSwitch.plan(
                selected: filled, chats: [filled, emptyNative], target: .native, defaultID: agent),
            .open(keeping: filled.id, existing: emptyNative.id, previousIsRunning: true))
        XCTAssertEqual(
            IDEACPProviderSwitch.plan(selected: filled, chats: [filled], target: .native, defaultID: agent),
            .open(keeping: filled.id, existing: nil, previousIsRunning: true))
    }

    func testWorkspaceDefaultDoesNotChangeTheGlobalChoice() throws {
        let defaults = UserDefaults(suiteName: "umbra.acp.registry.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.addACPAgent(name: "Codex", commandLine: "codex-acp")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertEqual(settings.currentChoice.acpAgentID, id)
        settings.acpActiveAgentID = nil
        settings.setWorkspaceDefault(agentID: id, workspace: root)
        XCTAssertNil(settings.currentChoice.acpAgentID)
        XCTAssertEqual(settings.agentIDForNewChats(in: root), id)
        XCTAssertEqual(settings.agentIDForNewChats(in: link), id)
        XCTAssertNil(settings.agentIDForNewChats(in: nil))

        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.workspaceDefaultID(for: root), id)
        reloaded.setACPAllowed(true, agentID: id)
        XCTAssertEqual(reloaded.agentIDForNewChats(in: root), id)
        XCTAssertNil(reloaded.currentChoice.acpAgentID)
    }

    func testOldDefinitionAndTranscriptDecodeStayUnpinnedAndEnabled() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"A","command":"agent","args":["--acp"],"env":{}}
        """
        let decoded = try JSONDecoder().decode(IDEACPDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertNil(decoded.presetID)
        XCTAssertEqual(decoded.args, ["--acp"])
        let again = try JSONDecoder().decode(IDEACPDefinition.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)

        let legacy = IDEAgentSavedTranscript.decode(Data(#"{"entries":[]}"#.utf8))
        XCTAssertNil(legacy.acpPinnedAgentID)
        XCTAssertFalse(legacy.acpPinnedNative)
        let pinned = IDEAgentSavedTranscript.decode(
            IDEAgentSavedTranscript.encode(entries: [], cost: nil, acpPinnedAgentID: id, acpPinnedNative: false))
        XCTAssertEqual(pinned.acpPinnedAgentID, id)
        XCTAssertFalse(pinned.acpPinnedNative)
        let native = IDEAgentSavedTranscript.decode(IDEAgentSavedTranscript.encode(entries: [], cost: nil, acpPinnedNative: true))
        XCTAssertNil(native.acpPinnedAgentID)
        XCTAssertTrue(native.acpPinnedNative)
        XCTAssertNil(legacy.acpSessionID)
        let withSession = IDEAgentSavedTranscript.decode(
            IDEAgentSavedTranscript.encode(entries: [], cost: nil, acpSessionID: "remote-1"))
        XCTAssertEqual(withSession.acpSessionID, "remote-1")
        XCTAssertNil(withSession.acpPinnedAgentID)
        XCTAssertNil(legacy.acpLaunchFingerprint)
        let withFingerprint = IDEAgentSavedTranscript.decode(
            IDEAgentSavedTranscript.encode(entries: [], cost: nil, acpSessionID: "remote-1", acpLaunchFingerprint: "agent|cmd|arg|/work"))
        XCTAssertEqual(withFingerprint.acpLaunchFingerprint, "agent|cmd|arg|/work")
        XCTAssertEqual(withFingerprint.acpSessionID, "remote-1")
    }

    func testSecretScrubberAndAuthClassification() {
        let scrubbed = IDEACPSecretScrubber.scrub(
            "login failed bearer sk-abcdefghijklmnop api_key=supersecret password: hunter2")
        XCTAssertFalse(scrubbed.contains("sk-"))
        XCTAssertFalse(scrubbed.contains("supersecret"))
        XCTAssertFalse(scrubbed.contains("hunter2"))
        XCTAssertTrue(scrubbed.contains("[redacted]"))
        XCTAssertEqual(
            IDEACPSecretScrubber.scrub("Could not find the ACP agent executable “codex-acp” on PATH."),
            "Could not find the ACP agent executable “codex-acp” on PATH.")

        XCTAssertTrue(IDEACPAuth.isAuthenticationFailure(
            ACPError.agentError(JSONRPCError(code: -32000, message: "Please login"))))
        XCTAssertTrue(IDEACPAuth.isAuthenticationFailure(
            ACPError.agentError(JSONRPCError(code: -32000, message: "Unauthorized"))))
        XCTAssertFalse(IDEACPAuth.isAuthenticationFailure(
            ACPError.agentError(JSONRPCError(code: -32000, message: "Could not find the ACP agent executable"))))
        XCTAssertFalse(IDEACPAuth.isAuthenticationFailure(ACPError.unsupportedProtocolVersion(2)))
    }

    func testAdvertisedConfigChoicesAreReadFromTheAgent() {
        let select = ACPConfigOption(jsonValue: .object([
            "id": .string("model"),
            "name": .string("Model"),
            "type": .string("select"),
            "currentValue": .string("fast"),
            "options": .array([
                .object(["value": .string("fast"), "name": .string("Fast")]),
                .object(["id": .string("deep"), "name": .string("Deep")]),
            ]),
        ]))
        XCTAssertEqual(select.selectableChoices.map(\.value), ["fast", "deep"])
        XCTAssertEqual(select.selectableChoices.map(\.title), ["Fast", "Deep"])
        let plain = ACPConfigOption(jsonValue: .object(["id": .string("thinking"), "name": .string("Thinking"), "type": .string("boolean")]))
        XCTAssertTrue(plain.selectableChoices.isEmpty)
    }

    func testMissingExecutableProbeDoesNotSpawn() async {
        let definition = IDEACPDefinition(name: "Missing", command: "umbra-acp-not-installed-\(UUID().uuidString)")
        let phase = await IDEACPConnectionTest.run(
            definition: definition,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"])
        guard case .failed(let message) = phase else {
            return XCTFail("expected a failure, got \(phase)")
        }
        XCTAssertTrue(message.contains("Could not find"), message)
        XCTAssertTrue(message.contains("on PATH"), message)
        XCTAssertFalse(IDEACPAuth.isAuthenticationFailure(
            ACPError.agentError(JSONRPCError(code: -32000, message: message))))
    }

    func testMissingAbsolutePathProbeDoesNotMentionPATH() async {
        let missing = "/tmp/umbra-acp-missing-\(UUID().uuidString)"
        let definition = IDEACPDefinition(name: "Missing", command: missing)
        let phase = await IDEACPConnectionTest.run(
            definition: definition,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"])
        guard case .failed(let message) = phase else {
            return XCTFail("expected a failure, got \(phase)")
        }
        XCTAssertTrue(message.contains("Could not find"), message)
        XCTAssertTrue(message.contains(missing), message)
        XCTAssertFalse(message.contains("on PATH"), message)
    }

    func testSelectingNativeLeavesTheMLXChoiceAndDoesNotMoveASentTranscript() {
        let settings = makeSettings()
        settings.provider = .mlx
        settings.addACPAgent(name: "Codex", commandLine: "codex-acp")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        let controller = IDEAgentController(
            settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let original = controller.selected
        original.appendNotice("sent")
        original.acpPin = .native
        controller.freezeUnpinnedTranscripts()
        settings.acpActiveAgentID = id
        XCTAssertNil(original.resolvedACPAgentID)
        XCTAssertFalse(original.isACPConversation)
        XCTAssertEqual(original.effectiveChoice.provider, .mlx)
        XCTAssertNil(original.effectiveChoice.acpAgentID)
        XCTAssertFalse(original.effectiveChoice.isACP)

        let empty = controller.addConversation()
        XCTAssertEqual(empty.resolvedACPAgentID, id)
        XCTAssertTrue(empty.isACPConversation)
        controller.select(original.id)
        controller.selectProvider(.agent(id))
        XCTAssertEqual(controller.selected.id, empty.id)
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertNil(original.resolvedACPAgentID)
        XCTAssertTrue(original.entries.contains { $0.text == "sent" })

        original.reset()
        XCTAssertEqual(original.acpPin, .native)
        XCTAssertTrue(original.isEmpty)
        XCTAssertEqual(original.acpLiveState, .idle)
        controller.teardown()
    }

    func testProviderSwitchRebindsAnEmptyChatAndFreezesContentBeforeTheDefaultChanges() {
        let settings = makeSettings()
        settings.addACPAgent(name: "Codex", commandLine: "codex-acp")
        settings.addACPAgent(name: "Gemini", commandLine: "gemini --acp")
        let codex = settings.acpAgents[0].id
        let gemini = settings.acpAgents[1].id
        settings.setACPAllowed(true, agentID: codex)
        settings.setACPAllowed(true, agentID: gemini)
        settings.acpActiveAgentID = codex
        let controller = IDEAgentController(
            settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let chat = controller.selected
        XCTAssertEqual(chat.resolvedACPAgentID, codex)
        controller.selectProvider(.native)
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertNil(chat.resolvedACPAgentID)
        XCTAssertEqual(chat.acpPin, .native)

        settings.acpActiveAgentID = gemini
        let kept = controller.addConversation()
        kept.appendNotice("kept")
        XCTAssertNil(kept.acpPin)
        XCTAssertEqual(kept.resolvedACPAgentID, gemini)
        controller.freezeUnpinnedTranscripts()
        settings.acpActiveAgentID = codex
        XCTAssertEqual(kept.resolvedACPAgentID, gemini, "content written before the default changed stays on its agent")
        XCTAssertEqual(chat.resolvedACPAgentID, nil)
        let follower = controller.addConversation()
        XCTAssertEqual(follower.resolvedACPAgentID, codex)
        controller.select(kept.id)
        controller.selectProvider(.agent(codex))
        XCTAssertEqual(controller.selected.id, follower.id)
        XCTAssertEqual(kept.resolvedACPAgentID, gemini)
        controller.teardown()
    }

    func testDisabledOrUnallowedAgentIsAnErrorAndDoesNotCallTheNativeModel() {
        let settings = makeSettings()
        settings.provider = .mlx
        let calls = NativeCallFlag()
        let host = RegistryHost(root: FileManager.default.temporaryDirectory)
        let conversation = IDEAgentConversation(
            settings: settings, store: nil,
            clientFactory: { _ in
                calls.called = true
                return MockLLMClient(turns: [])
            })
        conversation.host = host
        settings.addACPAgent(name: "Codex", commandLine: "codex-acp")
        let id = settings.acpAgents[0].id
        conversation.modelChoice = IDEAIModelChoice(provider: .mlx, model: "local", acpAgentID: id)

        conversation.submit(text: "hello")
        XCTAssertFalse(calls.called)
        XCTAssertFalse(conversation.isRunning)
        XCTAssertTrue(conversation.entries.contains { $0.kind == .error && $0.text.contains("Allow Codex") })
        XCTAssertFalse(conversation.entries.contains { $0.kind == .user })

        conversation.reset()
        settings.setACPAllowed(true, agentID: id)
        settings.setACPEnabled(false, agentID: id)
        conversation.submit(text: "hello")
        XCTAssertFalse(calls.called)
        XCTAssertFalse(conversation.isRunning)
        XCTAssertTrue(conversation.entries.contains { $0.kind == .error && $0.text.contains("disabled") })
        XCTAssertFalse(conversation.isACPConversation)
        XCTAssertEqual(conversation.resolvedACPAgentID, id)
    }

    func testUpdateAndDisableKeepTheIdentity() {
        let settings = makeSettings()
        settings.addACPAgent(name: "Custom", commandLine: "my-agent --acp")
        let id = settings.acpAgents[0].id
        settings.setACPAllowed(true, agentID: id)
        XCTAssertTrue(settings.updateACPAgent(id: id, name: "Renamed", commandLine: #""/opt/bin/my agent" --flag"#))
        XCTAssertEqual(settings.acpAgents[0].command, "/opt/bin/my agent")
        XCTAssertEqual(settings.acpAgents[0].args, ["--flag"])
        XCTAssertEqual(settings.acpAgents[0].id, id)
        settings.setACPEnabled(false, agentID: id)
        XCTAssertNil(settings.activeACPAgent)
        XCTAssertEqual(settings.acpActiveAgentID, id)
        settings.setACPEnabled(true, agentID: id)
        XCTAssertEqual(settings.activeACPAgent?.id, id)
    }

    func testWorkspaceSnapshotFeedsTheDiffCard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-acp-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("kept.txt")
        try "same\n".write(to: kept, atomically: true, encoding: .utf8)
        let before = IDEACPWorkspaceSnapshot.capture(root: root)
        try "hello-from-acp\n".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: kept, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("kept.txt"))
        try "gone\n".write(to: root.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("kept.txt"))
        let created = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        try "new\n".write(to: created.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let after = IDEACPWorkspaceSnapshot.capture(root: root)
        let log = CheckpointLog()
        let run = await log.beginRun(label: "acp")
        await IDEACPWorkspaceSnapshot.record(before: before, after: after, run: run, checkpoints: log)
        let changes = await log.changes(in: run)
        XCTAssertEqual(Set(changes.map(\.path)), ["hello.txt", "kept.txt", "nested/a.txt"])
        XCTAssertEqual(changes.first { $0.path == "hello.txt" }?.original, nil)
        XCTAssertEqual(changes.first { $0.path == "nested/a.txt" }?.original, nil)
        XCTAssertEqual(changes.first { $0.path == "kept.txt" }?.original, "same\n")
        XCTAssertEqual(changes.first { $0.path == "kept.txt" }?.isDeletion, true)
    }

    private func makeSettings() -> IDEAgentSettings {
        IDEAgentSettings(defaults: UserDefaults(suiteName: "umbra.acp.registry.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
    }
}

@MainActor
private final class NativeCallFlag {
    var called = false
}

@MainActor
private final class RegistryHost: IDEAgentHost {
    var agentProjectRoot: URL?
    init(root: URL?) { agentProjectRoot = root }
    func agentUnsavedBuffers() -> [String: String] { [:] }
    func agentEditorContext() -> String { "" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {}
    func agentCreateFile(relativePath: String, contents: String) async throws {}
    func agentTrashFile(relativePath: String) async throws {}
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { [:] }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome { .notStarted("no") }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}
