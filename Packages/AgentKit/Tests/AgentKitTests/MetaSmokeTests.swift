import Foundation
import Testing
@testable import AgentKit

/// Opt-in, against the real Meta Model API: `AGENTKIT_META_KEY=... swift test --filter MetaSmokeTests`
/// (`AGENTKIT_META_MODEL` picks the model; the default is the current Muse Spark). These spend a few
/// cents and check the wire, not the model's intelligence: Meta speaks the Responses format with a
/// Bearer key, so this is `OpenAIResponsesClient` at `api.meta.ai` — the same client Umbra builds
/// for its Meta provider.
@Suite(.enabled(if: PaidTests.allowed("AGENTKIT_META_KEY")), .serialized)
struct MetaSmokeTests {
    private var model: String { PaidTests.value("AGENTKIT_META_MODEL") ?? "muse-spark-1.3" }
    private var client: OpenAIResponsesClient {
        OpenAIResponsesClient(endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: PaidTests.value("AGENTKIT_META_KEY")))
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
        let bad = OpenAIResponsesClient(
            endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: "not-a-real-key"), retry: .none)
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
