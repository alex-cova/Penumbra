import Foundation
import JavaIntelligence

struct JavaDebugStackFrame: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let className: String
    let filePath: String
    let line: Int
    var id: Int { index }
}

struct JavaDebugVariable: Identifiable, Equatable, Sendable {
    let name: String
    let type: String
    let value: String
    var id: String { name }
}

enum JavaDebugSessionState: Equatable, Sendable {
    case idle
    case launching
    case running
    case stopped(file: URL, line: Int, reason: String)
    case terminated
    case failed(String)
}

/// Talks to the JDI adapter over stdin/stdout JSON lines.
@MainActor
@Observable
final class JavaDebugSession {
    private(set) var state: JavaDebugSessionState = .idle
    private(set) var stackFrames: [JavaDebugStackFrame] = []
    private(set) var variables: [JavaDebugVariable] = []
    private(set) var selectedFrameIndex = 0

    private var process: Process?
    private var inputHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let launcher = JavaDebugProcessLauncher()
    private(set) var isGradleAttachSession = false

    var isActive: Bool {
        switch state {
        case .idle, .terminated, .failed(_): return false
        default: return true
        }
    }

    func start(launch: JavaManagedLaunch, breakpoints: [JavaBreakpoint]) async {
        stop()
        state = .launching
        do {
            let javaHome = launch.javaExecutable.deletingLastPathComponent().deletingLastPathComponent()
            let process = try launcher.startAdapter(javaHome: javaHome)
            self.process = process
            inputHandle = (process.standardInput as? Pipe)?.fileHandleForWriting
            readTask = Task { await self.readLoop(process: process) }
            let classpath = launch.classpath.map(\.path).joined(separator: ":")
            var request: [String: Any] = [
                "command": "launch",
                "java": launch.javaExecutable.path,
                "classpath": classpath,
                "mainClass": launch.mainClass,
                "programArgs": launch.programArguments.joined(separator: " "),
                "vmArgs": launch.vmArguments.filter { !$0.contains("jdwp") }.joined(separator: " "),
                "port": launch.jdwpPort,
                "suspend": launch.suspendOnStart
            ]
            if !launch.environment.isEmpty {
                request["environment"] = launch.environment
            }
            _ = try await send(request)
            for breakpoint in breakpoints where breakpoint.isEnabled {
                _ = try await send([
                    "command": "setBreakpoint",
                    "file": breakpoint.filePath,
                    "line": breakpoint.line
                ])
            }
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Starts the JDI adapter for a Gradle `--debug-jvm` attach session.
    func prepareAdapter(javaHome: URL) async throws {
        stop()
        isGradleAttachSession = true
        state = .launching
        let process = try launcher.startAdapter(javaHome: javaHome)
        self.process = process
        inputHandle = (process.standardInput as? Pipe)?.fileHandleForWriting
        readTask = Task { await self.readLoop(process: process) }
    }

    /// Attaches to the Gradle-spawned JVM, applies breakpoints, and optionally resumes.
    func attachForGradle(
        port: Int = JavaLaunchCommand.gradleDebugJdwpPort,
        suspendOnStart: Bool,
        breakpoints: [JavaBreakpoint]
    ) async {
        do {
            try await attachWithRetry(port: port, maxAttempts: 60)
            for breakpoint in breakpoints where breakpoint.isEnabled {
                _ = try await send([
                    "command": "setBreakpoint",
                    "file": breakpoint.filePath,
                    "line": breakpoint.line
                ])
            }
            if !suspendOnStart {
                resume()
            }
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func resume() {
        Task { _ = try? await send(["command": "resume"]) }
    }

    func stepOver() {
        Task { _ = try? await send(["command": "stepOver"]) }
    }

    func refreshStack() {
        Task {
            guard let response = try? await send(["command": "stackFrames"]),
                  let frames = response["frames"] as? [[String: Any]] else { return }
            stackFrames = frames.compactMap { frame in
                guard let index = frame["index"] as? Int,
                      let name = frame["name"] as? String,
                      let className = frame["className"] as? String,
                      let file = frame["file"] as? String,
                      let line = frame["line"] as? Int else { return nil }
                return JavaDebugStackFrame(index: index, name: name, className: className, filePath: file, line: line)
            }
            await refreshVariables()
        }
    }

    func selectFrame(_ index: Int) {
        selectedFrameIndex = index
        Task { await refreshVariables() }
    }

    func refreshVariables() async {
        guard let response = try? await send(["command": "localVariables", "frameIndex": selectedFrameIndex]),
              let variables = response["variables"] as? [[String: Any]] else { return }
        self.variables = variables.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let type = entry["type"] as? String,
                  let value = entry["value"] as? String else { return nil }
            return JavaDebugVariable(name: name, type: type, value: value)
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let process {
            _ = try? sendSync(["command": "disconnect"])
            if process.isRunning { process.terminate() }
        }
        process = nil
        inputHandle = nil
        pending.values.forEach { $0.resume(throwing: JavaDebugProcessError.disconnected) }
        pending.removeAll()
        stackFrames = []
        variables = []
        selectedFrameIndex = 0
        isGradleAttachSession = false
        if case .failed = state { return }
        state = .terminated
    }

    private func attachWithRetry(port: Int, maxAttempts: Int) async throws {
        var lastError: Error = JavaDebugProcessError.launchFailed("could not attach")
        for _ in 0..<maxAttempts {
            do {
                _ = try await send(["command": "attach", "port": port])
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    private func readLoop(process: Process) async {
        guard let output = process.standardOutput as? Pipe else { return }
        var buffer = ""
        while !Task.isCancelled {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer += String(decoding: chunk, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                handleEventLine(line)
            }
        }
        if !process.isRunning, case .failed = state {} else if !process.isRunning {
            state = .terminated
        }
    }

    private func handleEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let event = json["event"] as? String {
            switch event {
            case "stopped":
                let filePath = json["file"] as? String ?? ""
                let line = json["line"] as? Int ?? 0
                let reason = json["reason"] as? String ?? "breakpoint"
                state = .stopped(file: URL(fileURLWithPath: filePath), line: line, reason: reason)
                refreshStack()
            case "terminated":
                state = .terminated
            default:
                break
            }
            return
        }
        if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if json["ok"] as? Bool == true {
                continuation.resume(returning: json)
            } else {
                continuation.resume(throwing: JavaDebugProcessError.launchFailed(json["error"] as? String ?? "unknown error"))
            }
        }
    }

    private func send(_ body: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try sendSync(body, continuation: continuation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendSync(_ body: [String: Any], continuation: CheckedContinuation<[String: Any], Error>? = nil) throws -> [String: Any]? {
        guard let inputHandle else { throw JavaDebugProcessError.disconnected }
        var payload = body
        let id = nextRequestID
        nextRequestID += 1
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: data, encoding: .utf8) else { throw JavaDebugProcessError.launchFailed("invalid request") }
        line.append("\n")
        inputHandle.write(line.data(using: .utf8)!)
        if let continuation {
            pending[id] = continuation
        }
        return nil
    }
}

enum JavaDebugPortPicker {
    static func pickPort(preferred: Int?) -> Int {
        if let preferred, preferred > 1024, preferred < 65535 { return preferred }
        return 5005 + Int.random(in: 0..<1000)
    }
}
