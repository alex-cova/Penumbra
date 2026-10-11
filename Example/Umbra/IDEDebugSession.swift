import Foundation

/// What a debugger is doing. Shaped from the lldb-dap session: launch, a stop, frames, variables, step.
enum IDEDebugSessionState: Equatable, Sendable {
    case idle
    case launching
    case running
    case stopped(file: URL?, line: Int, reason: String)
    case terminated
    case failed(String)
}

struct IDEDebugThread: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
}

struct IDEDebugFrame: Identifiable, Equatable, Sendable {
    /// The adapter's frame id.
    var id: Int
    var name: String
    var file: URL?
    var line: Int
}

struct IDEDebugVariable: Identifiable, Equatable, Sendable {
    var name: String
    var type: String
    var value: String
    /// Non-zero when the adapter can list children.
    var variablesReference: Int
    var id: String { name }
}

/// Breakpoints, threads, frames, variables, evaluate and step.
///
/// Both `DAPDebugSession` and `JavaDebugSessionBridge` conform. A default implementation would not
/// run on an existential, so every method is required.
@MainActor
protocol IDEDebugSession: AnyObject {
    var state: IDEDebugSessionState { get }
    var threads: [IDEDebugThread] { get }
    var frames: [IDEDebugFrame] { get }
    var variables: [IDEDebugVariable] { get }
    var selectedThreadID: Int? { get }
    var selectedFrameID: Int? { get }
    var isActive: Bool { get }
    var isStopped: Bool { get }

    func resume()
    func pause()
    func stepOver()
    func stepInto()
    func stepOut()
    func stop()
    func selectThread(_ id: Int)
    func selectFrame(_ id: Int)
    func evaluate(_ expression: String) async -> String?
    /// Replaces the line breakpoints in each path. A path with an empty list clears that file.
    func setLineBreakpoints(_ linesByPath: [String: [Int]]) async
}

enum IDEDebugSessionMapping {
    static func state(_ state: JavaDebugSessionState) -> IDEDebugSessionState {
        switch state {
        case .idle: .idle
        case .launching: .launching
        case .running: .running
        case .stopped(let file, let line, let reason): .stopped(file: file, line: line, reason: reason)
        case .terminated: .terminated
        case .failed(let message): .failed(message)
        }
    }

    static func thread(_ thread: JavaDebugThread) -> IDEDebugThread {
        IDEDebugThread(id: thread.id, name: thread.name)
    }

    static func frame(_ frame: JavaDebugStackFrame) -> IDEDebugFrame {
        IDEDebugFrame(
            id: frame.index,
            name: frame.name,
            file: frame.filePath.hasPrefix("/") ? URL(fileURLWithPath: frame.filePath) : nil,
            line: frame.line
        )
    }

    static func variable(_ value: JavaDebugValue) -> IDEDebugVariable {
        IDEDebugVariable(
            name: value.name ?? "",
            type: value.type,
            value: value.value,
            variablesReference: value.hasChildren ? 1 : 0
        )
    }
}

/// `JavaDebugSession` as an ``IDEDebugSession``. The Java debugger's own API is unchanged.
@MainActor
final class JavaDebugSessionBridge: IDEDebugSession {
    private let session: JavaDebugSession

    init(_ session: JavaDebugSession) {
        self.session = session
    }

    var state: IDEDebugSessionState { IDEDebugSessionMapping.state(session.state) }

    var threads: [IDEDebugThread] { session.threads.map(IDEDebugSessionMapping.thread) }

    var frames: [IDEDebugFrame] { session.stackFrames.map(IDEDebugSessionMapping.frame) }

    var variables: [IDEDebugVariable] { session.variables.map(IDEDebugSessionMapping.variable) }

    var selectedThreadID: Int? {
        session.threads.first(where: \.isCurrent)?.id ?? session.stopInfo?.threadID
    }

    var selectedFrameID: Int? { session.selectedFrameIndex }

    var isActive: Bool { session.isActive }

    var isStopped: Bool { session.isStopped }

    func resume() { session.resume() }
    func pause() { session.pause() }
    func stepOver() { session.stepOver() }
    func stepInto() { session.stepInto() }
    func stepOut() { session.stepOut() }
    func stop() { session.stop() }
    func selectThread(_ id: Int) { session.selectThread(id) }
    func selectFrame(_ id: Int) { session.selectFrame(id) }

    func evaluate(_ expression: String) async -> String? {
        switch await session.evaluate(expression, record: false) {
        case .value(let value): return value.value
        case .failure(let message): return message
        }
    }

    func setLineBreakpoints(_ linesByPath: [String: [Int]]) async {
        let breakpoints = linesByPath.flatMap { path, lines in
            lines.map { JavaBreakpoint(filePath: path, line: $0) }
        }
        await session.sync(breakpoints, muted: false)
    }
}
