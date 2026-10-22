import Foundation
import Testing
@testable import AgentKit

/// Opt-in, against the real API: `AGENTKIT_ANTHROPIC_KEY=sk-ant-... swift test --filter AnthropicSmokeTests`
/// (`AGENTKIT_ANTHROPIC_MODEL` picks the model; the default is the cheapest current one). These spend a few
/// cents and check the wire, not the model's intelligence: the headers, the stream, a thinking block replayed
/// across a tool round trip, and the usage counts.
@Suite(.enabled(if: PaidTests.allowed("AGENTKIT_ANTHROPIC_KEY")), .serialized)
struct AnthropicSmokeTests {
    private var model: String { PaidTests.value("AGENTKIT_ANTHROPIC_MODEL") ?? "claude-haiku-5-5" }
    private var client: AnthropicMessagesClient {
        AnthropicMessagesClient(endpoint: LLMEndpoint(baseURL: LLMEndpoint.anthropic.baseURL, apiKey: PaidTests.value("AGENTKIT_ANTHROPIC_KEY")))
    }

    @Test func streamsRealTextWithUsage() async throws {
        let events = try await collect(client.stream(LLMRequest(
            model: model, items: [.user("Reply with exactly the word: pong")], maxOutputTokens: 200)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.lowercased().contains("pong"), "\(text)")
        #expect(events.last == .finished(.completed))
        let usage = events.compactMap { event -> TokenUsage? in if case .usage(let u) = event { u } else { nil } }.first
        #expect((usage?.inputTokens ?? 0) > 0 && (usage?.outputTokens ?? 0) > 0)
    }

    @Test func aRejectedKeyIsReportedAsUnauthorized() async throws {
        let bad = AnthropicMessagesClient(endpoint: LLMEndpoint(baseURL: LLMEndpoint.anthropic.baseURL, apiKey: "sk-ant-not-a-key"), retry: .none)
        await #expect(throws: LLMError.unauthorized) {
            _ = try await collect(bad.stream(LLMRequest(model: model, items: [.user("hi")], maxOutputTokens: 20)))
        }
    }

    @Test func aRealToolCallRoundTripThroughTheSession() async throws {
        let project = try TempProject(files: ["NOTES.md": "The secret word is PELICAN.\n"])
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(
                model: model, systemPrompt: SystemPrompt.make(projectRoot: project.workspace.rootPath), reasoningEffort: "low", maxOutputTokens: 4_000))
        var events: [AgentEvent] = []
        for await event in await session.send("Read NOTES.md with the read_file tool and tell me the secret word.") { events.append(event) }

        #expect(events.last == .runEnded(.completed), "\(events.suffix(3))")
        #expect(events.contains { if case .toolCallStarted(_, "read_file") = $0 { true } else { false } })
        let answer = events.compactMap { if case .assistantMessage(let t) = $0 { t } else { nil } }.joined(separator: " ")
        #expect(answer.uppercased().contains("PELICAN"), "\(answer)")
        expectEveryCallAnswered(await session.items)
    }
}
