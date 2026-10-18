import Foundation

/// JSON-RPC 2.0 identifier: a string or an integer (ACP `RequestId`).
public enum JSONRPCID: Sendable, Hashable {
    case int(Int)
    case string(String)

    public var jsonValue: JSONValue {
        switch self {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }

    public init?(jsonValue: JSONValue) {
        switch jsonValue {
        case .int(let value): self = .int(value)
        case .string(let value): self = .string(value)
        case .double(let value):
            guard let exact = Int(exactly: value) else { return nil }
            self = .int(exact)
        default: return nil
        }
    }
}

/// JSON-RPC 2.0 error object.
public struct JSONRPCError: Error, Sendable, Hashable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }

    public init?(jsonValue: JSONValue) {
        guard let code = jsonValue["code"]?.intValue, let message = jsonValue["message"]?.stringValue else { return nil }
        self.code = code
        self.message = message
        self.data = jsonValue["data"]
    }

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: message)
    }
    public static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }
}

/// Errors surfaced by the ACP layer itself (not by the remote agent).
public enum ACPError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedProtocolVersion(Int)
    case transportClosed
    case malformedFrame(String)
    case agentError(JSONRPCError)
    case sessionNotEstablished
    case notConnected
    case timeout(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let version):
            "The agent requires ACP protocol version \(version), which this client does not support."
        case .transportClosed: "The ACP agent connection closed."
        case .malformedFrame(let detail): "Malformed ACP frame: \(detail)"
        case .agentError(let error): error.message
        case .sessionNotEstablished: "No ACP session has been established."
        case .notConnected: "The ACP agent is not connected."
        case .timeout(let what): "Timed out waiting for \(what)."
        case .cancelled: "The ACP request was cancelled."
        }
    }
}

/// One JSON-RPC 2.0 message decoded from a single newline-delimited frame.
public enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case result(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, error: JSONRPCError)

    public var jsonValue: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": id.jsonValue, "method": .string(method)]
            if let params { object["params"] = params }
            return .object(object)
        case .notification(let method, let params):
            var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { object["params"] = params }
            return .object(object)
        case .result(let id, let result):
            return .object(["jsonrpc": "2.0", "id": id.jsonValue, "result": result])
        case .error(let id, let error):
            return .object(["jsonrpc": "2.0", "id": id?.jsonValue ?? .null, "error": error.jsonValue])
        }
    }

    public func serialized() throws -> Data {
        Data(try jsonValue.serialized().utf8)
    }

    /// Parses one frame. Throws `ACPError.malformedFrame` for anything that is not a JSON-RPC object.
    public init(parsing data: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ACPError.malformedFrame("not valid JSON")
        }
        guard case .object = value else { throw ACPError.malformedFrame("frame is not a JSON object") }
        if let method = value["method"]?.stringValue {
            if let idValue = value["id"], idValue != .null {
                guard let id = JSONRPCID(jsonValue: idValue) else { throw ACPError.malformedFrame("invalid request id") }
                self = .request(id: id, method: method, params: value["params"])
            } else {
                self = .notification(method: method, params: value["params"])
            }
        } else if let result = value["result"] {
            guard let idValue = value["id"], let id = JSONRPCID(jsonValue: idValue) else {
                throw ACPError.malformedFrame("result without a valid id")
            }
            self = .result(id: id, result: result)
        } else if let errorValue = value["error"], let error = JSONRPCError(jsonValue: errorValue) {
            let id = value["id"].flatMap(JSONRPCID.init(jsonValue:))
            self = .error(id: id, error: error)
        } else {
            throw ACPError.malformedFrame("frame has neither method, result, nor error")
        }
    }
}
