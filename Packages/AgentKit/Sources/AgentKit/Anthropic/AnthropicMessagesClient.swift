import Foundation

extension LLMEndpoint {
    /// Anthropic's API. The key goes in `x-api-key`, not a bearer token (see `AnthropicMessagesClient`).
    public static let anthropic = LLMEndpoint(baseURL: URL(string: "https://api.anthropic.com/v1")!)
}

/// Anthropic's `/v1/messages`, stateless: see `AnthropicRequestEncoder`.
public struct AnthropicMessagesClient: LLMClient {
    public var providerID: String { AnthropicRequestEncoder.providerID }
    public var supportsDisabledToolChoice: Bool { true }

    public static let apiVersion = "2023-06-01"

    public let endpoint: LLMEndpoint
    private let transport: any LLMTransport
    private let retry: RetryPolicy

    public init(
        endpoint: LLMEndpoint = .anthropic,
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.retry = retry
    }

    /// The endpoint with Anthropic's authentication: `x-api-key` and `anthropic-version`, and no bearer header.
    var authenticated: LLMEndpoint {
        var result = endpoint
        var headers = endpoint.extraHeaders
        if let key = endpoint.apiKey, !key.isEmpty { headers["x-api-key"] = key }
        if headers["anthropic-version"] == nil { headers["anthropic-version"] = Self.apiVersion }
        result.apiKey = nil
        result.extraHeaders = headers
        return result
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let endpoint = authenticated
        return HTTPStreamClient(
            transport: transport, retry: retry, framing: .sse,
            makeRequest: { endpoint.urlRequest(path: "messages", body: try AnthropicRequestEncoder.body(for: request)) },
            makeDecoder: { AnthropicEventDecoder() }
        ).stream()
    }
}
