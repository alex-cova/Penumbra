import Foundation
import Testing
@testable import AgentKit

private func text(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
}

private func reasoning(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }.joined()
}

private func finishedCalls(_ events: [LLMEvent]) -> [(id: String, name: String, arguments: String)] {
    events.compactMap { event in
        if case .toolCallFinished(let id, let name, let arguments) = event { (id, name, arguments) } else { nil }
    }
}

// MARK: - Chat Completions

@Suite struct ChatCompletionsDecoderTests {
    @Test func decodesOllamasRealParallelToolCallsAndTheUsageOnlyLastChunk() throws {
        let events = try decode(try fixtureLines("v1-tools.sse"), sse: true, with: ChatCompletionsEventDecoder())
        let calls = finishedCalls(events)
        #expect(calls.count == 2)
        #expect(calls.map(\.name) == ["read_file", "read_file"])
        #expect(calls[0].arguments == #"{"path":"README.md"}"#)
        #expect(calls[1].arguments == #"{"path":"pom.xml"}"#)
        #expect(calls[0].id != calls[1].id && !calls[0].id.isEmpty)
        #expect(events.contains(.usage(TokenUsage(inputTokens: 277, outputTokens: 52))))
        #expect(events.last == .finished(.toolCalls), "the end is emitted at [DONE], after the usage chunk")
        let usageIndex = events.firstIndex { if case .usage = $0 { true } else { false } }!
        #expect(usageIndex < events.count - 1)
    }

    @Test func decodesRealTextWithOllamasReasoningField() throws {
        let events = try decode(try fixtureLines("v1-text.sse"), sse: true, with: ChatCompletionsEventDecoder())
        #expect(!reasoning(events).isEmpty, "Ollama sends delta.reasoning")
        #expect(events.last == .finished(.completed) || events.last == .finished(.length))
        #expect(events.contains { if case .usage = $0 { true } else { false } })
    }

