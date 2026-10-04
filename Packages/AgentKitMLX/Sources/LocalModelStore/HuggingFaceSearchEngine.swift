import Foundation

/// One row from the Hugging Face model list.
public struct HFModelSummary: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let downloads: Int
    public let likes: Int
    public let tags: [String]
    public let pipelineTag: String?
    public let isGated: Bool
    /// Total parameter count reported by the Hub, when the repo has safetensors metadata.
    public let parameterCount: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, gated, safetensors
        case pipelineTag = "pipeline_tag"
    }

    private struct SafetensorsInfo: Decodable { let total: Int64? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pipelineTag = try c.decodeIfPresent(String.self, forKey: .pipelineTag)
        isGated = HFModelSummary.decodeGated(from: c)
        parameterCount = try c.decodeIfPresent(SafetensorsInfo.self, forKey: .safetensors)?.total
    }

    public init(
        id: String, downloads: Int = 0, likes: Int = 0, tags: [String] = [],
        pipelineTag: String? = "text-generation", isGated: Bool = false, parameterCount: Int64? = nil
    ) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.pipelineTag = pipelineTag
        self.isGated = isGated
        self.parameterCount = parameterCount
    }

    /// The Hub sends `false`, or the strings `"auto"` / `"manual"` for gated repos.
    private static func decodeGated(from c: KeyedDecodingContainer<CodingKeys>) -> Bool {
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .gated) { return flag }
        if let mode = try? c.decodeIfPresent(String.self, forKey: .gated) { return !mode.isEmpty }
        return false
    }

    /// e.g. "4-bit", pulled from the tags the Hub attaches to quantized repos.
    public var quantization: String? {
        tags.first { $0.range(of: #"^\d+-?bit$"#, options: .regularExpression) != nil }
    }
}

public struct HFSibling: Hashable, Sendable, Decodable {
    public let path: String
    public let size: Int64?

    private enum CodingKeys: String, CodingKey {
        case path = "rfilename"
        case size
    }
}

/// Full repository detail, including the per-file sizes the list endpoint cannot provide.
public struct HFRepositoryInfo: Hashable, Sendable, Decodable {
    public let id: String
    public let sha: String?
    public let isGated: Bool
    public let siblings: [HFSibling]
    public let usedStorage: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, sha, gated, siblings, usedStorage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sha = try c.decodeIfPresent(String.self, forKey: .sha)
        siblings = try c.decodeIfPresent([HFSibling].self, forKey: .siblings) ?? []
        usedStorage = try c.decodeIfPresent(Int64.self, forKey: .usedStorage)
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .gated) {
            isGated = flag
        } else if let mode = try? c.decodeIfPresent(String.self, forKey: .gated) {
            isGated = !mode.isEmpty
        } else {
            isGated = false
        }
    }

    public init(id: String, sha: String? = nil, isGated: Bool = false, siblings: [HFSibling], usedStorage: Int64? = nil) {
        self.id = id
        self.sha = sha
        self.isGated = isGated
        self.siblings = siblings
        self.usedStorage = usedStorage
    }
}

/// Talks to the Hugging Face Hub JSON API. Pure request building and decoding are split from the
/// network call so tests never touch the network.
public enum HuggingFaceSearchEngine {
    public static let endpoint = URL(string: "https://huggingface.co")!

    /// `usedStorage` is deliberately absent: the list endpoint rejects it, so sizes come from
    /// `repositoryInfo` once a model is selected.
    private static let listFields = [
        "downloads", "likes", "tags", "pipeline_tag", "gated", "safetensors", "private",
    ]

    public static func searchRequest(query: String, limit: Int = 30, endpoint: URL = endpoint) -> URLRequest {
        var components = URLComponents(url: endpoint.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "filter", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        items += listFields.map { URLQueryItem(name: "expand[]", value: $0) }
        components.queryItems = items
        return URLRequest(url: components.url!)
    }

    public static func infoRequest(id: String, token: String? = nil, endpoint: URL = endpoint) throws -> URLRequest {
        guard LocalModelPaths.isValidRepositoryID(id) else { throw LocalModelError.invalidRepositoryID(id) }
        var components = URLComponents(url: endpoint.appendingPathComponent("api/models/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        var request = URLRequest(url: components.url!)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public static func decodeSearch(_ data: Data) throws -> [HFModelSummary] {
        let all: [HFModelSummary]
        do { all = try JSONDecoder().decode([HFModelSummary].self, from: data) } catch { throw LocalModelError.malformedResponse }
        // The server already narrows to text-generation; MLXLLM cannot load VLMs or embedders, so
        // keep the filter as a backstop against the Hub changing how `filter` combines.
        return all.filter { $0.pipelineTag == "text-generation" }
    }

    public static func decodeInfo(_ data: Data) throws -> HFRepositoryInfo {
        do { return try JSONDecoder().decode(HFRepositoryInfo.self, from: data) } catch { throw LocalModelError.malformedResponse }
    }

    public static func search(query: String, limit: Int = 30, session: URLSession = .shared) async throws -> [HFModelSummary] {
        let (data, response) = try await session.data(for: searchRequest(query: query, limit: limit))
        try validate(response, id: nil)
        return try decodeSearch(data)
    }

    public static func repositoryInfo(
        id: String, token: String? = nil, endpoint: URL = endpoint, session: URLSession = .shared
    ) async throws -> HFRepositoryInfo {
        let (data, response) = try await session.data(for: infoRequest(id: id, token: token, endpoint: endpoint))
        try validate(response, id: id)
        let info = try decodeInfo(data)
        if info.isGated, token?.isEmpty ?? true { throw LocalModelError.gatedModel(id) }
        return info
    }

    private static func validate(_ response: URLResponse, id: String?) throws {
        guard let http = response as? HTTPURLResponse else { throw LocalModelError.malformedResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw LocalModelError.gatedModel(id ?? "This repository")
        case 404: throw LocalModelError.modelNotFound(id ?? "This repository")
        default: throw LocalModelError.searchFailed(status: http.statusCode)
        }
    }
}
