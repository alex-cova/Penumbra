import Foundation
import Testing
@testable import AgentKit

@Suite struct ReadConversationToolTests {
    private func context() async throws -> ToolContext {
        let project = try TempProject(files: [:])
        let log = CheckpointLog()
        let run = await log.beginRun(label: "test")
        return ToolContext(
            workspace: project.workspace, ledger: ReadLedger(), callID: "c",
            checkpoint: CheckpointScope(log: log, run: run))
    }

    private func tool(_ turns: [HandoffTurn]) -> ReadConversationTool {
        ReadConversationTool { turns }
    }

    private let sample: [HandoffTurn] = [
        HandoffTurn(role: .user, text: "Use Postgres, not SQLite."),
        HandoffTurn(role: .assistant, text: "Understood."),
        HandoffTurn(role: .activity, text: "  "),
        HandoffTurn(role: .user, text: "Keep the port at 5433."),
        HandoffTurn(role: .assistant, text: "Done."),
    ]

    @Test func readsMessagesByTheHandoffsNumbers() async throws {
        let output = await tool(sample).execute(argumentsJSON: #"{"from":3,"limit":1}"#, context: try await context())
        #expect(!output.isError)
        // The blank turn is not numbered, like in the handoff, so #3 is the third readable message.
        #expect(output.text.contains("#3 [user]\nKeep the port at 5433."))
        #expect(!output.text.contains("Understood."))
        #expect(output.text.contains("[1 more. Use from: 4 to continue.]"))
    }

    @Test func aQueryListsMatchingMessageNumbers() async throws {
        let output = await tool(sample).execute(argumentsJSON: #"{"query":"postgres"}"#, context: try await context())
        #expect(output.text.contains("#1 [user] Use Postgres, not SQLite."))
        #expect(!output.text.contains("#3"))
        let none = await tool(sample).execute(argumentsJSON: #"{"query":"redis"}"#, context: try await context())
        #expect(none.text.contains("No earlier message mentions"))
    }

    @Test func aLongMessageIsCutAndContinuesAtTheOffset() async throws {
        let long = String(repeating: "a", count: 30_000) + "THE END"
        let first = await tool([HandoffTurn(role: .assistant, text: long)])
            .execute(argumentsJSON: #"{"from":1}"#, context: try await context())
        #expect(!first.text.contains("THE END"))
        let match = try #require(first.text.firstMatch(of: /offset: (\d+)\./))
        let next = await tool([HandoffTurn(role: .assistant, text: long)])
            .execute(argumentsJSON: #"{"from":1,"offset":\#(match.1)}"#, context: try await context())
        #expect(next.text.hasSuffix("THE END\n\n"))
    }

    @Test func pastTheEndIsAnErrorAndNothingSavedSaysSo() async throws {
        let past = await tool(sample).execute(argumentsJSON: #"{"from":9}"#, context: try await context())
        #expect(past.isError)
        let empty = await tool([]).execute(argumentsJSON: "{}", context: try await context())
        #expect(empty.text.contains("No earlier messages"))
    }

    @Test func handoffMarkersNameTheToolAndTheNumbers() throws {
        let turns = (1...60).map { HandoffTurn(role: $0.isMultiple(of: 2) ? .assistant : .user, text: "m\($0) " + String(repeating: "x", count: 300)) }
        let handoff = try #require(ConversationHandoff.make(turns: turns, cap: 4_000, retrievalTool: ReadConversationTool.name))
        let marker = try #require(handoff.text.firstMatch(of: /left out \(messages (\d+)–(\d+)\); read_conversation\(from: (\d+)\) shows them/))
        #expect(marker.1 == "2")
        #expect(marker.3 == "2")
        // The newest message kept follows the gap, so the gap ends just before it.
        let end = Int(marker.2)!
        #expect(handoff.text.contains("m\(end + 1) "))
        #expect(!handoff.text.contains("m\(end) "))
        #expect(handoff.text.utf8.count <= 4_000)
    }
}
