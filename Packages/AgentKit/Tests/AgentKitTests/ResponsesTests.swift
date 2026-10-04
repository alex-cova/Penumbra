import Foundation
import Testing
@testable import AgentKit

// Fixtures are hand-written from the Responses API event reference.
private enum Fixture {
    static let textTurn = sse(
        #"{"type":"response.created","response":{"id":"resp_1"}}"#,
        #"{"type":"response.output_item.added","item":{"type":"message","id":"msg_1"}}"#,
        #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Hel"}"#,
        #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"lo"}"#,
        #"{"type":"response.some_future_event","x":1}"#,
        #"{"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":9,"input_tokens_details":{"cached_tokens":64},"output_tokens_details":{"reasoning_tokens":4}}}}"#)

    /// Two parallel calls whose argument deltas interleave, and a reasoning item before them.
    static let toolTurn = sse(
        #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}"#,
        #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"Looking"}"#,
        #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"abc","summary":[]}}"#,
        #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_A","name":"read_file"}}"#,
        #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","call_id":"call_B","name":"grep"}}"#,
        #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"path\":"}"#,
        #"{"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\"q\":\"x\"}"}"#,
        #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\"A.java\"}"}"#,
        #"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"path\":\"A.java\"}"}"#,
        #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_A","name":"read_file","arguments":"{\"path\":\"A.java\"}"}}"#,
        #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_2","call_id":"call_B","name":"grep","arguments":"{\"q\":\"x\"}"}}"#,
        #"{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":5}}}"#)
}

@Suite struct ResponsesEventDecoderTests {
    private func decode(_ lines: [String]) throws -> [LLMEvent] {
        var decoder = ResponsesEventDecoder()
        let parser = SSELineParser()
        var events: [LLMEvent] = []
        for line in lines {
            if case .data(let payload) = parser.parse(line: line) { events += try decoder.events(forPayload: payload) }
        }
        return events
    }

    @Test func decodesTextUsageAndSkipsUnknownEvents() throws {
        #expect(try decode(Fixture.textTurn) == [
            .textDelta("Hel"), .textDelta("lo"),
            .usage(TokenUsage(inputTokens: 120, outputTokens: 9, cachedInputTokens: 64, reasoningTokens: 4)),
            .finished(.completed),
        ])
    }

    @Test func interleavedParallelCallsKeepTheirOwnArguments() throws {
        let events = try decode(Fixture.toolTurn)
        #expect(events.contains(.toolCallStarted(id: "call_A", name: "read_file")))
        #expect(events.contains(.toolCallStarted(id: "call_B", name: "grep")))
        #expect(events.contains(.toolCallArgumentsDelta(id: "call_A", delta: "\"A.java\"}")))
        #expect(events.contains(.toolCallArgumentsDelta(id: "call_B", delta: #"{"q":"x"}"#)))
        #expect(events.contains(.toolCallFinished(id: "call_A", name: "read_file", arguments: #"{"path":"A.java"}"#)))
        #expect(events.contains(.toolCallFinished(id: "call_B", name: "grep", arguments: #"{"q":"x"}"#)))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func reasoningItemsComeBackWholeAsOpaqueItems() throws {
        let events = try decode(Fixture.toolTurn)
        #expect(events.contains(.reasoningDelta("Looking")))
        let opaque = events.compactMap { event -> OpaqueItem? in
            if case .opaqueItem(let item) = event { item } else { nil }
        }
        #expect(opaque.count == 1)
        #expect(opaque[0].provider == "openai-responses")
        #expect(opaque[0].payload["encrypted_content"] == "abc")
    }

