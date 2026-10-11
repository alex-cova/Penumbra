import Foundation

/// Run for a TypeScript or JavaScript file when the folder has a package.json with scripts.
/// Debug launches that file under node through js-debug. A run starts the preferred script and does
/// not open a Run-tab session.
@MainActor
final class IDENpmRunProvider: IDERunProvider {
    let id = "npm"
    let languageIdentifiers: Set<String> = ["typescript", "javascript"]
    let npm: IDENpmProjectSystem
    weak var workspace: IDEWorkspace?

    init(npm: IDENpmProjectSystem, workspace: IDEWorkspace) {
        self.npm = npm
        self.workspace = workspace
    }

    func canRun(_ document: IDERunDocument) -> Bool {
        guard let language = document.languageIdentifier, languageIdentifiers.contains(language) else { return false }
        return npm.isActive && !npm.tasks.isEmpty
    }

    func canDebug(fileURL: URL?) -> Bool {
        guard npm.isActive, let fileURL else { return false }
        return Self.debugExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private static let debugExtensions: Set<String> = ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"]

    func runHelp(fileURL _: URL?) -> String {
        if let name = npm.preferredScript { return "Run npm \(name)" }
        return "Run npm"
    }

    func debugHelp(fileURL: URL?, canRun _: Bool) -> String {
        if canDebug(fileURL: fileURL) { return "Debug this file" }
        return "Debugging is not available for this language"
    }

    func run(_ document: IDERunDocument, mode: IDERunMode) {
        guard workspace != nil else { return }
        if mode == .debug {
            guard let url = document.url, canDebug(fileURL: url) else { return }
            debugFile(url)
            return
        }
        guard canRun(document), let name = npm.preferredScript else { return }
        npm.runTasks([name])
    }

    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
        guard canRun(document) else { return false }
        if mode == .debug {
            guard let url = document.url, canDebug(fileURL: url) else { return false }
            debugFile(url)
            return true
        }
        guard let name = npm.preferredScript else { return false }
        npm.runTasks([name])
        return true
    }

    func rerun(_: IDERunSession) {
        guard workspace != nil, let name = npm.preferredScript else { return }
        npm.runTasks([name])
    }

    var hasActiveWork: Bool { npm.isRunningTasks }

    func stop() {
        npm.cancelTasks()
    }

    /// The current file, under node, through js-debug's `dapDebugServer.js`.
    private func debugFile(_ url: URL) {
        guard let workspace else { return }
        workspace.configureDebugSession()
        workspace.dapDebugSession.beginLaunch(of: url.lastPathComponent)
        workspace.showBottomTab(.debug)
        let userPath = UserDefaults.standard.string(forKey: "umbra.jsDebugPath")
            ?? ProcessInfo.processInfo.environment["UMBRA_JS_DEBUG_PATH"]
        guard let script = JSDebugDiscovery.serverScript(userPath: userPath), let node = JSDebugDiscovery.node() else {
            workspace.dapDebugSession.noteFailure("js-debug was not found. Set umbra.jsDebugPath to dapDebugServer.js.")
            return
        }
        let lines = workspace.enabledLineBreakpointsByPath()
        Task {
            await workspace.dapDebugSession.launchJavaScript(
                node: node,
                serverScript: URL(fileURLWithPath: script),
                program: url,
                workingDirectory: url.deletingLastPathComponent(),
                lineBreakpoints: lines
            )
        }
    }
}

enum JSDebugDiscovery {
    /// `dapDebugServer.js` from a js-debug DAP build. The caller passes the user path or `UMBRA_JS_DEBUG_PATH`.
    static func serverScript(userPath: String?) -> String? {
        if let userPath, FileManager.default.fileExists(atPath: userPath) { return userPath }
        return nil
    }

    static func node() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("node").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
