import Foundation

/// Owns one ACP connection over an injected `ACPTransport`: frame parsing, pending-request
/// correlation, notification dispatch, and cancellation.
///
/// Handlers are installed with `setRequestHandler` / `setNotificationHandler` after creation so
/// an owner (client session, fake agent, future agent endpoint) can wire itself without a
/// construction cycle.
public actor ACPConnection {
    /// A line longer than this is a protocol failure, not a message (10 MiB).
    public static let maxLineBytes = 10 * 1024 * 1024

    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue?) async -> Void
    public typealias CloseHandler = @Sendable (_ error: ACPError?) async -> Void

    private let transport: any ACPTransport
    private var nextID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var closed = false
    private var closeError: ACPError?

    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var closeHandler: CloseHandler?

    public init(transport: any ACPTransport) {
        self.transport = transport
    }

    public var isClosed: Bool { closed }

    public func setRequestHandler(_ handler: RequestHandler?) { requestHandler = handler }
    public func setNotificationHandler(_ handler: NotificationHandler?) { notificationHandler = handler }
    public func setCloseHandler(_ handler: CloseHandler?) { closeHandler = handler }

    public func start() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop()
        }
    }

    // MARK: - Sending

    public func request(method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        guard !closed else { throw ACPError.transportClosed }
        let id = JSONRPCID.int(nextID)
        nextID += 1
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        let data = try message.serialized()
        let transport = self.transport
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(data)
                } catch let error as ACPError {
                    self.pending.removeValue(forKey: id)?.resume(throwing: error)
                    return
                } catch {
                    self.pending.removeValue(forKey: id)?.resume(throwing: ACPError.transportClosed)
                    return
                }
                if let timeout {
                    Task {
                        try? await Task.sleep(for: timeout)
                        self.expire(id: id, method: method)
                    }
                }
            }
        }
    }

    private func expire(id: JSONRPCID, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: ACPError.timeout(method))
    }

    public func notify(method: String, params: JSONValue? = nil) async throws {
        guard !closed else { throw ACPError.transportClosed }
        try await transport.send(try JSONRPCMessage.notification(method: method, params: params).serialized())
    }

    public func respond(id: JSONRPCID, result: JSONValue) async {
        try? await transport.send(try JSONRPCMessage.result(id: id, result: result).serialized())
    }

    public func respondError(id: JSONRPCID, error: JSONRPCError) async {
        try? await transport.send(try JSONRPCMessage.error(id: id, error: error).serialized())
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        failAllPending(with: ACPError.transportClosed)
        await transport.close()
    }

    // MARK: - Receiving

    private func readLoop() async {
        var buffer = Data()
        var failure: ACPError?
        outer: for await chunk in transport.incoming {
            if Task.isCancelled { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.count > Self.maxLineBytes {
                    failure = .malformedFrame("line exceeds \(Self.maxLineBytes) bytes")
                    break outer
                }
                let trimmed = line.filter { $0 != UInt8(ascii: "\r") }
                if trimmed.isEmpty { continue }
                await handle(frame: Data(trimmed))
            }
            if buffer.count > Self.maxLineBytes {
                failure = .malformedFrame("line exceeds \(Self.maxLineBytes) bytes")
                break
            }
        }
        let error = failure ?? closeError
        guard !closed else { return }
        closed = true
        failAllPending(with: error ?? ACPError.transportClosed)
        if let closeHandler { await closeHandler(error) }
    }

    private func failAllPending(with error: Error) {
        let waiters = pending
        pending = [:]
        for (_, continuation) in waiters { continuation.resume(throwing: error) }
    }

    private func handle(frame: Data) async {
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage(parsing: frame)
        } catch let error as ACPError {
            // A malformed frame must not corrupt the connection silently: surface it as closure.
            closeError = error
            await close()
            if let closeHandler { await closeHandler(error) }
            return
        } catch {
            closeError = .malformedFrame(error.localizedDescription)
            await close()
            if let closeHandler, let closeError { await closeHandler(closeError) }
            return
        }
        switch message {
        case .result(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .error(let id, let error):
            if let id, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: ACPError.agentError(error))
            }
        case .notification(let method, let params):
            if let notificationHandler { await notificationHandler(method, params) }
        case .request(let id, let method, let params):
            guard let requestHandler else {
                await respondError(id: id, error: .methodNotFound(method))
                return
            }
            // Requests run concurrently with the reader: a handler may itself call back
            // (permission, fs, terminal) and must not block response correlation.
            Task {
                switch await requestHandler(method, params) {
                case .success(let result): await self.respond(id: id, result: result)
                case .failure(let error): await self.respondError(id: id, error: error)
                }
            }
        }
    }
}