    @Test func fragmentedInterleavedCallsKeepTheirOwnArguments() throws {
        let lines = sse(
            #"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"grep","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"q\":\"x\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"A.java\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]")
        let events = try decode(lines, sse: true, with: ChatCompletionsEventDecoder())
        #expect(events.contains(.toolCallStarted(id: "call_a", name: "read_file")))
        #expect(events.contains(.toolCallArgumentsDelta(id: "call_b", delta: #"{"q":"x"}"#)))
        let calls = finishedCalls(events)
        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls[0].arguments == #"{"path":"A.java"}"#)
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func aServerThatSaysStopDespiteCallsStillEndsInToolCallsAndMissingIdsAreSynthesized() throws {
        let lines = sse(
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"stop"}]}"#,
            "[DONE]")
        let events = try decode(lines, sse: true, with: ChatCompletionsEventDecoder())
        #expect(finishedCalls(events).map(\.id) == ["call_0"])
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func lengthContentFilterAndErrorChunks() throws {
        let length = try decode(sse(#"{"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}"#, "[DONE]"), sse: true, with: ChatCompletionsEventDecoder())
        #expect(length.last == .finished(.length))
        let filtered = try decode(sse(#"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#, "[DONE]"), sse: true, with: ChatCompletionsEventDecoder())
        #expect(filtered.last == .finished(.contentFilter))
        #expect(throws: LLMError.api(message: "bad key", code: "invalid_api_key")) {
            try decode(sse(#"{"error":{"message":"bad key","code":"invalid_api_key"}}"#), sse: true, with: ChatCompletionsEventDecoder())
        }
    }
}

@Suite struct ChatCompletionsEncoderTests {
    private func json(_ request: LLMRequest, _ capabilities: ChatCompletionsCapabilities) throws -> JSONValue {
        try JSONValue(parsing: String(decoding: ChatCompletionsRequestEncoder.body(for: request, capabilities: capabilities), as: UTF8.self))
    }

    private let tool = ToolDefinition(name: "read_file", description: "Read.", parameters: [
        ToolParameter("path", .string, "Path."), ToolParameter("offset", .integer, "Start.", optional: true),
    ])

    @Test func anAssistantTurnIsOneMessageWithItsCallsAndOutputsAreToolMessages() throws {
        let request = LLMRequest(model: "m", system: "sys", items: [
            .user("hi"),
            .assistant("Let me look."),
            .toolCall(id: "c1", name: "read_file", arguments: #"{"path":"A"}"#),
            .toolCall(id: "c2", name: "read_file", arguments: #"{"path":"B"}"#),
            .toolOutput(callID: "c1", output: "a"), .toolOutput(callID: "c2", output: "b"),
            .assistant("done"),
        ])
        let messages = try #require(try json(request, .compatible)["messages"]?.arrayValue)
        #expect(messages.count == 6)
        #expect(messages[0] == ["role": "system", "content": "sys"])
        #expect(messages[2]["role"] == "assistant" && messages[2]["content"] == "Let me look.")
        #expect(messages[2]["tool_calls"]?.arrayValue?.count == 2)
        #expect(messages[2]["tool_calls"]?.arrayValue?[1]["function"]?["arguments"] == #"{"path":"B"}"#)
        #expect(messages[3] == ["role": "tool", "tool_call_id": "c1", "content": "a"])
        #expect(messages[5] == ["role": "assistant", "content": "done"])
    }

    @Test func aCallWithoutTextHasNullContent() throws {
        let request = LLMRequest(model: "m", items: [.user("x"), .toolCall(id: "c", name: "t", arguments: "{}")])
        let messages = try #require(try json(request, .compatible)["messages"]?.arrayValue)
        #expect(messages[1]["content"] == .null)
    }

    @Test func capabilityFlagsShapeTheRequest() throws {
        let request = LLMRequest(model: "m", items: [.user("hi")], tools: [tool], reasoningEffort: "low", maxOutputTokens: 500, cacheKey: "k")

        let openAI = try json(request, .openAI)
        let strict = try #require(openAI["tools"]?.arrayValue?.first?["function"])
        #expect(strict["strict"] == true && strict["parameters"]?["additionalProperties"] == false)
        #expect(openAI["stream_options"]?["include_usage"] == true)
        #expect(openAI["max_completion_tokens"] == 500 && openAI["max_tokens"] == nil)
        #expect(openAI["reasoning_effort"] == "low" && openAI["prompt_cache_key"] == "k")

        let plain = try json(request, .compatible)
        let loose = try #require(plain["tools"]?.arrayValue?.first?["function"])
        #expect(loose["strict"] == nil && loose["parameters"]?["required"] == ["path"])
        #expect(plain["max_tokens"] == 500 && plain["max_completion_tokens"] == nil)
        #expect(plain["reasoning_effort"] == nil && plain["prompt_cache_key"] == nil)

        var noUsage = ChatCompletionsCapabilities.compatible
        noUsage.usageInStream = false
        noUsage.parallelToolCalls = false
        let bare = try json(request, noUsage)
        #expect(bare["stream_options"] == nil && bare["parallel_tool_calls"] == false)
    }

    @Test func providerItemsFromOtherApisAreDroppedAndTheBodyIsByteStable() throws {
        let request = LLMRequest(
            model: "m", items: [.opaque(OpaqueItem(provider: "openai-responses", payload: ["type": "reasoning"])), .user("hi")], tools: [tool])
        let messages = try #require(try json(request, .openAI)["messages"]?.arrayValue)
        #expect(messages.count == 1)
        let first = try ChatCompletionsRequestEncoder.body(for: request, capabilities: .openAI)
        for _ in 0..<20 { #expect(try ChatCompletionsRequestEncoder.body(for: request, capabilities: .openAI) == first) }
    }
}

@Suite struct ChatCompletionsClientTests {
    private let request = LLMRequest(model: "m", items: [.user("hi")])

    private func client(_ transport: StubTransport) -> OpenAIChatCompletionsClient {
        OpenAIChatCompletionsClient(
            endpoint: LLMEndpoint(baseURL: URL(string: "http://localhost:1234/v1")!), capabilities: .compatible,
            transport: transport, retry: fastRetry)
    }

    @Test func streamsARealCaptureThroughTheClient() async throws {
        let transport = StubTransport([.response(status: 200, lines: try fixtureLines("v1-tools.sse"))])
        let events = try await collect(client(transport).stream(request))
        #expect(finishedCalls(events).count == 2)
        #expect(events.last == .finished(.toolCalls))
        #expect(transport.requests.first?.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
    }

    @Test func aServerThatNeverSendsDoneCompletesOnceItGaveAFinishReason() async throws {
        let lines = sse(#"{"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}"#)
        let events = try await collect(client(StubTransport([.response(status: 200, lines: lines)])).stream(request))
        #expect(text(events) == "hi")
        #expect(events.last == .finished(.completed))
    }

    @Test func aStreamThatStopsMidAnswerIsAConnectionLossNotACompletion() async throws {
        let lines = sse(#"{"choices":[{"delta":{"content":"par"}}]}"#)
        let transport = StubTransport([.response(status: 200, lines: lines)])
        let noRetry = OpenAIChatCompletionsClient(
            endpoint: LLMEndpoint(baseURL: URL(string: "http://x/v1")!), capabilities: .compatible, transport: transport, retry: .none)
        await #expect(throws: LLMError.connectionLost("The stream ended before the response completed.")) {
            _ = try await collect(noRetry.stream(request))
        }
    }
}

// MARK: - Ollama

@Suite struct OllamaDecoderTests {
    @Test func decodesARealTextStream() throws {
        let events = try decode(try fixtureLines("native-text.ndjson"), sse: false, with: OllamaEventDecoder())
        #expect(text(events) == "Hello there friend")
        #expect(events.contains(.usage(TokenUsage(inputTokens: 18, outputTokens: 4))))
        #expect(events.last == .finished(.completed))
    }

    @Test func decodesRealThinkingAsReasoningNotText() throws {
        let events = try decode(try fixtureLines("native-think.ndjson"), sse: false, with: OllamaEventDecoder())
        #expect(reasoning(events).hasPrefix("User asks: What is 2+2?"))
        #expect(events.last == .finished(.completed))
    }

    @Test func decodesRealParallelToolCallsDeliveredWholeInTheDoneObject() throws {
        let events = try decode(try fixtureLines("native-tools.ndjson"), sse: false, with: OllamaEventDecoder())
        let calls = finishedCalls(events)
        #expect(calls.map(\.name) == ["read_file", "read_file"])
        #expect(calls[0].id == "PPcaqyylaCr0qjxNMy34PNde0E0sm7H1", "the server's own call id is kept")
        #expect(calls.map(\.arguments) == [#"{"path":"README.md"}"#, #"{"path":"pom.xml"}"#], "object arguments become key-sorted JSON text")
        #expect(events.contains(.toolCallStarted(id: calls[0].id, name: "read_file")))
        #expect(events.contains(.usage(TokenUsage(inputTokens: 277, outputTokens: 52))))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func decodesTheAnswerAfterAToolResult() throws {
        let events = try decode(try fixtureLines("native-roundtrip.ndjson"), sse: false, with: OllamaEventDecoder())
        #expect(text(events).contains("README"))
        #expect(events.last == .finished(.completed))
    }

    @Test func missingIdsAreSynthesizedStringArgumentsAreKeptAndLengthIsReported() throws {
        let lines = [
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"grep","arguments":"{\"q\":1}"}},{"function":{"name":"glob","arguments":{}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"length","prompt_eval_count":5,"eval_count":9}"#,
        ]
        let events = try decode(lines, sse: false, with: OllamaEventDecoder())
        let calls = finishedCalls(events)
        #expect(calls.map(\.id) == ["call_0", "call_1"])
        #expect(calls.map(\.arguments) == [#"{"q":1}"#, "{}"])
        #expect(events.last == .finished(.length))
    }

    @Test func anErrorObjectThrows() {
        #expect(throws: LLMError.api(message: "model requires more memory", code: nil)) {
            try decode([#"{"error":"model requires more memory"}"#], sse: false, with: OllamaEventDecoder())
        }
    }
}

@Suite struct OllamaEncoderTests {
    private let tool = ToolDefinition(name: "read_file", description: "Read.", parameters: [ToolParameter("path", .string, "Path.")])

    private func json(_ request: LLMRequest, context: Int = 8_192, thinks: Bool = false) throws -> JSONValue {
        try JSONValue(parsing: String(decoding: OllamaRequestEncoder.body(for: request, contextLength: context, supportsThinking: thinks), as: UTF8.self))
    }

    @Test func theRequestFixesTheContextAndKeepsTheModelLoaded() throws {
        let body = try json(LLMRequest(model: "qwen", items: [.user("hi")], tools: [tool], maxOutputTokens: 700), context: 32_768)
        #expect(body["stream"] == true)
        #expect(body["options"]?["num_ctx"] == 32_768 && body["options"]?["num_predict"] == 700)
        #expect(body["keep_alive"] == "30m")
        #expect(body["tools"]?.arrayValue?.first?["function"]?["parameters"]?["additionalProperties"] == nil, "no strict mode here")
    }

    @Test func thinkingIsSentOnlyToModelsThatThinkAndFollowsTheReasoningSetting() throws {
        let off = LLMRequest(model: "m", items: [.user("hi")])
        let on = LLMRequest(model: "m", items: [.user("hi")], reasoningEffort: "medium")
        #expect(try json(off)["think"] == nil, "a model without the capability must not be sent the field")
        #expect(try json(off, thinks: true)["think"] == false, "a thinking model is told explicitly, since some think by default")
        #expect(try json(on, thinks: true)["think"] == true)
        #expect(try json(on)["think"] == nil)
    }

    @Test func toolCallsCarryObjectArgumentsAndOutputsNameTheirToolAndCall() throws {
        let request = LLMRequest(model: "m", system: "sys", items: [
            .user("read it"),
            .toolCall(id: "call_0", name: "read_file", arguments: #"{"path":"README.md"}"#),
            .toolOutput(callID: "call_0", output: "# Demo"),
        ])
        let messages = try #require(try json(request)["messages"]?.arrayValue)
        #expect(messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool"])
        #expect(messages[2]["tool_calls"]?.arrayValue?[0]["function"]?["arguments"] == ["path": "README.md"], "an object, not a string")
        #expect(messages[3]["tool_name"] == "read_file" && messages[3]["tool_call_id"] == "call_0")
        #expect(messages[3]["content"] == "# Demo")
    }

    @Test func theBodyIsByteStable() throws {
        let request = LLMRequest(model: "m", system: "s", items: [.user("hi")], tools: [tool, tool])
        let first = try OllamaRequestEncoder.body(for: request, contextLength: 4_096, supportsThinking: true)
        for _ in 0..<20 { #expect(try OllamaRequestEncoder.body(for: request, contextLength: 4_096, supportsThinking: true) == first) }
    }
}

@Suite struct OllamaClientTests {
    private let request = LLMRequest(model: "qwen", items: [.user("hi")])

    @Test func streamsARealCaptureToTheNativeEndpointAsNDJSON() async throws {
        let transport = StubTransport([.response(status: 200, lines: try fixtureLines("native-tools.ndjson"))])
        let client = OllamaClient(transport: transport, retry: fastRetry)
        let events = try await collect(client.stream(request))
        #expect(finishedCalls(events).count == 2)
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/x-ndjson")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil, "no key for a local server")
    }

    @Test func anUnknownModelIsTheServersOwnMessage() async throws {
        let body = try fixtureText("native-404.json")
        let transport = StubTransport([.response(status: 404, lines: [body])])
        await #expect(throws: LLMError.badRequest(status: 404, message: "model 'no-such-model' not found")) {
            _ = try await collect(OllamaClient(transport: transport, retry: fastRetry).stream(request))
        }
        #expect(transport.requests.count == 1, "a missing model is not retried")
    }

    @Test func aServerThatIsNotRunningFailsOnceWithoutRetrying() async throws {
        let transport = StubTransport([.failure(URLError(.cannotConnectToHost))])
        do {
            _ = try await collect(OllamaClient(transport: transport, retry: fastRetry).stream(request))
            Issue.record("expected a failure")
        } catch let error as LLMError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
        }
        #expect(transport.requests.count == 1)
    }

    @Test func aDroppedConnectionIsStillRetried() async throws {
        let transport = StubTransport([
            .response(status: 200, lines: [], failure: URLError(.networkConnectionLost)),
            .response(status: 200, lines: try fixtureLines("native-text.ndjson")),
        ])
        let events = try await collect(OllamaClient(transport: transport, retry: fastRetry).stream(request))
        #expect(events.contains { if case .retrying = $0 { true } else { false } })
        #expect(events.last == .finished(.completed))
    }
}

@Suite struct OllamaModelCatalogTests {
    @Test func capabilitiesComeFromShowNotFromTagsAndTheModelsOwnContextIsRead() throws {
        let tags = try fixtureData("api-tags.json")
        let tagsList = try JSONValue(parsing: String(decoding: tags, as: UTF8.self))["models"]?.arrayValue ?? []
        #expect(tagsList.first?["capabilities"]?.arrayValue?.compactMap(\.stringValue) == ["completion"], "tags only lists completion")

        let shows = try JSONValue(parsing: try fixtureText("api-show.json")).objectValue ?? [:]
        let showData = try shows.mapValues { Data(try $0.serialized().utf8) }
        let models = OllamaModelCatalog.parse(tags: tags, shows: showData)

        let qwen = try #require(models.first { $0.name == "qwen-fixed:latest" })
        #expect(qwen.supportsTools && qwen.supportsThinking)
        #expect(qwen.contextLength == 262_144)
        #expect(qwen.parameterSize == "27.3B" && qwen.quantization != nil && qwen.sizeBytes > 1_000_000_000)
        #expect(models.map(\.name) == models.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func aModelWhoseDetailsFailedIsListedWithoutCapabilitiesSoItIsNotOfferedToTheAgent() throws {
        let models = OllamaModelCatalog.parse(tags: try fixtureData("api-tags.json"), shows: [:])
        #expect(models.count == 2)
        #expect(models.allSatisfy { !$0.supportsTools && $0.capabilities.isEmpty })
    }

    @Test func listsModelsOverTheTransportWithOneDetailCallEach() async throws {
        let tags = try fixtureData("api-tags.json")
        let shows = try JSONValue(parsing: try fixtureText("api-show.json")).objectValue ?? [:]
        let transport = RouteTransport { request in
            switch request.url?.path {
            case "/api/tags": return (200, tags)
            case "/api/show":
                let body = try JSONValue(parsing: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                let name = body["model"]?.stringValue ?? ""
                return (200, Data(try (shows[name] ?? .null).serialized().utf8))
            default: return (404, Data())
            }
        }
        let models = try await OllamaModelCatalog(transport: transport).models()
        #expect(models.count == 2 && models.allSatisfy(\.supportsTools))
        #expect(transport.requests.filter { $0.url?.path == "/api/show" }.count == 2)
    }

    @Test func aMissingServerSaysOllamaIsNotRunning() async throws {
        let transport = RouteTransport { _ -> (status: Int, data: Data) in throw URLError(.cannotConnectToHost) }
        await #expect(throws: LLMError.unreachable("Ollama isn't running at localhost:11434.")) {
            _ = try await OllamaModelCatalog(transport: transport).models()
        }
    }
}
