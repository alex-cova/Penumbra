import Foundation
import Testing
@testable import AgentKit

private func text(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
}

private func reasoning(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }.joined()
}

private func opaques(_ events: [LLMEvent]) -> [OpaqueItem] {
    events.compactMap { if case .opaqueItem(let item) = $0 { item } else { nil } }
}

private let thinkingBlock: JSONValue = ["type": "thinking", "thinking": "Let me look.", "signature": "sig-1"]

// MARK: - Encoder

@Suite struct AnthropicEncoderTests {
    private let tool = ToolDefinition(name: "read_file", description: "Read.", parameters: [
        ToolParameter("path", .string, "Path."), ToolParameter("offset", .integer, "Start.", optional: true),
    ])

    private func json(_ request: LLMRequest) throws -> JSONValue {
        try JSONValue(parsing: String(decoding: AnthropicRequestEncoder.body(for: request), as: UTF8.self))
    }

    @Test func aPlainChatSendsNoToolsAndAlwaysSetsMaxTokens() throws {
        let body = try json(LLMRequest(model: "claude-sonnet-5-5", system: "Be brief.", items: [.user("hi")]))
        #expect(body["model"] == "claude-sonnet-5-5")
        #expect(body["stream"] == true)
        #expect(body["system"] == "Be brief.")
        #expect(body["tools"] == nil)
        #expect(body["max_tokens"]?.intValue == AnthropicRequestEncoder.defaultMaxTokens)
        #expect(body["thinking"] == nil && body["output_config"] == nil && body["cache_control"] == nil)
        #expect(try json(LLMRequest(model: "m", items: [.user("hi")], maxOutputTokens: 700))["max_tokens"]?.intValue == 700)
    }

