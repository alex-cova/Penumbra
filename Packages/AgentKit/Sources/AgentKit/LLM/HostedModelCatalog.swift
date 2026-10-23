import Foundation

/// The models a hosted, OpenAI-compatible endpoint currently offers, from `GET {baseURL}/models`
/// with the endpoint's Bearer key. Meta's Model API, OpenAI and most compatible servers answer
/// this, so a host can list what is available today instead of shipping model ids in the app:
/// a model released after the app was built appears on its own.
///
/// The answer is the OpenAI shape, `{"data": [{"id": …}, …]}`; a bare `{"models": [...]}` list
/// of ids or objects is accepted too, since compatible servers vary. Order is the server's
/// (usually newest first), duplicates removed. Nothing is filtered: whether a model can call
/// tools is not in this answer, so the host decides what to offer for agent use.
public struct HostedModelCatalog: Sendable {
    public let endpoint: LLMEndpoint
    private let transport: any LLMTransport

    public init(endpoint: LLMEndpoint, transport: any LLMTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// The model ids the endpoint lists. Throws the classified HTTP error on a non-2xx answer
    /// (a rejected key is `.unauthorized`), so the host can say why the list is empty.
    public func models() async throws -> [String] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"), timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in endpoint.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }

        let (status, data) = try await transport.fetch(request)
        guard (200..<300).contains(status) else {
            throw HTTPErrorClassifier.classify(status: status, body: String(decoding: data, as: UTF8.self), retryAfter: nil)
        }
        return Self.parse(data)
    }

    /// Pure parsing, so fixtures test it without a network.
    public static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONValue(parsing: String(decoding: data, as: UTF8.self)) else { return [] }
        let entries = root["data"]?.arrayValue ?? root["models"]?.arrayValue ?? root.arrayValue ?? []
        var seen: Set<String> = []
        return entries.compactMap { entry in
            let id = entry.stringValue ?? entry["id"]?.stringValue
            guard let id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
