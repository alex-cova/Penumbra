import SwiftUI

/// The tab showing in the bottom panel. A value, not a closed list: a language module adds its own
/// (``IDEBottomTabContribution``). The ids are the names these tabs have always had, which tool
/// windows and the palette use too (`"\(tab)"` prints the id).
struct IDEBottomPanelTab: Hashable, CustomStringConvertible {
    let id: String

    init(_ id: String) {
        self.id = id
    }

    var description: String { id }

    /// A shell -- which one is `IDEWorkspace.selectedTerminalTabID`.
    static let terminal = IDEBottomPanelTab("terminal")
    static let sourceControl = IDEBottomPanelTab("sourceControl")
    static let problems = IDEBottomPanelTab("problems")
    /// The results of the last Find Usages.
    static let usages = IDEBottomPanelTab("usages")
}

/// A tab a language module puts in the bottom panel: its place in the strip, the strip item, and the
/// panel shown while it is selected. A module returns one only while the tab is available.
///
/// The panel stays mounted while another tab is selected (it is hidden, not removed), as the
/// built-in ones always have, so a log keeps its scroll position and a tree its expansion.
struct IDEBottomTabContribution {
    let tab: IDEBottomPanelTab
    /// Where the item sits in the strip among the built-in tabs and the others, lowest first.
    let order: Int
    /// The strip item. Built with the workspace so it reads its own selection and status.
    let item: @MainActor (IDEWorkspace) -> AnyView
    /// The panel.
    let content: @MainActor (IDEWorkspace) -> AnyView
    /// The controls at the right end of the panel's header while this tab is selected (Cancel, Copy,
    /// elapsed time). Without them the header shows the shell's Restart button.
    var controls: (@MainActor (IDEWorkspace) -> AnyView)?
    /// When the last shell is closed, the panel stays on this tab instead of hiding (a console the
    /// user may still want to read).
    var staysWhenLastShellCloses = false
}

extension IDEBottomPanelTab {
    /// The positions of the strip items in the order they have always had. Terminal shells come
    /// first and have no number; the rest are sparse so a module can add one between two.
    enum Order {
        static let run = 10
        static let gradle = 20
        static let http = 30
        static let problems = 40
        static let typeHierarchy = 50
        static let usages = 60
        static let testResults = 70
        static let debug = 80
        static let callHierarchy = 90
        static let sourceControl = 100
    }
}

extension IDEWorkspace {
    /// Every module's bottom tabs that are available now, and those of the active project system
    /// (the Gradle console).
    func languageModuleBottomTabs() -> [IDEBottomTabContribution] {
        IDELanguageModules.all.flatMap { $0.bottomTabs(for: self) }
            + projectSystems.systems.filter(\.isActive).flatMap { $0.bottomTabs(for: self) }
    }
}
