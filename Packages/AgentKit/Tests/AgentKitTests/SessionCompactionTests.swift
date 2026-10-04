import Foundation
import Testing
@testable import AgentKit

/// A read-only tool that answers with a fixed amount of text, to fill a window on purpose.
private struct BulkTool: AgentTool {
    let characters: Int
    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(name: "bulk", description: "bulk", parameters: [ToolParameter("n", .integer, "n", optional: true)])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let n = try arguments.optionalInt("n") ?? 0
        return "output \(n)\n" + String(repeating: "x", count: characters)
    }
}

/// Answers the summarizing request on its own (recognized by its system prompt) and everything else from
/// a script, so a test does not depend on exactly when compaction fires.
private final class SummarizingClient: LLMClient, @unchecked Sendable {
    let providerID = "mock"
    let inner: MockLLMClient
    let summary: Result<String, LLMError>
    private let lock = NSLock()
    private var summaries: [LLMRequest] = []

    init(turns: [MockTurn], summary: Result<String, LLMError>) {
        inner = MockLLMClient(turns: turns)
        self.summary = summary
    }

    var summaryRequests: [LLMRequest] { lock.withLock { summaries } }
    var turnRequests: [LLMRequest] { inner.requests }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        guard request.system == ConversationSummary.systemPrompt else { return inner.stream(request) }
        lock.withLock { summaries.append(request) }
        let result = summary
        return AsyncThrowingStream { continuation in
            switch result {
            case .success(let text):
                continuation.yield(.textDelta(text))
                continuation.yield(.finished(.completed))
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

private func call(_ n: Int) -> MockTurn {
    .toolCalls((id: "c\(n)", name: "bulk", arguments: #"{"n":\#(n)}"#))
}

private func session(
    _ client: any LLMClient, window: Int?, characters: Int = 2_400, threshold: Double = 0.75
) throws -> AgentSession {
    AgentSession(
        client: client, tools: [BulkTool(characters: characters)], workspace: try TempProject().workspace,
        configuration: AgentConfiguration(model: "m", systemPrompt: "sys", contextWindow: window, compactionThreshold: threshold))
}

private func run(_ session: AgentSession) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await session.send("go") { events.append(event) }
    return events
}

private func reports(_ events: [AgentEvent]) -> [CompactionReport] {
    events.compactMap { if case .compacted(let report) = $0 { report } else { nil } }
}

private func outputs(_ items: [ConversationItem]) -> [String] {
    items.compactMap { if case .toolOutput(_, let text) = $0 { text } else { nil } }
}

@Suite struct SessionCompactionTests {
    @Test func oldToolOutputsBecomeStubsBeforeTheWindowFillsAndTheNewestStayWhole() async throws {
        // Each output is about 600 tokens; a 4_000-token window passes 75% after four of them.
        let client = MockLLMClient(turns: (1...7).map(call) + [.text("done")])
        let agent = try session(client, window: 4_000)
        let events = await run(agent)

        #expect(events.last == .runEnded(.completed))
        let report = try #require(reports(events).first)
        #expect(report.stubbedOutputs > 0 && report.summarizedItems == 0)
        #expect(report.estimatedTokensAfter < report.estimatedTokensBefore)

        let final = outputs(client.requests.last!.items)
        #expect(final.prefix(2).allSatisfy(ToolOutputStubs.isStub), "the oldest are stubs")
        #expect(final.suffix(2).allSatisfy { !ToolOutputStubs.isStub($0) }, "the newest are whole")
        expectEveryCallAnswered(await agent.items)
        #expect(await agent.items.count == 1 + 7 * 2 + 1, "history keeps its shape: only text changed")
    }

    @Test func aTranscriptTheHostShowsIsNotTouchedByCompaction() async throws {
        let client = MockLLMClient(turns: (1...7).map(call) + [.text("done")])
        let events = await run(try session(client, window: 4_000))
        // The host built its transcript from events as they came; every tool call finished with its full output.
        let finished = events.compactMap { event -> String? in if case .toolCallFinished(_, _, let output) = event { output.text } else { nil } }
        #expect(finished.count == 7 && finished.allSatisfy { !ToolOutputStubs.isStub($0) })
    }

    @Test func whenStubsAreNotEnoughTheOldestPartIsSummarizedWithOneRequest() async throws {
        // About 610 tokens per output against a 2_500 window: three outputs already pass 75%, and
        // the newest four are never stubbed, so stubs cannot help.
        let client = SummarizingClient(turns: (1...6).map(call) + [.text("done")], summary: .success("We read files; nothing changed."))
        let agent = try session(client, window: 2_500)
        let events = await run(agent)

        #expect(events.last == .runEnded(.completed))
        let report = try #require(reports(events).first { $0.summarizedItems > 0 })
        #expect(report.estimatedTokensAfter < report.estimatedTokensBefore)

        // The summarizing request: no tools, its own system prompt, the older part as plain text.
        let ask = try #require(client.summaryRequests.first)
        #expect(ask.tools.isEmpty && ask.items.count == 1)
        guard case .user(let body) = ask.items[0] else { Issue.record("expected one user message"); return }
        #expect(body.contains("USER: go") && body.contains("ASSISTANT CALLS bulk"))

        // The turn after it starts from the summary, then the recent turns.
        let firstAfter = try #require(client.turnRequests.first { request in
            if case .user(let text)? = request.items.first { text.hasPrefix(ConversationSummary.heading) } else { false }
        })
        guard case .user(let head) = firstAfter.items[0] else { Issue.record("expected the summary first"); return }
        #expect(head.contains("We read files; nothing changed."))
        expectEveryCallAnswered(firstAfter.items)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func aSummaryThatCannotBeWrittenLeavesTheStubsAndTheRunGoesOn() async throws {
        let client = SummarizingClient(turns: (1...8).map(call) + [.text("done")], summary: .failure(.server(status: 500, message: "down")))
        let events = await run(try session(client, window: 2_500))
        #expect(events.last == .runEnded(.completed))
        let failed = try #require(reports(events).first { $0.summaryFailed })
        #expect(failed.summarizedItems == 0)
        // Still over the limit on the following turns, but it does not keep asking a failing model.
        #expect(client.summaryRequests.count >= 1 && client.summaryRequests.count <= 3, "\(client.summaryRequests.count) summary requests")
    }

    @Test func aContextLengthErrorFromTheProviderCompactsHardAndRetriesOnce() async throws {
        // Sized to stay under the 75% line (so nothing compacts by itself) until the provider says no.
        let client = MockLLMClient(turns: [
            call(1), call(2), call(3), call(4),
            MockTurn([], failure: .contextLengthExceeded),
            .text("done"),
        ])
        let agent = try session(client, window: 5_000, characters: 1_200)
        let events = await run(agent)

        #expect(events.last == .runEnded(.completed))
        let forced = try #require(reports(events).last)
        #expect(forced.changedAnything)
        #expect(client.requests.count == 6, "four calls, the refused turn, and its retry")
        #expect(ContextBudget.tokens(client.requests.last!.items) < ContextBudget.tokens(client.requests[4].items))
    }

    @Test func aSecondOverflowFailsInsteadOfLooping() async throws {
        let client = MockLLMClient(turns: [
            call(1), call(2), call(3), call(4),
            MockTurn([], failure: .contextLengthExceeded), MockTurn([], failure: .contextLengthExceeded), .text("never"),
        ])
        let events = await run(try session(client, window: 5_000, characters: 1_200))
        #expect(events.last == .runEnded(.failed(LLMError.contextLengthExceeded.localizedDescription)))
    }

    @Test func anOverflowWithNothingToShortenFailsAtOnce() async throws {
        let client = MockLLMClient(turns: [MockTurn([], failure: .contextLengthExceeded), .text("never")])
        let events = await run(try session(client, window: 5_000))
        #expect(events.last == .runEnded(.failed(LLMError.contextLengthExceeded.localizedDescription)))
        #expect(client.requests.count == 1)
    }

    @Test func withoutAWindowNothingIsEverCompacted() async throws {
        let client = MockLLMClient(turns: (1...7).map(call) + [.text("done")])
        let agent = try session(client, window: nil)
        let events = await run(agent)
        #expect(reports(events).isEmpty)
        #expect(outputs(await agent.items).allSatisfy { !ToolOutputStubs.isStub($0) })
    }

    @Test func theProvidersReportedInputTokensCountEvenWhenTheItemsLookSmall() async throws {
        // The provider says the prompt was already 9_000 tokens (system prompt, hidden context…).
        let client = MockLLMClient(turns: [
            MockTurn([
                .toolCallStarted(id: "c1", name: "bulk"), .toolCallFinished(id: "c1", name: "bulk", arguments: "{}"),
                .usage(TokenUsage(inputTokens: 9_000, outputTokens: 10)), .finished(.toolCalls),
            ]),
            call(2), call(3), call(4), call(5), call(6), .text("done"),
        ])
        let events = await run(try session(client, window: 10_000, characters: 3_000))
        let first = try #require(reports(events).first)
        #expect(first.estimatedTokensBefore >= 9_000, "\(first)")
    }

    @Test func aStoppedRunNeverCompactsHalfway() async throws {
        let client = MockLLMClient(turns: (1...3).map(call) + [.text("done")])
        let agent = try session(client, window: 4_000)
        let stream = await agent.send("go")
        await agent.stop()
        for await _ in stream {}
        expectEveryCallAnswered(await agent.items)
    }
}
