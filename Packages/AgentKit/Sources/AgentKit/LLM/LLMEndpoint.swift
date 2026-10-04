import Foundation

/// Where a client sends requests. Azure needs `api-key` and `api-version`, so headers and query
/// items are open-ended.
public struct LLMEndpoint: Sendable, Hashable {
    public var baseURL: URL
    public var apiKey: String?
    public var extraHeaders: [String: String]
    public var queryItems: [URLQueryItem]
    /// Long enough for a slow reasoning model to start answering.
    public var requestTimeout: TimeInterval

    public static let openAI = LLMEndpoint(baseURL: URL(string: "https://api.openai.com/v1")!)

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        requestTimeout: TimeInterval = 300
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.queryItems = queryItems
        self.requestTimeout = requestTimeout
    }

    /// A POST request with the endpoint's authorization, headers and query items applied.
    public func urlRequest(path: String, body: Data, accept: String = "text/event-stream") -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}
