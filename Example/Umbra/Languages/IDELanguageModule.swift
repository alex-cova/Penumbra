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

/// What a language adds to Umbra's chrome, beside the intelligence its `LanguageService` provides:
/// palette commands, a menu-bar menu, Settings pages and tool-window stripe entries. See
/// `docs/LANGUAGE_SUPPORT_PLAN.md`.
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
}

extension IDELanguageModule {
    func commands(for workspace: IDEWorkspace) -> [EditorCommand] { [] }
    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] { [] }
    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] { [] }
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? { nil }
    var preferencePanes: [IDEPreferencesPane] { [] }
    var sidebarTabs: [IDESidebarTabDescriptor] { [] }
}

/// The modules Umbra ships, in the order their pages and entries appear.
@MainActor
enum IDELanguageModules {
    static let all: [any IDELanguageModule] = [IDEJavaModule(), IDEHTTPModule()]

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

    /// Every module's tool-window entries that are available now.
    func languageModuleToolWindows() -> [IDEToolWindow] {
        IDELanguageModules.all.flatMap { $0.toolWindows(for: self) }
    }

    /// The menu `module` shows now, or nil.
    func languageModuleMenu(for module: String) -> IDEModuleMenu? {
        IDELanguageModules.module(id: module)?.menu(for: self)
    }
}