    @Test func reasoningWithoutEncryptedContentIsDroppedBecauseItCannotBeReplayed() throws {
        let events = try decode(sse(
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_9","summary":[]}}"#))
        #expect(events.isEmpty)
    }

    @Test func incompleteMapsToLengthOrContentFilter() throws {
        let length = try decode(sse(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#))
        #expect(length == [.finished(.length)])
        let filtered = try decode(sse(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#))
        #expect(filtered == [.finished(.contentFilter)])
    }

    @Test func failedAndErrorEventsThrow() {
        #expect(throws: LLMError.api(message: "boom", code: "server_error")) {
            try decode(sse(#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}"#))
        }
        #expect(throws: LLMError.api(message: "bad", code: nil)) {
            try decode(sse(#"{"type":"error","message":"bad"}"#))
        }
    }

    @Test func garbageThrowsMalformedEvent() {
        #expect(throws: LLMError.malformedEvent("Invalid JSON in stream event.")) {
            try decode(["data: {not json"])
        }
    }
}

@Suite struct ResponsesRequestEncoderTests {
    private let tool = ToolDefinition(
        name: "read_file", description: "Read.", parameters: [ToolParameter("path", .string, "Path.")])

    private func body(_ request: LLMRequest) throws -> JSONValue {
        try JSONValue(parsing: String(decoding: ResponsesRequestEncoder.body(for: request), as: UTF8.self))
    }

    @Test func rendersAStatelessStreamingRequest() throws {
        let request = LLMRequest(
            model: "gpt-5", system: "Be brief.",
            items: [
                .user("hi"),
                .toolCall(id: "call_1", name: "read_file", arguments: #"{"path":"A"}"#),
                .toolOutput(callID: "call_1", output: "contents"),
                .assistant("done"),
            ],
            tools: [tool], reasoningEffort: "medium", maxOutputTokens: 4000, cacheKey: "session-1")
        let json = try body(request)
        #expect(json["model"] == "gpt-5")
        #expect(json["stream"] == true)
        #expect(json["store"] == false)
        #expect(json["instructions"] == "Be brief.")
        #expect(json["include"] == ["reasoning.encrypted_content"])
        #expect(json["reasoning"]?["effort"] == "medium")
        #expect(json["max_output_tokens"] == 4000)
        #expect(json["prompt_cache_key"] == "session-1")
        #expect(json["previous_response_id"] == nil)

        let input = try #require(json["input"]?.arrayValue)
        #expect(input[0] == ["role": "user", "content": "hi"])
        #expect(input[1]["type"] == "function_call")
        #expect(input[1]["call_id"] == "call_1")
        #expect(input[2] == ["type": "function_call_output", "call_id": "call_1", "output": "contents"])
        #expect(input[3] == ["role": "assistant", "content": "done"])

        let rendered = try #require(json["tools"]?.arrayValue?.first)
        #expect(rendered["type"] == "function")
        #expect(rendered["strict"] == true)
        #expect(rendered["parameters"]?["additionalProperties"] == false)
    }

    @Test func omitsReasoningFieldsForNonReasoningModels() throws {
        let json = try body(LLMRequest(model: "gpt-4.1", items: [.user("hi")]))
        #expect(json["reasoning"] == nil)
        #expect(json["include"] == nil)
        #expect(json["instructions"] == nil)
        #expect(json["tools"] == nil)
    }

    @Test func replaysOnlyItsOwnOpaqueItems() throws {
        let mine = OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning", "id": "rs_1"])
        let foreign = OpaqueItem(provider: "someone-else", payload: ["type": "reasoning", "id": "x"])
        let json = try body(LLMRequest(model: "m", items: [.opaque(foreign), .user("hi"), .opaque(mine)]))
        let input = try #require(json["input"]?.arrayValue)
        #expect(input.count == 2)
        #expect(input[1]["id"] == "rs_1")
    }

    @Test func bodyIsByteIdenticalAcrossEncodings() throws {
        let tools = (0..<8).map {
            ToolDefinition(name: "tool\($0)", description: "d", parameters: [
                ToolParameter("a", .string, "a"), ToolParameter("b", .integer, "b", optional: true),
            ])
        }
        let request = LLMRequest(model: "m", system: "s", items: [.user("hi")], tools: tools)
        let first = try ResponsesRequestEncoder.body(for: request)
        for _ in 0..<20 { #expect(try ResponsesRequestEncoder.body(for: request) == first) }
    }
}

@Suite struct OpenAIResponsesClientTests {
    private let request = LLMRequest(model: "gpt-5", items: [.user("hi")])

    private func client(_ transport: StubTransport, retry: RetryPolicy = fastRetry) -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            endpoint: LLMEndpoint(baseURL: URL(string: "https://example.test/v1")!, apiKey: "sk-test"),
            transport: transport, retry: retry)
    }

    @Test func streamsATurnAndSendsAuthorizedJSON() async throws {
        let transport = StubTransport([.response(status: 200, lines: Fixture.textTurn)])
        let events = try await collect(client(transport).stream(request))
        #expect(events.first == .textDelta("Hel"))
        #expect(events.last == .finished(.completed))

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://example.test/v1/responses")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func appliesExtraHeadersAndQueryItems() async throws {
        let transport = StubTransport([.response(status: 200, lines: Fixture.textTurn)])
        let azure = OpenAIResponsesClient(
            endpoint: LLMEndpoint(
                baseURL: URL(string: "https://res.openai.azure.com/openai/v1")!, apiKey: nil,
                extraHeaders: ["api-key": "azure-secret"], queryItems: [URLQueryItem(name: "api-version", value: "2025-04-01")]),
            transport: transport, retry: .none)
        _ = try await collect(azure.stream(request))
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://res.openai.azure.com/openai/v1/responses?api-version=2025-04-01")
        #expect(sent.value(forHTTPHeaderField: "api-key") == "azure-secret")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func retriesA429AndTellsTheConsumerToDropTheTurn() async throws {
        let transport = StubTransport([
            .response(status: 429, headers: ["retry-after": "0"], lines: [#"{"error":{"message":"slow"}}"#]),
            .response(status: 200, lines: Fixture.textTurn),
        ])
        let events = try await collect(client(transport).stream(request))
        #expect(events.first == .retrying(attempt: 1, after: 0.001))
        #expect(events.last == .finished(.completed))
        #expect(transport.requests.count == 2)
    }

    @Test func aDroppedConnectionMidStreamResendsTheWholeTurn() async throws {
        let transport = StubTransport([
            .response(status: 200, lines: Array(Fixture.textTurn.prefix(3)), failure: URLError(.networkConnectionLost)),
            .response(status: 200, lines: Fixture.textTurn),
        ])
        let events = try await collect(client(transport).stream(request))
        let retryIndex = try #require(events.firstIndex(of: .retrying(attempt: 1, after: 0.001)))
        // Everything before the marker is the discarded partial turn; the full turn follows it.
        #expect(retryIndex > 0)
        #expect(Array(events[(retryIndex + 1)...]).first == .textDelta("Hel"))
        #expect(events.last == .finished(.completed))
    }

    @Test func aStreamThatEndsEarlyCountsAsAConnectionLoss() async throws {
        let transport = StubTransport([.response(status: 200, lines: Array(Fixture.textTurn.prefix(3)))])
        await #expect(throws: LLMError.connectionLost("The stream ended before the response completed.")) {
            _ = try await collect(client(transport, retry: .none).stream(request))
        }
    }

    @Test func unauthorizedIsFinalAndNotRetried() async throws {
        let transport = StubTransport([.response(status: 401, lines: [#"{"error":{"message":"bad key"}}"#])])
        await #expect(throws: LLMError.unauthorized) {
            _ = try await collect(client(transport).stream(request))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func contextOverflowIsReportedForTheLoopToCompact() async throws {
        let transport = StubTransport([
            .response(status: 400, lines: [#"{"error":{"code":"context_length_exceeded","message":"too long"}}"#])
        ])
        await #expect(throws: LLMError.contextLengthExceeded) {
            _ = try await collect(client(transport).stream(request))
        }
    }

    @Test func givesUpAfterTheRetryLimit() async throws {
        let transport = StubTransport(Array(repeating: .response(status: 503, lines: ["overloaded"]), count: 5))
        await #expect(throws: LLMError.server(status: 503, message: "overloaded\n")) {
            _ = try await collect(client(transport).stream(request))
        }
        #expect(transport.requests.count == 4)
    }

    @Test func cancellingTheConsumerStopsTheRequest() async throws {
        let transport = StubTransport([.response(status: 200, lines: Fixture.textTurn)])
        let task = Task { try await collect(client(transport).stream(request)) }
        task.cancel()
        _ = try? await task.value
        #expect(transport.requests.count <= 1)
    }
}

/// Opt-in: `AGENTKIT_OPENAI_KEY=sk-... swift test --filter OpenAISmokeTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_OPENAI_KEY"] != nil))
struct OpenAISmokeTests {
    @Test func streamsTextFromTheRealAPI() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["AGENTKIT_OPENAI_KEY"])
        let model = ProcessInfo.processInfo.environment["AGENTKIT_OPENAI_MODEL"] ?? "gpt-4.1-mini"
        let client = OpenAIResponsesClient(endpoint: LLMEndpoint(baseURL: LLMEndpoint.openAI.baseURL, apiKey: key))
        let events = try await collect(client.stream(LLMRequest(model: model, items: [.user("Reply with the single word: pong")])))
        let text = events.compactMap { event -> String? in if case .textDelta(let t) = event { t } else { nil } }.joined()
        #expect(text.lowercased().contains("pong"))
        #expect(events.last == .finished(.completed))
    }
}
