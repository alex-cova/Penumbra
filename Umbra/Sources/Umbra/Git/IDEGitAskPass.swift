import Darwin
import Foundation
import GitIntelligence

/// Git and ssh ask for credentials by running `$GIT_ASKPASS` / `$SSH_ASKPASS` with the prompt as
/// its argument and reading the answer from stdout. Umbra is that program: when a child is started
/// with `UMBRA_ASKPASS_SOCKET` set, `UmbraMain` runs `IDEGitAskPassClient` instead of the app. The
/// client sends the prompt to the running Umbra over a Unix socket (`IDEGitAskPassServer`), which
/// shows a sheet in the window that started the command and sends the answer back.
enum IDEGitAskPassEnvironment {
    static let socket = "UMBRA_ASKPASS_SOCKET"
    static let token = "UMBRA_ASKPASS_TOKEN"
    static let session = "UMBRA_ASKPASS_SESSION"
}

struct IDEGitAskPassRequest: Codable, Equatable {
    var token: String
    var session: String
    var prompt: String
}

struct IDEGitAskPassReply: Codable, Equatable {
    var answer: String?
    var cancelled: Bool

    static let cancel = IDEGitAskPassReply(answer: nil, cancelled: true)
}

/// What kind of answer a prompt wants, from git's and ssh's wording.
enum IDEGitCredentialPromptKind: Equatable {
    /// `Username for 'https://github.com':`
    case username
    /// A password, passphrase or PIN: typed into a secure field.
    case secret
    /// `Are you sure you want to continue connecting (yes/no/[fingerprint])?`
    case confirmation
    case text

    static func classify(_ prompt: String) -> IDEGitCredentialPromptKind {
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") { return .confirmation }
        if lower.hasPrefix("username") { return .username }
        if lower.contains("password") || lower.contains("passphrase") || lower.contains("enter pin") {
            return .secret
        }
        return .text
    }
}

// MARK: - Socket plumbing shared by both ends

enum IDEUnixSocket {
    /// `sun_path` holds 104 bytes on macOS.
    static let maximumPathLength = 100

    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// One line, without the newline; nil on EOF before one, an error or more than `limit` bytes.
    static func readLine(from descriptor: Int32, limit: Int = 64 * 1_024) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= limit {
            let count = read(descriptor, &byte, 1)
            if count == 0 { return data.isEmpty ? nil : data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }

    @discardableResult
    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer -> Bool in
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

// MARK: - The helper side

enum IDEGitAskPassClient {
    /// True when this process was started by git or ssh as the askpass helper.
    static func isAskPassInvocation(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[IDEGitAskPassEnvironment.socket] != nil
    }

    /// Runs as the helper: asks the app, prints the answer. Exit 0 with the answer, 1 when the user
    /// cancelled or the app cannot be reached (git then fails the command), 2 when misconfigured.
    static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: (String) -> Void
    ) -> Int32 {
        guard let path = environment[IDEGitAskPassEnvironment.socket],
              let token = environment[IDEGitAskPassEnvironment.token]
        else { return 2 }
        let request = IDEGitAskPassRequest(
            token: token,
            session: environment[IDEGitAskPassEnvironment.session] ?? "",
            prompt: arguments.dropFirst().joined(separator: " ")
        )
        guard let reply = ask(request, socketPath: path), !reply.cancelled, let answer = reply.answer else { return 1 }
        output(answer + "\n")
        return 0
    }

    static func ask(_ request: IDEGitAskPassRequest, socketPath: String) -> IDEGitAskPassReply? {
        guard var address = IDEUnixSocket.address(for: socketPath),
              var line = try? JSONEncoder().encode(request)
        else { return nil }
        line.append(0x0A)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, IDEUnixSocket.writeAll(line, to: descriptor),
              let reply = IDEUnixSocket.readLine(from: descriptor)
        else { return nil }
        return try? JSONDecoder().decode(IDEGitAskPassReply.self, from: reply)
    }
}

// MARK: - The app side

/// Listens for helper processes and routes each prompt to the handler registered for the session
/// that started the command. A prompt for an unknown session, or with a wrong token, is cancelled.
final class IDEGitAskPassServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ prompt: String) async -> IDEGitAskPassReply

    static let shared = IDEGitAskPassServer()

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var descriptor: Int32 = -1
    private var directory: URL?
    private(set) var socketPath: String = ""
    let token: String

    private init() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts listening once. Returns false when the socket cannot be created, in which case git
    /// keeps running in batch mode and a command that needs a credential fails.
    @discardableResult
    func startIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { return true }

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var candidate = base.appendingPathComponent("umbra-ap-\(getpid())", isDirectory: true)
        if candidate.appendingPathComponent("s").path.utf8.count > IDEUnixSocket.maximumPathLength {
            candidate = URL(fileURLWithPath: "/tmp/umbra-ap-\(getuid())-\(getpid())", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(
                at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let path = candidate.appendingPathComponent("s").path
        unlink(path)
        guard var address = IDEUnixSocket.address(for: path) else { return false }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            return false
        }
        chmod(path, 0o600)
        descriptor = listener
        directory = candidate
        socketPath = path
        let accepting = Thread { [weak self] in self?.acceptLoop(listener) }
        accepting.name = "umbra.git.askpass"
        accepting.qualityOfService = .userInitiated
        accepting.start()
        // The socket and its folder are removed when the app quits; a crash leaves the 0700 folder
        // in the temporary directory, which the system clears.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.stop() }
        return true
    }

    /// Stops listening and removes the socket and its folder.
    func stop() {
        lock.lock()
        let listener = descriptor
        let folder = directory
        descriptor = -1
        directory = nil
        lock.unlock()
        if listener >= 0 { close(listener) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func register(session: String, handler: @escaping Handler) {
        lock.withLock { handlers[session] = handler }
    }

    func unregister(session: String) {
        lock.withLock { handlers[session] = nil }
    }

    /// What a network command started for `session` runs with. Falls back to batch mode (a prompt
    /// fails at once) when the server could not start.
    func environment(session: String) -> GitNetworkEnvironment {
        guard startIfNeeded(), let helper = Bundle.main.executableURL?.path else { return .batchMode }
        return GitNetworkEnvironment(variables: [
            "GIT_ASKPASS": helper,
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            "GIT_TERMINAL_PROMPT": "0",
            IDEGitAskPassEnvironment.socket: socketPath,
            IDEGitAskPassEnvironment.token: token,
            IDEGitAskPassEnvironment.session: session
        ])
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(connection)
            }
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        // A helper that connects and never writes must not hold a thread forever.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = IDEUnixSocket.readLine(from: connection),
              let request = try? JSONDecoder().decode(IDEGitAskPassRequest.self, from: line)
        else { return }
        let reply = answer(request)
        if let data = try? JSONEncoder().encode(reply) {
            IDEUnixSocket.writeAll(data + Data([0x0A]), to: connection)
        }
    }

    /// Decides the reply for a request, blocking until the user answers. Exposed for tests.
    func answer(_ request: IDEGitAskPassRequest) -> IDEGitAskPassReply {
        guard request.token == token, let handler = lock.withLock({ handlers[request.session] }) else { return .cancel }
        let box = ReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.reply = await handler(request.prompt)
            semaphore.signal()
        }
        semaphore.wait()
        return box.reply
    }

    private final class ReplyBox: @unchecked Sendable {
        var reply = IDEGitAskPassReply.cancel
    }
}
