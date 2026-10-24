import AgentKit
import Foundation
import Testing
@testable import AgentKitApple

/// Against the real model on this Mac. Opt-in, because it needs Apple Intelligence turned on:
///
///     AGENTKIT_APPLE_SMOKE=1 swift test --filter AppleSmokeTests
///
/// `AGENTKIT_APPLE_PCC_SMOKE=1` runs the same against Private Cloud Compute (macOS 27).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_APPLE_SMOKE"] != nil
    || ProcessInfo.processInfo.environment["AGENTKIT_APPLE_PCC_SMOKE"] != nil))
struct AppleSmokeTests {
    static var kind: AppleModelKind {
        ProcessInfo.processInfo.environment["AGENTKIT_APPLE_PCC_SMOKE"] != nil ? .privateCloudCompute : .onDevice
    }

    private func collect(_ client: AppleLLMClient, _ request: LLMRequest) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in client.stream(request) { events.append(event) }
        return events
    }

    private func answer(_ events: [LLMEvent]) -> String {
        events.compactMap { if case .textDelta(let value) = $0 { value } else { nil } }.joined()
    }

    @Test func reportsWhetherTheModelCanBeUsed() async {
        let status = AppleModelAvailability.status(for: Self.kind)
        let size = await AppleModelAvailability.contextSize(for: Self.kind)
        print("apple model status: \(status), context size: \(String(describing: size))")
    }

    @Test func aGreetingGetsAnAnswerThatEnds() async throws {
        try #require(AppleModelAvailability.status(for: Self.kind) == .available)
        let client = AppleLLMClient(kind: Self.kind)
        let events = try await collect(client, LLMRequest(model: "system", system: "Answer in one short sentence.", items: [.user("Say hello.")]))
        print("greeting: \(answer(events))")
        #expect(!answer(events).isEmpty)
        #expect(events.contains { if case .finished(.completed) = $0 { true } else { false } })
        #expect(events.contains { if case .usage(let usage) = $0 { usage.inputTokens > 0 } else { false } })
    }

    @Test func aSecondTurnReusesTheSession() async throws {
        try #require(AppleModelAvailability.status(for: Self.kind) == .available)
        let client = AppleLLMClient(kind: Self.kind)
        let first = try await collect(client, LLMRequest(model: "system", system: "Be brief.", items: [.user("My name is Ada. Reply with just OK.")]))
        let second = try await collect(client, LLMRequest(
            model: "system", system: "Be brief.", items: [.user("My name is Ada. Reply with just OK."), .assistant(answer(first)), .user("What is my name?")]))
        print("second turn: \(answer(second)) reuse=\(await client.host.lastReuse)")
        #expect(await client.host.lastReuse == .continued)
        // A fresh client given the same history (a rebuilt session) must also know the name.
        let rebuilt = try await collect(AppleLLMClient(kind: Self.kind), LLMRequest(
            model: "system", system: "Be brief.", items: [.user("My name is Ada. Reply with just OK."), .assistant(answer(first)), .user("What is my name?")]))
        print("rebuilt: \(answer(rebuilt))")
        #expect(answer(second).localizedCaseInsensitiveContains("ada"))
    }

    @Test func aToolCallRoundTripsThroughTheLoop() async throws {
        try #require(AppleModelAvailability.status(for: Self.kind) == .available)
        let client = AppleLLMClient(kind: Self.kind)
        let tool = ToolDefinition(
            name: "get_time", description: "Returns the current time of day. Always call it to answer questions about the time.",
            parameters: [ToolParameter("timezone", .string, "A timezone name such as UTC", optional: true)])
        var items: [ConversationItem] = [.user("What time is it? Use the tool.")]
        let first = try await collect(client, LLMRequest(model: "system", items: items, tools: [tool]))
        let calls = first.compactMap { event -> (String, String, String)? in
            if case .toolCallFinished(let id, let name, let arguments) = event { (id, name, arguments) } else { nil }
        }
        print("first turn: text=\(answer(first)) calls=\(calls)")
        try #require(!calls.isEmpty)
        #expect(first.contains { if case .finished(.toolCalls) = $0 { true } else { false } })
        let said = answer(first)
        if !said.isEmpty { items.append(.assistant(said)) }
        for call in calls { items.append(.toolCall(id: call.0, name: call.1, arguments: call.2)) }
        for call in calls { items.append(.toolOutput(callID: call.0, output: "It is 14:32 UTC.")) }
        let second = try await collect(client, LLMRequest(model: "system", items: items, tools: [tool]))
        print("second turn: \(answer(second))")
        #expect(answer(second).contains("14"))
        #expect(second.contains { if case .finished(.completed) = $0 { true } else { false } })
    }

    @Test func anOversizedPromptAsksForCompaction() async throws {
        try #require(AppleModelAvailability.status(for: Self.kind) == .available)
        let client = AppleLLMClient(kind: Self.kind)
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 20_000)
        await #expect(throws: LLMError.contextLengthExceeded) {
            _ = try await collect(client, LLMRequest(model: "system", items: [.user(big)]))
        }
    }
}
