import Penumbra
import SwiftUI

/// A menu-bar menu a language module adds while it applies (Java for a Java file or Gradle project,
/// HTTP for a shown `.http` file). SwiftUI cannot build a menu bar from a runtime list, so
/// `IDEAppCommands` has one line per built-in module that shows the menu the module returns.
struct IDEModuleMenu {
    let title: String
    /// The menu items. Built from the focused window's reference, never the workspace itself: menu
    /// items outlive their window, and a stored workspace would stay alive with them.
    let content: @MainActor (IDEWorkspaceRef) -> AnyView
}

/// A Settings page a language module adds, in the sidebar after Project and before Agent.
struct IDEPreferencesPane {
    let domain: IDEPreferencesDomain
    let content: @MainActor (IDEPreferences, IDEWorkspace) -> AnyView
}

/// One button or control a module (or a project system) puts in the titlebar's action cluster.
struct IDEToolbarItem: Identifiable {
    struct Button {
        let systemImage: String
        let help: String
        var tint: Color?
        /// Drawn as the open one (a preview that is showing).
        var isActive = false
        var isEnabled = true
        let action: @MainActor () -> Void
    }

    enum Content {
        case button(Button)
        /// Anything else (the run configuration picker).
        case custom(AnyView)
    }

    let id: String
    /// Where it sits in the cluster, lowest first (``Order``).
    let order: Int
    let content: Content

    static func button(
        id: String, order: Int, systemImage: String, help: String, tint: Color? = nil,
        isActive: Bool = false, isEnabled: Bool = true, action: @escaping @MainActor () -> Void
    ) -> IDEToolbarItem {
        IDEToolbarItem(id: id, order: order, content: .button(Button(
            systemImage: systemImage, help: help, tint: tint, isActive: isActive, isEnabled: isEnabled, action: action
        )))
    }

    /// The positions of the items in the order they have always had, sparse so a module can add one
    /// between two. The close-editor-group button comes first and is the window's.
    enum Order {
        static let build = 100
        static let runConfigurations = 200
        static let run = 210
        static let debug = 220
        static let stop = 230
        static let tests = 240
        static let send = 300
        static let agentRun = 400
        static let exportPreview = 410
        static let preview = 500
    }
}

/// An item a module puts in the status bar. Each is followed by the bar's `·` separator.
struct IDEStatusItem: Identifiable {
    enum Placement {
        /// Before the problem counts (a request in flight).
        case leading
        /// After the line and column, before the syntax and encoding pickers (the JDK).
        case trailing
    }

    let id: String
    let placement: Placement
    let order: Int
    let content: AnyView
}

/// Items a module adds to the View menu. Built from the focused window's reference, never the
/// workspace itself: menu items outlive their window.
struct IDEViewMenuContribution: Identifiable {
    let id: String
    let content: @MainActor (IDEWorkspaceRef) -> AnyView
}

/// What a language adds to Umbra's chrome, beside the intelligence its `LanguageService` provides:
/// palette commands, menus, Settings pages, tool-window stripe entries, bottom and sidebar tabs,
/// toolbar buttons and status-bar items. See `docs/LANGUAGE_SUPPORT_PLAN.md`.
///
/// Modules are stateless. A language's per-window state (its `IDEJavaSupport`, its `IDEHTTPSupport`)
/// stays on the workspace, which is passed to each call, so a module never keeps a window alive.
/// Every member has a default, so a module overrides only what it has.
@MainActor
protocol IDELanguageModule {
    var id: String { get }

    /// Command palette entries. Registered for every window; a command whose language is not active
    /// decides for itself what to do when chosen.
    func commands(for workspace: IDEWorkspace) -> [EditorCommand]

    /// Tool-window stripe entries available right now. Each carries an `order` that places it among the
    /// built-in ones.
    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow]

    /// Bottom-panel tabs available right now: the strip item and the panel for each.
    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution]

    /// Left-sidebar tabs. They are offered through their descriptor's `isAvailable`.
    var sidebarTabs: [IDESidebarTabDescriptor] { get }

    /// The menu-bar menu, or nil while the module does not apply.
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu?

    var preferencePanes: [IDEPreferencesPane] { get }

    /// Buttons in the titlebar's action cluster, available now. Evaluated while the toolbar draws, so
    /// reading the workspace's state here keeps the buttons current.
    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem]

    /// Status-bar items, available now.
    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem]

    /// Items for the View menu, available now.
    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution]

    /// What makes Run, Debug and Run in Context work on this language's files: one per window, made
    /// once. The provider must hold `workspace` weakly.
    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)?

    /// Extra rows for the Symbols tab, after Java's members. Read an index the window already holds.
    func symbolPaletteSources(for workspace: IDEWorkspace) -> [any SearchEverywhereProvider]

    /// A diagram this module knows how to draw. Nil when `request` belongs to someone else.
    func loadDiagram(_ request: IDEDiagramRequest, settings: IDEDiagramSettings, workspace: IDEWorkspace) async -> IDEDiagramLoad?
}

