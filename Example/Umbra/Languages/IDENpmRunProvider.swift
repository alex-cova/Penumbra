import Foundation

/// Run for a TypeScript or JavaScript file when the folder has a package.json with scripts.
/// Debugging stays unavailable. A run starts the preferred script and does not open a Run-tab session.
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

    func canDebug(fileURL _: URL?) -> Bool { false }

    func runHelp(fileURL _: URL?) -> String {
        if let name = npm.preferredScript { return "Run npm \(name)" }
        return "Run npm"
    }

    func debugHelp(fileURL _: URL?, canRun _: Bool) -> String {
        "Debugging is not available for this language"
    }

    func run(_ document: IDERunDocument, mode: IDERunMode) {
        guard workspace != nil, mode == .run, canRun(document), let name = npm.preferredScript else { return }
        npm.runTasks([name])
    }

    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
        guard canRun(document) else { return false }
        guard mode == .run else { return true }
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
}
