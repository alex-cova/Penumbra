import Foundation
import Observation
import SwiftUI

/// Where a project of one kind stands in a window: whether it was recognized, whether the user let
/// its build scripts run, and how the last sync ended. Generalized from what was
/// `IDEJavaSupport.GradleSyncState`; the status bar, the console tab and the Reload / Show Output
/// commands read it.
enum IDEProjectSyncState: Equatable {
    /// No project open, or the open folder isn't a project of this kind.
    case notDetected
    /// A project was detected but hasn't synced yet (auto-sync is off, or the user hasn't answered
    /// the trust prompt).
    case awaitingTrust
    /// The user declined to trust this project's build scripts.
    case untrusted
    case syncing
    case synced(modules: Int, dependencies: Int)
    case failed(summary: String)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// How a user-visible (non-silent) sync ended, so the host can post a notification.
enum IDEProjectSyncOutcome: Equatable {
    case synced(modules: Int, dependencies: Int)
    case failed(summary: String)
    case cancelled
}

/// A task run that ended (finished, timed out or cancelled), with whatever output it produced, so a
/// language can pull compiler errors and test results out of it.
struct IDEProjectTaskReport: Sendable {
    let tasks: [String]
    let root: URL
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var output: String { stdout + "\n" + stderr }
}

/// A task the project can run (`build`, `:app:test`), as the model lists it.
struct IDEProjectTask: Equatable, Sendable {
    /// What `runTasks` takes: Gradle's task path (`:app:test`).
    let path: String
    let name: String
    /// The module it belongs to (`:app`); `:` for the root project.
    let module: String
    /// The task group (`build`, `verification`), empty when it has none.
    let group: String
    let summary: String
}

/// What a project system asks of the host, as closures the host sets once. None of them keeps the
/// window alive: the host captures itself weakly, as it does for `LanguageEnvironment`.
struct IDEProjectEnvironment {
    /// Asks the user whether to trust `root` to run build scripts (a sheet). `nil` means never prompt
    /// automatically: a sync for an undecided root settles on `.awaitingTrust` instead of running anything.
    var requestTrust: (@MainActor (URL) async -> Bool)?
    /// A sync ended in `.failed` (not on a user-initiated cancel), so the host can surface the console.
    var syncFailed: @MainActor () -> Void = {}
    /// A user-visible sync ended.
    var syncFinished: @MainActor (IDEProjectSyncOutcome) -> Void = { _ in }
    /// A task run ended.
    var tasksFinished: @MainActor (IDEProjectTaskReport) -> Void = { _ in }
}

/// A short, human-readable line for the status card ("Indexing JDK 24…", "Resolving Gradle
/// project…", or nil once idle). One per window, written by the project system and by the language
/// services that index in the background. Each writer clears only a message it set itself, so a
/// finishing task never blanks another's.
@MainActor
@Observable
final class IDEProjectStatus {
    var message: String?

    func set(_ message: String) {
        self.message = message
    }

    /// Clears the message if it is `message`.
    func clear(_ message: String) {
        if self.message == message { self.message = nil }
    }
}

/// One kind of project Umbra understands: it recognizes a folder, syncs the project model (asking for
/// trust first), keeps a console log, runs the project's tasks and shows a tool window. Gradle is the
/// first (`IDEGradleProjectSystem`); npm is the second (`IDENpmProjectSystem`). SwiftPM or Cargo would
/// be others. See `docs/LANGUAGE_SUPPORT_PLAN.md` (phase 5 and its follow-up).
///
/// One instance per window, made with the window's other services (`IDEIntelligenceServices`). A
/// project system is not a language service: a language that wants the model (Java reads Gradle's)
/// is handed it by whoever builds both.
@MainActor
protocol IDEProjectSystem: AnyObject {
    var id: String { get }
    /// "Gradle": titles the tool window and the console and names the sync in notifications.
    var displayName: String { get }
    var environment: IDEProjectEnvironment { get set }

