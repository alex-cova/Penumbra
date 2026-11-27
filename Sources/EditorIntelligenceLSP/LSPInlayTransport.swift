import Foundation
import JSONRPC
import LanguageServerProtocol

/// Extends the shared framed connection for the inlay requests the pinned protocol dependency
/// cannot cancel and the parameterless refresh request it cannot decode.
actor LSPInlayTransport {
    private static let requestPrefix = "umbra-inlay:"
    private static let prefixBytes = Data(requestPrefix.utf8)
    private static let refreshBytes = Data("inlayHint".utf8)
    private static let capabilitiesBytes = Data("\"capabilities\"".utf8)
    private static let initializeBytes = Data("\"initialize\"".utf8)
    private let write: DataChannel.WriteHandler
    private let onRefresh: (@Sendable () -> Void)?
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private var initializationID: JSONValue?
    private var isClosed = false
    private(set) var resolvesHints = false

    init(write: @escaping DataChannel.WriteHandler, onRefresh: (@Sendable () -> Void)?) {
        self.write = write
        self.onRefresh = onRefresh
    }

    func forward(_ data: Data) async throws {
        guard data.range(of: Self.initializeBytes) != nil,
              var message = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              message["method"] == .string("initialize"),
              case .hash(var params) = message["params"],
              case .hash(var capabilities) = params["capabilities"] else {
            try await write(data)
            return
        }
        initializationID = message["id"]
        var workspace: [String: JSONValue] = [:]
        if case .hash(let existing) = capabilities["workspace"] { workspace = existing }
        workspace["inlayHint"] = .hash(["refreshSupport": .bool(true)])
        capabilities["workspace"] = .hash(workspace)
        params["capabilities"] = .hash(capabilities)
        message["params"] = .hash(params)
        try await write(JSONEncoder().encode(message))
    }

    /// Returns true for messages handled here and leaves other protocol traffic to LanguageClient.
    func consume(_ data: Data) async -> Bool {
        guard data.range(of: Self.prefixBytes) != nil
                || data.range(of: Self.refreshBytes) != nil
                || (initializationID != nil && data.range(of: Self.capabilitiesBytes) != nil),
              let message = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return false }
        if message["method"] == .string("workspace/inlayHint/refresh"), let id = message["id"] {
            if let response = try? JSONEncoder().encode(["jsonrpc": .string("2.0"), "id": id, "result": .null]) {
                try? await write(response)
            }
            onRefresh?()
            return true
        }
        if message["id"] == initializationID, initializationID != nil {
            initializationID = nil
            if case .hash(let result) = message["result"], case .hash(let capabilities) = result["capabilities"],
               case .hash(let options) = capabilities["inlayHintProvider"] {
                resolvesHints = options["resolveProvider"] == .bool(true)
            }
            return false
        }
        guard message["method"] == nil, case .string(let id) = message["id"], id.hasPrefix(Self.requestPrefix) else {
            return false
        }
        if let continuation = pending.removeValue(forKey: id) {
            if let result = message["result"], let encoded = try? JSONEncoder().encode(result) {
                continuation.resume(returning: encoded)
            } else {
                continuation.resume(throwing: Failure.invalidResponse)
            }
        }
        return true
    }

    func request<Params: Encodable & Sendable>(_ method: String, params: Params) async throws -> Data {
        try Task.checkCancellation()
        guard !isClosed else { throw Failure.closed }
        guard pending.count < 32 else { throw Failure.tooManyRequests }
        let id = Self.requestPrefix + UUID().uuidString
        let message = JSONRPCRequest(id: .stringId(id), method: method, params: params)
        let data = try JSONEncoder().encode(message)
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                await cancel(id, reason: Failure.timedOut)
            } catch {}
        }
        defer { timeout.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil else { return }
                    do {
                        try await write(data)
                    } catch {
                        pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(id, reason: CancellationError()) }
        }
    }

    func close() {
        isClosed = true
        let requests = pending
        pending.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: Failure.closed)
        }
    }

    private func cancel(_ id: String, reason: any Error) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: reason)
        let notification = JSONRPCNotification(method: "$/cancelRequest", params: ["id": id])
        guard let data = try? JSONEncoder().encode(notification) else { return }
        try? await write(data)
    }

    private enum Failure: Error {
        case invalidResponse, tooManyRequests, timedOut, closed
    }
}
