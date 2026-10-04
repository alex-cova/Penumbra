import Foundation
import Testing
@testable import AgentKit

private func makeStore() -> (SessionStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)", isDirectory: true)
    return (SessionStore(directory: directory), directory)
}

private func snapshot(_ root: String = "/proj/a", title: String = "Fix the build", at date: Date = Date(), id: UUID = UUID()) -> SessionSnapshot {
    SessionSnapshot(
        id: id, projectRoot: root, title: title, createdAt: date, updatedAt: date,
        items: [
            .user("fix it"), .assistant("Looking."), .toolCall(id: "c1", name: "read_file", arguments: #"{"path":"A.java"}"#),
            .toolOutput(callID: "c1", output: "contents"),
            .opaque(OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning", "encrypted_content": "abc"])),
        ],
        totalUsage: TokenUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 50), host: Data("transcript".utf8))
}

@Suite struct SessionStoreTests {
    @Test func aSavedSessionComesBackExactly() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = snapshot(at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(original)
        let loaded = try #require(store.load(original.id, projectRoot: original.projectRoot))
        #expect(loaded == original)
        #expect(loaded.items.count == 5 && loaded.host == Data("transcript".utf8))
    }

    @Test func sessionsAreKeptPerProjectAndListedNewestFirst() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = snapshot("/proj/a", title: "old", at: Date(timeIntervalSince1970: 1_000))
        let new = snapshot("/proj/a", title: "new", at: Date(timeIntervalSince1970: 2_000))
        let other = snapshot("/proj/b", title: "other project")
        for item in [old, new, other] { try store.save(item) }

        #expect(store.list(projectRoot: "/proj/a").map(\.title) == ["new", "old"])
        #expect(store.list(projectRoot: "/proj/b").map(\.title) == ["other project"])
        #expect(store.list(projectRoot: "/proj/none").isEmpty)
        #expect(store.load(new.id, projectRoot: "/proj/b") == nil, "another project's folder never answers")
    }

    @Test func savingAgainReplacesTheSameSession() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = snapshot()
        try store.save(item)
        item.items.append(.user("and also this"))
        item.updatedAt = Date().addingTimeInterval(10)
        try store.save(item)
        #expect(store.list(projectRoot: item.projectRoot).count == 1)
        #expect(store.load(item.id, projectRoot: item.projectRoot)?.items.count == 6)
    }

    @Test func filesAreOwnerOnlyAndHoldNoCredential() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = snapshot()
        try store.save(item)
        let file = store.projectDirectory(for: item.projectRoot).appendingPathComponent("\(item.id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        // The shape is the history and the host blob; there is nowhere to put a key.
        let keys = Set(((try JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]).keys)
        #expect(keys == ["version", "id", "projectRoot", "title", "createdAt", "updatedAt", "items", "totalUsage", "host"])
    }

    @Test func deletingOneOrAllWorks() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = snapshot("/p", title: "a"), b = snapshot("/p", title: "b"), other = snapshot("/q", title: "q")
        for item in [a, b, other] { try store.save(item) }
        store.delete(a.id, projectRoot: "/p")
        #expect(store.list(projectRoot: "/p").map(\.title) == ["b"])
        store.deleteAll(projectRoot: "/p")
        #expect(store.list(projectRoot: "/p").isEmpty)
        #expect(store.list(projectRoot: "/q").count == 1, "Clear History is per project")
    }

    @Test func unreadableAndNewerVersionFilesAreSkippedNotFatal() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = snapshot(title: "good")
        try store.save(good)
        let folder = store.projectDirectory(for: good.projectRoot)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString).json"))
        var future = snapshot(title: "from the future")
        future.version = SessionSnapshot.currentVersion + 1
        try store.save(future)

        #expect(store.list(projectRoot: good.projectRoot).map(\.title) == ["good"])
        #expect(store.load(future.id, projectRoot: future.projectRoot) == nil)
    }

    @Test func titlesComeFromTheFirstRealUserLine() {
        #expect(SessionStore.title(from: [.user("Fix the failing test in Calc")]) == "Fix the failing test in Calc")
        #expect(SessionStore.title(from: [.user("[Editor state, for orientation only]\nActive file: A.java\n[End editor state]\n\nrename foo to bar")]) == "rename foo to bar")
        #expect(SessionStore.title(from: [.user(String(repeating: "x", count: 200))]).count == 61)
        #expect(SessionStore.title(from: []) == "New conversation")
    }

    @Test func aRestoredSessionKeepsItsIdentityHistoryAndUsage() async throws {
        let item = snapshot()
        let project = try TempProject()
        let client = MockLLMClient(turns: [.text("ok")])
        let agent = AgentSession(
            client: client, tools: [], workspace: project.workspace, configuration: AgentConfiguration(model: "m"),
            history: item.items, totalUsage: item.totalUsage, sessionID: item.id)
        let (id, restoredItems, usage) = (await agent.sessionID, await agent.items, await agent.totalUsage)
        #expect(id == item.id && restoredItems == item.items && usage == item.totalUsage)
        var events: [AgentEvent] = []
        for await event in await agent.send("continue") { events.append(event) }
        #expect(client.requests[0].items.prefix(5).elementsEqual(item.items), "the model sees the restored history, then the new message")
        #expect(events.last == .runEnded(.completed))
    }
}