    /// The open folder is a project of this kind.
    var isActive: Bool { get }
    var syncState: IDEProjectSyncState { get }
    /// A sync or a task run is going.
    var isBusy: Bool { get }
    var runningTasks: [String] { get }
    /// Output of the latest sync or task run.
    var console: IDEProjectConsoleLog { get }
    /// The tasks of the synced model, root project first; empty before a sync.
    var tasks: [IDEProjectTask] { get }
    /// Standardized paths of the source directories of the synced model; empty before a sync.
    var sourceRootPaths: Set<String> { get }
    /// Files that define the project changed on disk outside of a sync (a banner offers Reload).
    var hasConfigurationChanges: Bool { get }

    /// The folder changed (or closed). Synchronous, so what the caller reads next reflects it.
    func projectDidChange(root: URL?)
    /// Syncs again, asking for trust even if the user declined before.
    func reload()
    func dismissConfigurationChanges()
    func cancelSync()
    func cancelTasks()
    /// Runs project tasks through the console. No-op while busy.
    func runTasks(_ tasks: [String])
    /// Builds the whole project through the console (Build Project).
    func build()
    /// The window is closing: stop everything this project started.
    func stop()

    /// Contributions to the window's chrome, only while `isActive`.
    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow]
    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution]
    /// Buttons for the titlebar (Build Project).
    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem]
    /// The right-hand tool window's content.
    func makeSidebar() -> AnyView
    /// The bottom-panel tab that shows this system's console, when it has one. The status toast
    /// opens it while this system is the one being followed.
    var consoleTab: IDEBottomPanelTab? { get }
    /// Whether that console tab, and its tool-window entry, should be offered right now.
    var showsConsole: Bool { get }
    /// A diagram this system knows how to draw. Nil when `request` belongs to someone else.
    func loadDiagram(_ request: IDEDiagramRequest, settings: IDEDiagramSettings, workspace: IDEWorkspace) async -> IDEDiagramLoad?
}

extension IDEProjectSystem {
    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] { [] }
    var consoleTab: IDEBottomPanelTab? { nil }
    var showsConsole: Bool { isActive && (isBusy || !console.lines.isEmpty) }
    func loadDiagram(
        _: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace _: IDEWorkspace
    ) async -> IDEDiagramLoad? { nil }
}

/// The project systems of one window, in the order they claim a folder.
@MainActor
@Observable
final class IDEProjectSystems {
    let systems: [any IDEProjectSystem]

    init(_ systems: [any IDEProjectSystem]) {
        self.systems = systems
    }

    /// The system that recognized the open folder, if any. When several do, this is the first, and
    /// it owns the right-hand sidebar.
    var active: (any IDEProjectSystem)? {
        activeSystems.first
    }

    /// Every system that recognized the open folder, in registration order. A folder can be a
    /// Gradle project and an npm project at once; each keeps its own console and tasks.
    var activeSystems: [any IDEProjectSystem] {
        systems.filter(\.isActive)
    }

    /// The first active system whose build files changed. The reload banner names this one and
    /// reloads only it.
    var pendingReload: (any IDEProjectSystem)? {
        activeSystems.first { $0.hasConfigurationChanges }
    }

    /// The system the status toast reads: the first one that is busy, otherwise ``active``.
    var statusSystem: (any IDEProjectSystem)? {
        systems.first { $0.isBusy } ?? active
    }

    var isBusy: Bool { systems.contains { $0.isBusy } }

    func system(id: String) -> (any IDEProjectSystem)? {
        systems.first { $0.id == id }
    }

    func start(environment: IDEProjectEnvironment) {
        for system in systems { system.environment = environment }
    }

    func projectDidChange(root: URL?) {
        for system in systems { system.projectDidChange(root: root) }
    }

    func stop() {
        for system in systems.reversed() { system.stop() }
    }
}