extension IDELanguageModule {
    func commands(for workspace: IDEWorkspace) -> [EditorCommand] { [] }
    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] { [] }
    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] { [] }
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? { nil }
    var preferencePanes: [IDEPreferencesPane] { [] }
    var sidebarTabs: [IDESidebarTabDescriptor] { [] }
    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] { [] }
    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem] { [] }
    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] { [] }
    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? { nil }
    func symbolPaletteSources(for _: IDEWorkspace) -> [any SearchEverywhereProvider] { [] }
    func loadDiagram(
        _: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace _: IDEWorkspace
    ) async -> IDEDiagramLoad? { nil }
}

/// The language modules of the app, in the order their pages and entries appear. The shipped ones are
/// listed here; ``register(_:)`` adds another (a test, or a language compiled into the app) and
/// ``unregister(id:)`` takes it out. Registration is compile-time and main-actor only: a window made
/// after it sees the module, and a window already open does not rebuild what it built.
@MainActor
enum IDELanguageModules {
    static let shipped: [any IDELanguageModule] = [
        IDEJavaModule(), IDEHTTPModule(), IDEMarkdownModule(), IDEJSONModule(), IDECSVModule(),
        IDETypeScriptModule()
    ]

    private(set) static var all: [any IDELanguageModule] = shipped

    /// Adds `module` after the others. A module with the same id replaces the earlier one.
    static func register(_ module: any IDELanguageModule) {
        all.removeAll { $0.id == module.id }
        all.append(module)
    }

    static func unregister(id: String) {
        all.removeAll { $0.id == id }
    }

    static func module(id: String) -> (any IDELanguageModule)? {
        all.first { $0.id == id }
    }

    static var preferencePanes: [IDEPreferencesPane] {
        all.flatMap(\.preferencePanes)
    }
}

extension IDEWorkspace {
    /// Every module's palette commands.
    func languageModuleCommands() -> [EditorCommand] {
        IDELanguageModules.all.flatMap { $0.commands(for: self) }
    }

    /// Every module's tool-window entries that are available now, and those of every active project system.
    func languageModuleToolWindows() -> [IDEToolWindow] {
        IDELanguageModules.all.flatMap { $0.toolWindows(for: self) }
            + projectSystems.systems.filter(\.isActive).flatMap { $0.toolWindows(for: self) }
    }

    /// Every module's and the active project system's toolbar buttons, plus Run, Debug and Stop,
    /// in their order. Those three follow the active file's run provider, so they are not a
    /// language module's. Their ids stay `java.run`, `java.debug` and `java.stop`.
    func toolbarItems() -> [IDEToolbarItem] {
        (IDELanguageModules.all.flatMap { $0.toolbarItems(for: self) }
            + projectSystems.systems.filter(\.isActive).flatMap { $0.toolbarItems(for: self) }
            + runToolbarItems())
            .sorted { $0.order < $1.order }
    }

    /// Run, Debug and Stop for whatever language is in front. Hidden when that file cannot run,
    /// except Stop, which stays while a run is going.
    private func runToolbarItems() -> [IDEToolbarItem] {
        typealias Order = IDEToolbarItem.Order
        let canRun = runFileCanRun
        let running = isRunActive
        guard canRun || running else { return [] }
        var items: [IDEToolbarItem] = []
        if canRun {
            items.append(.button(
                id: "java.run", order: Order.run, systemImage: "play.fill", help: runHelp,
                tint: IDEAppearance.ColorToken.run, action: { [weak self] in self?.runActiveFile() }
            ))
            let canDebug = runFileCanDebug
            items.append(.button(
                id: "java.debug", order: Order.debug, systemImage: "ladybug.fill", help: debugHelp,
                tint: canDebug ? IDEAppearance.ColorToken.run : nil, isEnabled: canDebug,
                action: { [weak self] in self?.debugActiveFile() }
            ))
        }
        items.append(.button(
            id: "java.stop", order: Order.stop, systemImage: "stop.fill", help: "Stop",
            tint: running ? IDEAppearance.ColorToken.error : nil, isEnabled: running,
            action: { [weak self] in self?.stopRunning() }
        ))
        return items
    }

    /// Every module's status-bar items for `placement`, in their order.
    func statusItems(_ placement: IDEStatusItem.Placement) -> [IDEStatusItem] {
        IDELanguageModules.all.flatMap { $0.statusItems(for: self) }
            .filter { $0.placement == placement }
            .sorted { $0.order < $1.order }
    }

    /// Every module's View menu items.
    func viewMenuContributions() -> [IDEViewMenuContribution] {
        IDELanguageModules.all.flatMap { $0.viewMenuItems(for: self) }
    }

    /// The menu `module` shows now, or nil.
    func languageModuleMenu(for module: String) -> IDEModuleMenu? {
        IDELanguageModules.module(id: module)?.menu(for: self)
    }
}
