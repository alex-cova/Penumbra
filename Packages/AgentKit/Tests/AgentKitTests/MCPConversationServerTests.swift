import Foundation
import Testing
@testable import AgentKit

@Suite struct MCPConversationServerTests {
    private let turns = [
        HandoffTurn(role: .user, text: "Use Postgres, not SQLite."),
        HandoffTurn(role: .assistant, text: "Understood."),
        HandoffTurn(role: .user, text: "Keep the port at 5433."),
    ]

    /// AgentKit's own MCP client against the server, over the in-memory pipe.
    private func connected() async throws -> (MCPClient, Task<Void, Never>) {
        let (clientSide, serverSide) = ACPInMemoryTransport.pair()
        let server = MCPConversationServer { [turns] in turns }
        let serving = Task { await server.serve(over: serverSide) }
        let client = MCPClient(transport: clientSide)
        try await client.start(timeout: .seconds(5))
        return (client, serving)
    }

    @Test func listsOneReadOnlyToolAndAnswersByTheHandoffsNumbers() async throws {
        let (client, serving) = try await connected()
        let tools = try await client.listTools(timeout: .seconds(5))
        #expect(tools.map(\.name) == [ReadConversationTool.name])
        #expect(tools.first?.readOnlyHint == true)

        let read = try await client.callTool(
            name: ReadConversationTool.name, arguments: .object(["from": 3, "limit": 1]), timeout: .seconds(5))
        #expect(!read.isError)
        #expect(read.text.contains("#3 [user]\nKeep the port at 5433."))

        let found = try await client.callTool(
            name: ReadConversationTool.name, arguments: .object(["query": "postgres"]), timeout: .seconds(5))
        #expect(found.text.contains("#1 [user] Use Postgres"))
        await client.close()
        await serving.value
    }

    @Test func aBadCallIsAnErrorResultAndAnUnknownToolIsRefused() async throws {
        let (client, serving) = try await connected()
        let past = try await client.callTool(
            name: ReadConversationTool.name, arguments: .object(["from": 99]), timeout: .seconds(5))
        #expect(past.isError)
        #expect(past.text.contains("past the end"))
        await #expect(throws: (any Error).self) {
            _ = try await client.callTool(name: "write_file", arguments: .object([:]), timeout: .seconds(5))
        }
        await client.close()
        await serving.value
    }

    @Test func theProtocolVersionFollowsTheClientWhenSupported() async {
        let server = MCPConversationServer { [] }
        let old = await server.handle(method: "initialize", params: .object(["protocolVersion": "2024-11-05"]))
        #expect((try? old.get())?["protocolVersion"]?.stringValue == "2024-11-05")
        let future = await server.handle(method: "initialize", params: .object(["protocolVersion": "2099-01-01"]))
        #expect((try? future.get())?["protocolVersion"]?.stringValue == MCPConversationServer.supportedProtocolVersions[0])
        let other = await server.handle(method: "resources/list", params: nil)
        #expect((try? other.get()) == nil)
    }

    @Test func theArchiveFileIsReadAtEachCallAndAMissingOneIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString).json")
        #expect(MCPConversationServer.turns(fromFile: url).isEmpty)
        try JSONEncoder().encode(turns).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MCPConversationServer.turns(fromFile: url) == turns)
    }
}
