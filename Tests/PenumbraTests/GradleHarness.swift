import Foundation
import JavaIntelligence
@testable import Umbra

/// What `IDEGradleProjectSystemTests` sees of a window's Gradle project, whatever type holds it.
@MainActor
final class GradleHarness {
    enum Sync: Equatable {
        case notGradle
        case awaitingTrust
        case untrusted
        case syncing
        case synced(subprojects: Int, jars: Int)
        case failed(summary: String)
    }

    enum Outcome: Equatable {
        case synced(subprojects: Int, jars: Int)
        case failed(summary: String)
        case cancelled
    }

    enum RunOutcome: Equatable {
        case finished(exitCode: Int32)
        case timedOut
        case cancelled
        case notStarted(String)
        case failed(String)
    }

    struct FinishedTasks {
        let tasks: [String]
        let root: URL
        let exitCode: Int32
    }

    private let gradle: IDEGradleProjectSystem
    private let java: IDEJavaSupport
    private let trustStore: GradleTrustStore
    private let cacheRoot: URL

    private(set) var asked: [String] = []
    private(set) var outcomes: [Outcome] = []
    private(set) var failures = 0
    private(set) var finishedTasks: [FinishedTasks] = []

    /// What the trust prompt answers; `nil` shows no prompt, so an undecided project waits.
    var requestTrust: ((URL) async -> Bool)? {
        didSet {
            guard let handler = requestTrust else {
                gradle.environment.requestTrust = nil
                return
            }
            gradle.environment.requestTrust = { [weak self] url in
                self?.asked.append(url.path)
                return await handler(url)
            }
        }
    }

    init(base: URL, reusingStoresOf other: GradleHarness? = nil) {
        trustStore = other?.trustStore ?? GradleTrustStore(storeURL: base.appendingPathComponent("trust.json"))
        cacheRoot = other?.cacheRoot ?? base.appendingPathComponent("model-cache", isDirectory: true)
        let jdk = IDEJDKSelection(store: JDKSelectionStore(storeURL: base.appendingPathComponent("jdk-\(UUID().uuidString).json")))
        let status = IDEProjectStatus()
        gradle = IDEGradleProjectSystem(jdk: jdk, status: status, trustStore: trustStore, modelCacheRoot: cacheRoot)
        java = IDEJavaSupport(jdk: jdk, gradle: gradle, status: status, shardHub: JavaSharedShardHub())
        gradle.environment.syncFinished = { [weak self] outcome in
            switch outcome {
            case .synced(let modules, let dependencies): self?.outcomes.append(.synced(subprojects: modules, jars: dependencies))
            case .failed(let summary): self?.outcomes.append(.failed(summary: summary))
            case .cancelled: self?.outcomes.append(.cancelled)
            }
        }
        gradle.environment.syncFailed = { [weak self] in self?.failures += 1 }
        gradle.environment.tasksFinished = { [weak self] report in
            self?.finishedTasks.append(FinishedTasks(tasks: report.tasks, root: report.root, exitCode: report.exitCode))
        }
    }

    func teardown() {
        gradle.stop()
        java.teardown()
    }

    // MARK: - Driving

    /// The order `IDEWorkspace` uses: the project system first, then the language.
    func setRoot(_ url: URL?) {
        gradle.projectDidChange(root: url)
        java.projectDidChange(root: url)
    }

    func reload() {
        gradle.reload()
    }

    func cancelSync() {
        gradle.cancelSync()
    }

    func cancelTasks() {
        gradle.cancelTasks()
    }

    func dismissBuildFileChanges() {
        gradle.dismissConfigurationChanges()
    }

    func runTasks(_ tasks: [String]) async -> RunOutcome {
        await withCheckedContinuation { continuation in
            gradle.runGradleTasks(tasks) { outcome in
                switch outcome {
                case .finished(let result): continuation.resume(returning: .finished(exitCode: result.exitCode))
                case .timedOut: continuation.resume(returning: .timedOut)
                case .cancelled: continuation.resume(returning: .cancelled)
                case .notStarted(let reason): continuation.resume(returning: .notStarted(reason))
                case .failed(let reason): continuation.resume(returning: .failed(reason))
                }
            }
        }
    }

    func isTrusted(_ url: URL) -> Bool {
        trustStore.isTrusted(url)
    }

    // MARK: - Reading

    var state: Sync {
        switch gradle.syncState {
        case .notDetected: .notGradle
        case .awaitingTrust: .awaitingTrust
        case .untrusted: .untrusted
        case .syncing: .syncing
        case .synced(let modules, let dependencies): .synced(subprojects: modules, jars: dependencies)
        case .failed(let summary): .failed(summary: summary)
        }
    }

    var taskPaths: [String] { gradle.tasks.map(\.path) }
    var taskGroups: [String] { gradle.tasks.map(\.group) }
    var taskModules: [String] { gradle.tasks.map(\.module) }
    var isGradleProject: Bool { gradle.isActive }
    var isBusy: Bool { gradle.isBusy }
    var isRunningTasks: Bool { gradle.isRunningTasks }
    var runningTaskPaths: [String] { gradle.runningTasks }
    var buildFilesChanged: Bool { gradle.hasConfigurationChanges }
    var modelModuleCount: Int? { gradle.model?.subprojects.count }
    var sourceRootPaths: Set<String> { gradle.sourceRootPaths }
    var moduleGraphComponentCount: Int? { gradle.moduleDependencyGraph?.components.count }
    var consoleText: String { gradle.console.lines.map(\.text).joined(separator: "\n") }
}
