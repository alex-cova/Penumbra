import Foundation

/// OpenAI's `/v1/responses`, stateless: see `ResponsesRequestEncoder`.
public struct OpenAIResponsesClient: LLMClient {
    public var providerID: String { ResponsesRequestEncoder.providerID }

    public let endpoint: LLMEndpoint
    public let strictTools: Bool
    private let transport: any LLMTransport
    private let retry: RetryPolicy

    public init(
        endpoint: LLMEndpoint = .openAI,
        strictTools: Bool = true,
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) {
        self.endpoint = endpoint
        self.strictTools = strictTools
        self.transport = transport
        self.retry = retry
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
