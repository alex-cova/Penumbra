import Foundation

public enum MCPError: Error, Equatable, LocalizedError {
    case unsupportedVersion(String)
    case server(code: Int, message: String)
    case timedOut(String)
    case closed
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "The server speaks MCP version \(version), which this client does not."
        case .server(_, let message): message
        case .timedOut(let what): "The MCP server did not answer \(what) in time."
        case .closed: "The MCP server has stopped."
        case .malformed(let detail): "The MCP server sent something unreadable: \(detail)"
        }
    }
}

/// A tool a server offers.
public struct MCPToolInfo: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// What the server claims about the tool. A claim, not a fact: nothing here relaxes a permission.
    public var title: String?
    public var readOnlyHint: Bool?
}

/// What a tool call came back with, as text.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
}

/// One MCP session with one server, over any `ACPTransport` (newline-delimited JSON-RPC, which is what
/// MCP's stdio transport is). Tools only: resources, prompts, sampling, roots and elicitation are not
/// offered, so a server that asks for them gets "method not found".
public actor MCPClient {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxTools = 200
    static let maxPages = 10

    private let connection: ACPConnection
    private let clientName: String
    private let clientVersion: String
    private var hasTools = true
    public private(set) var serverName: String?
    public private(set) var serverInstructions: String?

    public init(transport: any ACPTransport, clientName: String = "Umbra", clientVersion: String = "1.0") {
        self.connection = ACPConnection(transport: transport)
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    public var isClosed: Bool { get async { await connection.isClosed } }

    /// Opens the session: the handshake, then the `initialized` notice.
    public func start(timeout: Duration = .seconds(20)) async throws {
        await connection.setRequestHandler { method, _ in
            // `ping` is the one request a client must answer; everything else is a capability we did not offer.
            method == "ping" ? .success(.object([:])) : .failure(.methodNotFound(method))
        }
        await connection.start()
        let result = try await call("initialize", [
            "protocolVersion": .string(Self.supportedVersions[0]),
            "capabilities": .object([:]),
            "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
        ], timeout: timeout, what: "the handshake")
        guard let version = result["protocolVersion"]?.stringValue else { throw MCPError.malformed("no protocol version") }
        guard Self.supportedVersions.contains(version) else {
            await connection.close()
            throw MCPError.unsupportedVersion(version)
        }
        serverName = result["serverInfo"]?["name"]?.stringValue
        serverInstructions = result["instructions"]?.stringValue
        hasTools = result["capabilities"]?["tools"] != nil
        do { try await connection.notify(method: "notifications/initialized") } catch { throw Self.map(error) }
    }

    public func listTools(timeout: Duration = .seconds(20)) async throws -> [MCPToolInfo] {
        guard hasTools else { return [] }
        var tools: [MCPToolInfo] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await call("tools/list", params.isEmpty ? nil : .object(params), timeout: timeout, what: "its tool list")
            for item in page["tools"]?.arrayValue ?? [] {
                guard let name = item["name"]?.stringValue, !name.isEmpty else { continue }
                tools.append(MCPToolInfo(
                    name: name, description: item["description"]?.stringValue ?? "",
                    inputSchema: item["inputSchema"] ?? .object([:]), title: item["title"]?.stringValue ?? item["annotations"]?["title"]?.stringValue,
                    readOnlyHint: item["annotations"]?["readOnlyHint"]?.boolValue))
                if tools.count >= Self.maxTools { return tools }
            }
            guard let next = page["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }
        return tools
    }

    public func callTool(name: String, arguments: JSONValue, timeout: Duration) async throws -> MCPToolResult {
        let result = try await call("tools/call", ["name": .string(name), "arguments": arguments], timeout: timeout, what: "\(name)")
        return Self.result(from: result)
    }

    public func close() async { await connection.close() }

    // MARK: - Wire

    private func call(_ method: String, _ params: JSONValue?, timeout: Duration, what: String) async throws -> JSONValue {
        do {
            return try await connection.request(method: method, params: params, timeout: timeout)
        } catch {
            if case ACPError.timeout = error { throw MCPError.timedOut(what) }
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> Error {
        switch error {
        case ACPError.agentError(let rpc): MCPError.server(code: rpc.code, message: rpc.message)
        case ACPError.transportClosed: MCPError.closed
        case ACPError.malformedFrame(let detail): MCPError.malformed(detail)
        default: error
        }
    }

    /// A result's content blocks as text. Binary blocks are named, not carried.
    static func result(from value: JSONValue) -> MCPToolResult {
        var parts: [String] = []
        for block in value["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue { parts.append(text) }
            case "image", "audio":
                parts.append("[\(block["type"]?.stringValue ?? "binary") content (\(block["mimeType"]?.stringValue ?? "unknown type")) not shown]")
            case "resource":
                let resource = block["resource"]
                if let text = resource?["text"]?.stringValue {
                    parts.append((resource?["uri"]?.stringValue.map { "[\($0)]\n" } ?? "") + text)
                } else {
                    parts.append("[resource \(resource?["uri"]?.stringValue ?? "") not shown]")
                }
            case "resource_link":
                parts.append("[link \(block["name"]?.stringValue ?? ""): \(block["uri"]?.stringValue ?? "")]")
            default:
                break
            }
        }
        // A server that answers with structured content only still gets heard.
        if parts.isEmpty, let structured = value["structuredContent"], let text = try? structured.serialized() { parts.append(text) }
        return MCPToolResult(text: parts.joined(separator: "\n"), isError: value["isError"]?.boolValue ?? false)
    }
}
