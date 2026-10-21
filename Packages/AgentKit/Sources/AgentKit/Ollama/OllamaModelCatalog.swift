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
    /// Shown as a badge only: the agent sends no images.
    public var supportsVision: Bool { capabilities.contains("vision") }
}

/// Where a `pull` stands. `/api/pull` reports one layer at a time; the counts here add the layers
/// seen so far, so the fraction can move backwards when a new layer announces its size.
public struct OllamaPullProgress: Sendable, Equatable {
    /// Ollama's own words: "pulling manifest", "pulling 4f2c…", "verifying sha256 digest", "success".
    public var status: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var isFinished: Bool

    public var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
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

    /// Downloads a model, reporting progress; the stream ends after `success`. Cancelling the consumer
    /// stops the download (Ollama keeps the layers it has, so a second pull resumes).
    public func pull(_ name: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURL
        let transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !name.isEmpty else { throw LLMError.badRequest(status: 400, message: "Enter a model name, such as qwen3:8b.") }
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"), timeoutInterval: 600)
                    request.httpMethod = "POST"
                    request.httpBody = try JSONEncoder().encode(JSONValue.object(["model": .string(name), "stream": true]))
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let response = try await transport.open(request)
                    guard (200..<300).contains(response.status) else {
                        var body = ""
                        for try await line in response.lines where body.count < 4_096 { body += line + "\n" }
                        throw HTTPErrorClassifier.classify(status: response.status, body: body, retryAfter: nil)
                    }
                    var tracker = PullTracker()
                    for try await line in response.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        if let progress = try tracker.apply(line: trimmed) { continuation.yield(progress) }
                    }
                    // A server that closes without `success` did not finish the download.
                    if !tracker.isFinished { throw LLMError.connectionLost("The download stopped before it finished.") }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: Self.unreachableMessage(HTTPStreamClient.normalized(error), baseURL: baseURL))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Removes an installed model from disk.
    public func delete(_ name: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"), timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["model": .string(name)]))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    /// Folds `/api/pull` lines into totals across layers.
    struct PullTracker {
        private var layers: [String: (total: Int64, completed: Int64)] = [:]
        private(set) var isFinished = false

        mutating func apply(line: String) throws -> OllamaPullProgress? {
            guard let json = try? JSONValue(parsing: line) else { throw LLMError.malformedEvent("Invalid JSON in pull progress.") }
            if let error = json["error"]?.stringValue { throw LLMError.api(message: error, code: nil) }
            let status = json["status"]?.stringValue ?? ""
            if let digest = json["digest"]?.stringValue, let total = json["total"]?.intValue {
                layers[digest] = (Int64(total), Int64(json["completed"]?.intValue ?? 0))
            }
            if status == "success" { isFinished = true }
            let total = layers.values.reduce(Int64(0)) { $0 + $1.total }
            let completed = layers.values.reduce(Int64(0)) { $0 + $1.completed }
            return OllamaPullProgress(status: status, completedBytes: completed, totalBytes: total, isFinished: isFinished)
        }
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
            throw Self.unreachableMessage(HTTPStreamClient.normalized(error), baseURL: baseURL)
        }
    }

    private static func unreachableMessage(_ error: Error, baseURL: URL) -> Error {
        if case LLMError.unreachable = error {
            return LLMError.unreachable("Ollama isn't running at \(baseURL.host() ?? "localhost"):\(baseURL.port ?? 11434).")
        }
        return error
    }
}
