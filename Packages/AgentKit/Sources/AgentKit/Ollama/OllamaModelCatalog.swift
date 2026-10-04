import Foundation

/// An installed Ollama model. Capabilities come from `/api/show`: `/api/tags` lists only
/// `completion` for models that `/api/show` says support tools and thinking (seen on 0.33).
public struct OllamaModel: Sendable, Equatable, Identifiable {
    public let name: String
    public let parameterSize: String?
    public let quantization: String?
    public let sizeBytes: Int64
    public let capabilities: [String]
    /// The model's own maximum, from `model_info`.
    public let contextLength: Int?

    public var id: String { name }
    public var supportsTools: Bool { capabilities.contains("tools") }
    public var supportsThinking: Bool { capabilities.contains("thinking") }
}

public struct OllamaModelCatalog: Sendable {
    public let baseURL: URL
    private let transport: any LLMTransport

    public init(baseURL: URL = OllamaClient.defaultBaseURL, transport: any LLMTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Installed models with their capabilities. Throws `.unreachable` when Ollama isn't running.
    public func models() async throws -> [OllamaModel] {
        let tags = try await get("api/tags")
        let names = Self.names(inTags: tags)
        var shows: [String: Data] = [:]
        // Detail calls run together; a model whose detail call fails is listed without capabilities.
        await withTaskGroup(of: (String, Data?).self) { group in
            for name in names {
                group.addTask { (name, try? await self.post("api/show", body: ["model": .string(name)])) }
            }
            for await (name, data) in group { if let data { shows[name] = data } }
        }
        return Self.parse(tags: tags, shows: shows)
    }

    // MARK: - Pure parsing

    static func names(inTags data: Data) -> [String] {
        ((try? JSONDecoder().decode(JSONValue.self, from: data))?["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    public static func parse(tags: Data, shows: [String: Data]) -> [OllamaModel] {
        let models = (try? JSONDecoder().decode(JSONValue.self, from: tags))?["models"]?.arrayValue ?? []
        return models.compactMap { entry -> OllamaModel? in
            guard let name = entry["name"]?.stringValue else { return nil }
            let show = shows[name].flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let info = show?["model_info"]?.objectValue ?? [:]
            let contextKey = info.keys.first { $0.hasSuffix(".context_length") }
            return OllamaModel(
                name: name,
                parameterSize: entry["details"]?["parameter_size"]?.stringValue,
                quantization: entry["details"]?["quantization_level"]?.stringValue,
                sizeBytes: Int64(entry["size"]?.intValue ?? 0),
                capabilities: show?["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                contextLength: contextKey.flatMap { info[$0]?.intValue })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Requests

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post(_ path: String, body: [String: JSONValue]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (status, data) = try await transport.fetch(request)
            guard (200..<300).contains(status) else {
                throw HTTPErrorClassifier.classify(status: status, body: String(decoding: data, as: UTF8.self), retryAfter: nil)
            }
            return data
        } catch {
            let normalized = HTTPStreamClient.normalized(error)
            if case LLMError.unreachable = normalized {
                throw LLMError.unreachable("Ollama isn't running at \(baseURL.host() ?? "localhost"):\(baseURL.port ?? 11434).")
            }
            throw normalized
        }
    }
}
