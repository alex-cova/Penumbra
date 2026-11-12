import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
private final class ManagedHost: IDEAgentHost {
    var agentProjectRoot: URL?
    init(root: URL?) { agentProjectRoot = root }
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

/// A real chat, a real process, and a managed adapter whose "node" is python3 and whose entry is
/// a fake ACP agent. Shows how updates, rollbacks and removals behave around running chats.
@MainActor
final class IDEACPManagedAdapterConversationTests: XCTestCase {
    private var root: ACPTestRoot!
    private var project: URL!
    private var saved: IDEACPAdapterManager!
    private var manager: IDEACPAdapterManager!
    private var controller: IDEAgentController!
    /// Conversations hold their host weakly, so the test keeps it alive.
    private var host: ManagedHost!

    override func setUp() async throws {
        saved = IDEACPAdapterManager.shared
        root = try ACPTestRoot()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-managed-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let registry = IDEACPNpmRegistry(fetcher: ACPFixtureFetcher())
        let installer = IDEACPAdapterInstaller(environment: .init(
            store: root.store, registry: registry, npm: ACPFakeNpm(packages: []), locateNode: { nil },
            smokeTest: { _ in .failed("not used") }))
        manager = IDEACPAdapterManager(
            store: root.store, registry: registry, installer: installer,
            defaults: UserDefaults(suiteName: "umbra.acp.managed.\(UUID().uuidString)")!, isSandboxed: false)
        IDEACPAdapterManager.shared = manager
    }

    override func tearDown() async throws {
        controller?.teardown()
        IDEACPAdapterManager.shared = saved
        root.cleanUp()
        try? FileManager.default.removeItem(at: project)
    }

