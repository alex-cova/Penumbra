import AgentKit
import Foundation

/// Umbra's `ACPHostServices`: `fs/*` through `IDEAgentWorkspace` (unsaved buffers, `PathJail`,
/// checkpoint recording in `ACPClientSession`), `terminal/*` through `AgentCommandRunner`.
/// Capabilities are advertised strictly from what is provided here (plan step 4/5).
enum IDEACPHostServices {
    static func make(workspace: IDEAgentWorkspace, root: URL) -> ACPHostServices {
        let terminals = IDEACPTerminalStore(root: root, workspace: workspace)
        return ACPHostServices(
            readTextFile: { request in
                try await workspace.readText(path: relativePath(request.path, workspace: workspace))
            },
            writeTextFile: { request in
                let relative = try relativePath(request.path, workspace: workspace)
                try workspace.checkWritable(path: relative)
                if let current = try? await workspace.readText(path: relative) {
                    let whole = AgentTextEdit(
                        location: 0, length: (current as NSString).length, replacement: request.content)
                    try await workspace.replaceText(path: relative, expecting: current, edits: [whole])
                } else {
                    try await workspace.createFile(path: relative, contents: request.content)
                }
            },
            createTerminal: { request in
                try await terminals.create(request)
            },
            terminalOutput: { terminalId in
                await terminals.output(terminalId)
            },
            waitForTerminalExit: { terminalId in
                await terminals.waitForExit(terminalId)
            },
            killTerminal: { terminalId in
                await terminals.kill(terminalId)
            },
            releaseTerminal: { terminalId in
                await terminals.release(terminalId)
            })
    }

    /// ACP paths are absolute; the workspace speaks project-relative. The jail resolves (and
    /// refuses) outside paths.
    static func relativePath(_ path: String, workspace: IDEAgentWorkspace) throws -> String {
        let url = try workspace.disk.jail.resolve(path)
        return workspace.disk.jail.relativePath(of: url)
    }
}

/// Terminals an ACP agent created, keyed by the id handed back in `terminal/create`.
final class IDEACPTerminalStore: @unchecked Sendable {
    private struct Entry {
        var output = ""
        var exitCode: Int32?
        var finished = false
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let root: URL
    private let workspace: IDEAgentWorkspace

    init(root: URL, workspace: IDEAgentWorkspace) {
        self.root = root
        self.workspace = workspace
    }

    func create(_ request: ACPCreateTerminalRequest) async throws -> String {
        let id = UUID().uuidString
        let commandLine = ([request.command] + request.args).map(Self.shellQuoted).joined(separator: " ")
        let cwd = request.cwd.map { URL(fileURLWithPath: $0) } ?? root
        var environment = ProcessInfo.processInfo.environment
        for variable in request.env { environment[variable.name] = variable.value }
        lock.withLock { entries[id] = Entry() }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AgentCommandRunner.run(
                    AgentCommandSpec(command: commandLine, workingDirectory: cwd, environment: environment, timeout: 3600),
                    onOutput: { [weak self] chunk in
                        self?.lock.withLock { self?.entries[id]?.output += chunk }
                    })
                lock.withLock {
                    entries[id]?.output = result.output
                    entries[id]?.exitCode = result.exitCode
                    entries[id]?.finished = true
                }
            } catch {
                lock.withLock {
                    entries[id]?.output += error.localizedDescription
                    entries[id]?.exitCode = 1
                    entries[id]?.finished = true
                }
            }
        }
        lock.withLock { entries[id]?.task = task }
        return id
    }

    func output(_ id: String) async -> ACPTerminalOutput {
        lock.withLock {
            guard let entry = entries[id] else { return ACPTerminalOutput(output: "") }
            return ACPTerminalOutput(output: entry.output, exitCode: entry.finished ? entry.exitCode.map(Int.init) : nil)
        }
    }

    func waitForExit(_ id: String) async -> ACPTerminalOutput {
        while true {
            let done: Bool = lock.withLock { entries[id]?.finished ?? true }
            if done { return await output(id) }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func kill(_ id: String) async {
        lock.withLock { entries[id]?.task }?.cancel()
    }

    func release(_ id: String) async {
        let task: Task<Void, Never>? = lock.withLock { entries.removeValue(forKey: id)?.task }
        task?.cancel()
    }

    static func shellQuoted(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/=:".contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
