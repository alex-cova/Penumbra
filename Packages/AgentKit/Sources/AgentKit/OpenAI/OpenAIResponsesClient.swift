import Foundation

/// OpenAI's `/v1/responses`, stateless: see `ResponsesRequestEncoder`.
public struct OpenAIResponsesClient: LLMClient {
    public var providerID: String { ResponsesRequestEncoder.providerID }
    /// OpenAI takes `tool_choice: "none"`. Meta's Model API answers it with a 400 ("only `auto` is
    /// supported"), so `meta(...)` turns it off and the closing turn sends no tool list instead.
    public let supportsDisabledToolChoice: Bool
    public var supportsImages: Bool { true }

    public let endpoint: LLMEndpoint
    public let strictTools: Bool
    private let transport: any LLMTransport
    private let retry: RetryPolicy

    public init(
        endpoint: LLMEndpoint = .openAI,
        strictTools: Bool = true,
        supportsDisabledToolChoice: Bool = true,
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) {
        self.endpoint = endpoint
        self.strictTools = strictTools
        self.supportsDisabledToolChoice = supportsDisabledToolChoice
        self.transport = transport
        self.retry = retry
    }

    /// The client for Meta's Model API (Muse): the Responses format with the quirks measured on
    /// 2026-11-02 (`agent-harness-9.md`). Every host builds it here so a quirk is fixed once.
    public static func meta(
        endpoint: LLMEndpoint = .meta,
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            endpoint: endpoint, supportsDisabledToolChoice: false, transport: transport, retry: retry)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let endpoint = endpoint
        let strictTools = strictTools
        return HTTPStreamClient(
            transport: transport, retry: retry, framing: .sse,
            makeRequest: { endpoint.urlRequest(path: "responses", body: try ResponsesRequestEncoder.body(for: request, strictTools: strictTools)) },
            makeDecoder: { ResponsesEventDecoder() }
        ).stream()
    }
}

extension ResponsesEventDecoder: StreamDecoder {}