    private func makeController() throws -> (IDEAgentController, IDEAgentSettings, IDEACPDefinition, URL) {
        let defaults = UserDefaults(suiteName: "umbra.acp.managed.settings.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .mlx
        let pid = project.appendingPathComponent("agent.pid")
        var row = settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        settings.acpAgents[0].env["FAKE_PID_FILE"] = pid.path
        row = settings.acpAgents[0]
        settings.setACPAllowed(true, agentID: row.id)
        settings.acpActiveAgentID = row.id
        let controller = IDEAgentController(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        host = ManagedHost(root: project)
        controller.attach(host: host)
        self.controller = controller
        return (controller, settings, row, pid)
    }

    private func assistantText(_ chat: IDEAgentConversation) -> String {
        chat.entries.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n")
    }

    private func send(_ chat: IDEAgentConversation, _ text: String, expecting reply: String, occurrences: Int = 1) async -> Bool {
        chat.submit(text: text)
        return await acpWaitUntil(20) {
            !chat.isRunning && self.assistantText(chat).components(separatedBy: reply).count - 1 >= occurrences
        }
    }

    private func pid(_ url: URL) -> Int32 {
        Int32((try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func testARunningChatKeepsItsVersionThroughAnUpdateAndNewProcessesGetTheNewOne() async throws {
        try acpInstallFakeAgent(root.store, version: "1.0.0", reply: "Hello from v1")
        await manager.load()
        let (controller, _, _, pidFile) = try makeController()
        let chat = controller.selected

        let first = await send(chat, "hi", expecting: "Hello from v1")
        XCTAssertTrue(first, "\(chat.entries.map { "\($0.kind):\($0.text)" })")
        XCTAssertEqual(chat.acpLiveState, .connected)
        let firstPid = pid(pidFile)
        XCTAssertGreaterThan(firstPid, 0)
        XCTAssertTrue(root.leases.isLeased(adapterID: "codex-acp", version: "1.0.0"), "the running process holds its version")

        // A newer version is installed and activated while the chat is open.
        try acpInstallFakeAgent(root.store, version: "2.0.0", reply: "Hello from v2")
        await manager.load()
        XCTAssertEqual(manager.states["codex-acp"]?.activeVersion, "2.0.0")
        XCTAssertThrowsError(try root.store.removeVersion("codex-acp", version: "1.0.0"), "the running version cannot be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.store.versionDirectory("codex-acp", "1.0.0").path))

        // The same chat keeps talking to the same process: no silent switch mid-conversation.
        let second = await send(chat, "again", expecting: "Hello from v1", occurrences: 2)
        XCTAssertTrue(second)
        XCTAssertEqual(pid(pidFile), firstPid, "same process, so the version did not change under the conversation")
        XCTAssertFalse(assistantText(chat).contains("Hello from v2"))
        XCTAssertFalse(chat.entries.contains { $0.text.contains("adapter is now") })

        // A new process (restart) uses the new version, and says so.
        chat.restartACP()
        let third = await send(chat, "after restart", expecting: "Hello from v2")
        XCTAssertTrue(third, "\(chat.entries.map { "\($0.kind):\($0.text)" })")
        XCTAssertNotEqual(pid(pidFile), firstPid)
        XCTAssertTrue(
            chat.entries.contains { $0.kind == .notice && $0.text.contains("adapter is now 2.0.0") && $0.text.contains("1.0.0") },
            "\(chat.entries.map { "\($0.kind):\($0.text)" })")
        XCTAssertTrue(root.leases.isLeased(adapterID: "codex-acp", version: "2.0.0"))
        let released = await acpWaitUntil { !self.root.leases.isLeased(adapterID: "codex-acp", version: "1.0.0") }
        XCTAssertTrue(released, "the old version is free once its process has exited")
        XCTAssertNoThrow(try root.store.removeVersion("codex-acp", version: "1.0.0"))
    }

    func testRollbackAppliesToTheNextProcessOnly() async throws {
        try acpInstallFakeAgent(root.store, version: "1.0.0", reply: "Hello from v1")
        try acpInstallFakeAgent(root.store, version: "2.0.0", reply: "Hello from v2")
        await manager.load()
        let (controller, _, _, _) = try makeController()
        let chat = controller.selected
        let onNew = await send(chat, "hi", expecting: "Hello from v2")
        XCTAssertTrue(onNew)

        try await manager.restorePrevious("codex-acp")
        XCTAssertEqual(root.store.activeInstall("codex-acp")?.version, "1.0.0")
        let stillNew = await send(chat, "more", expecting: "Hello from v2", occurrences: 2)
        XCTAssertTrue(stillNew, "restoring does not move a running chat")

        chat.restartACP()
        let rolledBack = await send(chat, "restart", expecting: "Hello from v1")
        XCTAssertTrue(rolledBack)
        XCTAssertTrue(chat.entries.contains { $0.kind == .notice && $0.text.contains("adapter is now 1.0.0") })
    }

    func testTwoChatsOnTheSameAdapterShareNothingAndNativeChatsAreUntouched() async throws {
        try acpInstallFakeAgent(root.store, version: "1.0.0", reply: "Hello from v1")
        await manager.load()
        let (controller, _, row, _) = try makeController()
        let codexChat = controller.selected
        let ok = await send(codexChat, "first chat", expecting: "Hello from v1")
        XCTAssertTrue(ok)

        controller.selectProvider(.native)
        let nativeChat = controller.selected
        XCTAssertNotEqual(nativeChat.id, codexChat.id)
        XCTAssertFalse(nativeChat.isACPConversation, "a native chat never launches an adapter")
        XCTAssertNil(nativeChat.resolvedACPAgentID)
        XCTAssertFalse(nativeChat.entries.contains { $0.text.contains("Hello from") || $0.text.contains("first chat") })
        XCTAssertEqual(nativeChat.effectiveChoice.provider, .mlx)
        XCTAssertEqual(codexChat.resolvedACPAgentID, row.id)
        XCTAssertEqual(root.leases.count(adapterID: "codex-acp", version: "1.0.0"), 1, "only the Codex chat holds the adapter")

        controller.selectProvider(.agent(row.id))
        let secondCodex = controller.selected
        XCTAssertNotEqual(secondCodex.id, codexChat.id)
        XCTAssertFalse(secondCodex.entries.contains { $0.kind == .user }, "a new Codex chat starts empty")
        let second = await send(secondCodex, "second chat", expecting: "Hello from v1")
        XCTAssertTrue(second)
        XCTAssertFalse(assistantText(secondCodex).contains("first chat"))
        XCTAssertFalse(codexChat.entries.contains { $0.text.contains("second chat") })
        XCTAssertEqual(root.leases.count(adapterID: "codex-acp", version: "1.0.0"), 2, "each chat has its own process")
    }

    func testAChatAgainstAMissingAdapterFailsWithAnActionableMessageAndNoDownload() async throws {
        await manager.load()
        let (controller, _, _, _) = try makeController()
        let chat = controller.selected
        chat.submit(text: "hi")
        let failed = await acpWaitUntil { !chat.isRunning && chat.entries.contains { $0.kind == .error } }
        XCTAssertTrue(failed)
        let message = chat.entries.filter { $0.kind == .error }.map(\.text).joined()
        XCTAssertTrue(message.contains("not installed"), message)
        XCTAssertTrue(message.contains("Settings"), message)
        XCTAssertEqual(chat.acpLiveState, .failed(IDEACPLaunchUnavailable.notInstalled("Codex").message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.store.adapterDirectory("codex-acp").path), "nothing was created")
    }

    func testATamperedManagedEntryIsRefusedAtLaunch() async throws {
        let manifest = try acpInstallFakeAgent(root.store, version: "1.0.0", reply: "Hello from v1")
        await manager.load()
        let entry = root.store.versionDirectory("codex-acp", "1.0.0").appendingPathComponent(manifest.entryRelativePath)
        try acpFakeAgentScript(reply: "Hello from an impostor").write(to: entry, atomically: true, encoding: .utf8)
        let (controller, _, _, _) = try makeController()
        let chat = controller.selected
        chat.submit(text: "hi")
        let failed = await acpWaitUntil { !chat.isRunning && chat.entries.contains { $0.kind == .error } }
        XCTAssertTrue(failed)
        XCTAssertFalse(assistantText(chat).contains("impostor"))
        XCTAssertTrue(chat.entries.filter { $0.kind == .error }.map(\.text).joined().contains("changed after it was installed"))
        XCTAssertFalse(root.leases.isLeased(adapterID: "codex-acp", version: "1.0.0"), "a refused launch holds no lease")
    }
}
