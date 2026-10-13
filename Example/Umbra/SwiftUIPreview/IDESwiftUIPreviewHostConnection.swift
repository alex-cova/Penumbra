import Darwin
import Foundation

/// A command to the host (`SwiftPreviewHostSource` documents them).
enum IDESwiftUIPreviewHostCommand: Sendable {
    case load(dylib: String, generation: Int)
    case render(
        generation: Int, width: Double, height: Double, scale: Double, scheme: String,
        dynamicType: String, locale: String, rightToLeft: Bool, fitsContent: Bool,
        safeTop: Double, safeBottom: Double, output: String
    )
    case mouse(type: String, x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    /// `kind`: `text` (`value` is the characters), `command` or `action` (`value` is a selector name).
    case key(kind: String, value: String)
    case quit

    var json: [String: Any] {
        switch self {
        case .load(let dylib, let generation):
            return ["cmd": "load", "dylib": dylib, "generation": generation]
        case .render(let generation, let width, let height, let scale, let scheme, let dynamicType, let locale, let rightToLeft, let fitsContent, let safeTop, let safeBottom, let output):
            return ["cmd": "render", "generation": generation, "width": width, "height": height,
                    "scale": scale, "scheme": scheme, "dynamicType": dynamicType, "locale": locale,
                    "rightToLeft": rightToLeft, "fit": fitsContent,
                    "safeTop": safeTop, "safeBottom": safeBottom, "output": output]
        case .mouse(let type, let x, let y):
            return ["cmd": "mouse", "type": type, "x": x, "y": y]
        case .scroll(let x, let y, let dx, let dy):
            return ["cmd": "scroll", "x": x, "y": y, "dx": dx, "dy": dy]
        case .key(let kind, let value):
            return kind == "text"
                ? ["cmd": "key", "kind": kind, "text": value]
                : ["cmd": "key", "kind": kind, "selector": value]
        case .quit:
            return ["cmd": "quit"]
        }
    }
}

/// One JSON object the host sent. The fields are plain JSON values, written once and only read.
struct IDESwiftUIPreviewHostEvent: @unchecked Sendable {
    var fields: [String: Any]

    subscript(key: String) -> Any? { fields[key] }
    var name: String? { fields["event"] as? String }
    var isOK: Bool { fields["ok"] as? Bool == true }
    var error: String? { fields["error"] as? String }
}

/// The client side of the preview host's socket (`SwiftPreviewHostSource`): JSON lines, one reply
/// event per command, in order. Events that arrive before anyone asks for one are kept, so the
/// host's `ready` is not lost when it comes before the first `nextEvent()`.
///
/// Reading happens on a thread of its own because `read(2)` blocks; everything else is async.
final class IDESwiftUIPreviewHostConnection: @unchecked Sendable {
    enum ConnectionError: Error, Equatable {
        case couldNotConnect
        case closed
    }

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var buffered: [IDESwiftUIPreviewHostEvent] = []
    private var waiters: [CheckedContinuation<IDESwiftUIPreviewHostEvent, Error>] = []
    private var isClosed = false

    /// Connects to the socket the host creates, retrying while it starts (it binds a moment after launch).
    static func connect(path: String, attempts: Int = 100, delay: Duration = .milliseconds(50)) async throws -> IDESwiftUIPreviewHostConnection {
        for _ in 0..<attempts {
            if Task.isCancelled { throw CancellationError() }
            if let descriptor = openSocket(path: path) {
                let connection = IDESwiftUIPreviewHostConnection(descriptor: descriptor)
                connection.startReading()
                return connection
            }
            try await Task.sleep(for: delay)
        }
        throw ConnectionError.couldNotConnect
    }

    private static func openSocket(path: String) -> Int32? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8.prefix(raw.count - 1)))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        // A closed peer must not kill Umbra with SIGPIPE.
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    // MARK: Requests

    /// Sends a command and returns the next event, which is its reply.
    func request(_ command: IDESwiftUIPreviewHostCommand) async throws -> IDESwiftUIPreviewHostEvent {
        try send(command)
        return try await nextEvent()
    }

    func send(_ command: IDESwiftUIPreviewHostCommand) throws {
        guard var data = try? JSONSerialization.data(withJSONObject: command.json) else { return }
        data.append(10)
        let descriptor = lock.withLock { isClosed ? -1 : self.descriptor }
        guard descriptor >= 0 else { throw ConnectionError.closed }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { throw ConnectionError.closed }
                offset += written
            }
        }
    }

    func nextEvent() async throws -> IDESwiftUIPreviewHostEvent {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffered.isEmpty {
                let event = buffered.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else if isClosed {
                lock.unlock()
                continuation.resume(throwing: ConnectionError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {
        let (waiting, descriptor): ([CheckedContinuation<IDESwiftUIPreviewHostEvent, Error>], Int32) = lock.withLock {
            guard !isClosed else { return ([], -1) }
            isClosed = true
            let pending = waiters
            waiters = []
            let open = self.descriptor
            self.descriptor = -1
            return (pending, open)
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
        waiting.forEach { $0.resume(throwing: ConnectionError.closed) }
    }

    // MARK: Reading

    private func startReading() {
        let descriptor = lock.withLock { self.descriptor }
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(descriptor, &chunk, chunk.count)
                if count <= 0 { break }
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self?.deliver(IDESwiftUIPreviewHostEvent(fields: object))
                    }
                }
            }
            self?.close()
        }
    }

    private func deliver(_ event: IDESwiftUIPreviewHostEvent) {
        lock.lock()
        if waiters.isEmpty {
            buffered.append(event)
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: event)
        }
    }
}