    @Test func toolsUseInputSchemaAndEagerStreaming() throws {
        let body = try json(LLMRequest(model: "claude-opus-5-5", items: [.user("hi")], tools: [tool]))
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 1)
        #expect(tools[0]["name"] == "read_file")
        #expect(tools[0]["eager_input_streaming"] == true)
        #expect(tools[0]["input_schema"]?["required"] == ["path"], "optional parameters stay out of required")
        #expect(tools[0]["input_schema"]?["additionalProperties"] == nil)
    }

    @Test func adaptiveModelsGetEffortAndLegacyOnesAGetBudget() throws {
        let adaptive = try json(LLMRequest(model: "claude-opus-5-5", items: [.user("hi")], reasoningEffort: "high"))
        #expect(adaptive["thinking"]?["type"] == "adaptive")
        #expect(adaptive["thinking"]?["display"] == "summarized")
        #expect(adaptive["output_config"]?["effort"] == "high")

        let legacy = try json(LLMRequest(model: "claude-haiku-4-5", items: [.user("hi")], reasoningEffort: "medium", maxOutputTokens: 20_000))
        #expect(legacy["thinking"]?["type"] == "enabled")
        #expect(legacy["thinking"]?["budget_tokens"]?.intValue == 8_192)
        #expect(legacy["output_config"] == nil)

        let tooSmall = try json(LLMRequest(model: "claude-haiku-4-5", items: [.user("hi")], reasoningEffort: "high", maxOutputTokens: 1_000))
        #expect(tooSmall["thinking"] == nil, "a budget must stay below max_tokens and above 1,024")

        let none = try json(LLMRequest(model: "claude-opus-5-5", items: [.user("hi")]))
        #expect(none["thinking"] == nil, "no effort means the model's own default")
    }

    @Test func aToolRoundTripGroupsMessagesAndPutsResultsFirst() throws {
        let items: [ConversationItem] = [
            .user("open it"),
            .opaque(OpaqueItem(provider: "anthropic", payload: thinkingBlock)),
            .assistant("Reading."),
            .toolCall(id: "toolu_1", name: "read_file", arguments: #"{"path":"A.java"}"#),
            .toolCall(id: "toolu_2", name: "read_file", arguments: #"{"path":"B.java"}"#),
            .toolOutput(callID: "toolu_1", output: "a"),
            .toolOutput(callID: "toolu_2", output: "b"),
            .user("[Note from the editor] hello"),
        ]
        let messages = AnthropicRequestEncoder.messages(for: LLMRequest(model: "m", items: items))
        #expect(messages.count == 3)
        #expect(messages[0]["role"] == "user")
        #expect(messages[1]["role"] == "assistant")
        let assistant = try #require(messages[1]["content"]?.arrayValue)
        #expect(assistant.map { $0["type"]?.stringValue } == ["thinking", "text", "tool_use", "tool_use"])
        #expect(assistant[0] == thinkingBlock, "thinking goes back exactly as received")
        #expect(assistant[2]["input"]?["path"] == "A.java")
        let user = try #require(messages[2]["content"]?.arrayValue)
        #expect(user.map { $0["type"]?.stringValue } == ["tool_result", "tool_result", "text"])
        #expect(user[0]["tool_use_id"] == "toolu_1")
    }

    @Test func otherProvidersItemsAndEmptyTextAreDroppedAndBadArgumentsBecomeAnObject() throws {
        let items: [ConversationItem] = [
            .user("go"),
            .opaque(OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning"])),
            .assistant(""),
            .toolCall(id: "toolu_1", name: "grep", arguments: "{not json"),
            .toolOutput(callID: "toolu_1", output: "error"),
        ]
        let messages = AnthropicRequestEncoder.messages(for: LLMRequest(model: "m", items: items))
        let assistant = try #require(messages[1]["content"]?.arrayValue)
        #expect(assistant.count == 1)
        #expect(assistant[0]["type"] == "tool_use")
        #expect(assistant[0]["input"] == .object([:]))
    }

    @Test func theBodyIsByteIdenticalAcrossEncodingsAndAsksForCaching() throws {
        let request = LLMRequest(model: "claude-opus-5-5", system: "s", items: [.user("hi")], tools: [tool, tool], reasoningEffort: "low", cacheKey: "k")
        let first = try AnthropicRequestEncoder.body(for: request)
        for _ in 0..<20 { #expect(try AnthropicRequestEncoder.body(for: request) == first) }
        #expect(try json(request)["cache_control"]?["type"] == "ephemeral")
    }
}

// MARK: - Decoder

@Suite struct AnthropicDecoderTests {
    private let thinkingThenTool = sse(
        #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":25,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"look."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"1"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Reading "}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"now."}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"A.java\"}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_2","name":"list_dir","input":{}}}"#,
        #"{"type":"content_block_stop","index":3}"#,
        #"{"type":"ping"}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        #"{"type":"message_stop"}"#)

    @Test func decodesThinkingTextAndParallelToolCalls() throws {
        let events = try decode(thinkingThenTool, sse: true, with: AnthropicEventDecoder())
        #expect(reasoning(events) == "Let me look.")
        #expect(text(events) == "Reading now.")
        #expect(events.contains(.toolCallStarted(id: "toolu_1", name: "read_file")))
        #expect(events.contains(.toolCallArgumentsDelta(id: "toolu_1", delta: #"{"path":"#)))
        #expect(events.contains(.toolCallFinished(id: "toolu_1", name: "read_file", arguments: #"{"path":"A.java"}"#)))
        #expect(events.contains(.toolCallFinished(id: "toolu_2", name: "list_dir", arguments: "{}")), "a call with no arguments sends an empty object")
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func theThinkingBlockIsKeptWholeWithItsSignatureAndInOrder() throws {
        let events = try decode(thinkingThenTool, sse: true, with: AnthropicEventDecoder())
        let kept = opaques(events)
        #expect(kept.count == 1)
        #expect(kept[0].provider == "anthropic")
        #expect(kept[0].payload == ["type": "thinking", "thinking": "Let me look.", "signature": "sig-1"])
        let thinkingIndex = try #require(events.firstIndex { if case .opaqueItem = $0 { true } else { false } })
        let firstText = try #require(events.firstIndex { if case .textDelta = $0 { true } else { false } })
        #expect(thinkingIndex < firstText)
    }

    @Test func usageIncludesWhatTheCacheServedAndIsReportedOnceBeforeTheEnd() throws {
        let events = try decode(thinkingThenTool, sse: true, with: AnthropicEventDecoder())
        let usage = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
        #expect(usage == [TokenUsage(inputTokens: 135, outputTokens: 42, cachedInputTokens: 100)])
        #expect(events.count - 2 == events.firstIndex { if case .usage = $0 { true } else { false } }!)
    }

    @Test func redactedThinkingIsKeptAndNeverShown() throws {
        let lines = sse(
            #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
            #"{"type":"message_stop"}"#)
        let events = try decode(lines, sse: true, with: AnthropicEventDecoder())
        #expect(opaques(events).map(\.payload) == [["type": "redacted_thinking", "data": "abc"]])
        #expect(reasoning(events).isEmpty)
        #expect(events.last == .finished(.completed))
    }

    @Test func aThinkingBlockWithoutASignatureCannotBeReplayedSoItIsNotKept() throws {
        let lines = sse(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_stop"}"#)
        #expect(opaques(try decode(lines, sse: true, with: AnthropicEventDecoder())).isEmpty)
    }

    @Test func stopReasonsMapToFinishReasons() throws {
        func finish(_ reason: String) throws -> LLMEvent? {
            let lines = sse(
                #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":1}}"#, #"{"type":"message_stop"}"#)
            return try decode(lines, sse: true, with: AnthropicEventDecoder()).last
        }
        #expect(try finish("end_turn") == .finished(.completed))
        #expect(try finish("max_tokens") == .finished(.length))
        #expect(try finish("refusal") == .finished(.contentFilter))
        #expect(try finish("stop_sequence") == .finished(.completed))
    }

    @Test func errorEventsMapToTheErrorsTheRetryPolicyKnows() throws {
        func error(_ type: String, _ message: String) -> [String] {
            sse(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#)
        }
        #expect(throws: LLMError.server(status: 529, message: "Overloaded")) {
            try decode(error("overloaded_error", "Overloaded"), sse: true, with: AnthropicEventDecoder())
        }
        #expect(throws: LLMError.rateLimited(retryAfter: nil)) {
            try decode(error("rate_limit_error", "slow down"), sse: true, with: AnthropicEventDecoder())
        }
        #expect(throws: LLMError.unauthorized) {
            try decode(error("authentication_error", "bad key"), sse: true, with: AnthropicEventDecoder())
        }
        #expect(throws: LLMError.contextLengthExceeded) {
            try decode(error("invalid_request_error", "prompt is too long: 300000 tokens > 200000 maximum"), sse: true, with: AnthropicEventDecoder())
        }
        #expect(throws: LLMError.malformedEvent("Invalid JSON in stream event.")) {
            try decode(["data: {oops"], sse: true, with: AnthropicEventDecoder())
        }
    }
}

// MARK: - Client

@Suite struct AnthropicClientTests {
    private let request = LLMRequest(model: "claude-sonnet-5-5", items: [.user("hi")])
    private let ok = sse(
        #"{"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
        #"{"type":"message_stop"}"#)

    @Test func sendsTheKeyInXApiKeyWithTheVersionAndNoBearerHeader() async throws {
        let transport = StubTransport([.response(status: 200, lines: ok)])
        let client = AnthropicMessagesClient(
            endpoint: LLMEndpoint(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: "sk-ant-test"),
            transport: transport, retry: fastRetry)
        let events = try await collect(client.stream(request))
        #expect(text(events) == "Hello")
        #expect(events.last == .finished(.completed))
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anOverloadedStreamIsRetriedAndTheConsumerIsToldToDropThePartialTurn() async throws {
        let overloaded = sse(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"par"}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let transport = StubTransport([.response(status: 200, lines: overloaded), .response(status: 200, lines: ok)])
        let events = try await collect(AnthropicMessagesClient(transport: transport, retry: fastRetry).stream(request))
        #expect(events.contains { if case .retrying = $0 { true } else { false } })
        #expect(events.last == .finished(.completed))
        #expect(transport.requests.count == 2)
    }

    @Test func aRejectedKeyIsUnauthorizedAndAnOversizedPromptIsAContextError() async throws {
        let unauthorized = StubTransport([.response(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])])
        await #expect(throws: LLMError.unauthorized) {
            _ = try await collect(AnthropicMessagesClient(transport: unauthorized, retry: .none).stream(request))
        }
        let tooLong = StubTransport([.response(status: 400, lines: [#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#])])
        await #expect(throws: LLMError.contextLengthExceeded) {
            _ = try await collect(AnthropicMessagesClient(transport: tooLong, retry: .none).stream(request))
        }
    }

    @Test func aStreamThatStopsBeforeMessageStopIsAConnectionLoss() async throws {
        let cut = sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        await #expect(throws: LLMError.connectionLost("The stream ended before the response completed.")) {
            _ = try await collect(AnthropicMessagesClient(transport: StubTransport([.response(status: 200, lines: cut)]), retry: .none).stream(request))
        }
    }
}
