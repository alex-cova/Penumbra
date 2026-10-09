import Penumbra
import SwiftUI

/// A tab of the left sidebar. The sidebar shows one at a time, in a single card, instead of a card
/// per tool window.
///
/// A value, not a closed list: its raw value is the string saved in sessions (`"explorer"`,
/// `"breakpoints"`), so existing sessions decode unchanged, and an id no module provides any more
/// is simply never offered. What a tab looks like and shows is its ``IDESidebarTabDescriptor``.
struct IDESidebarTab: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let explorer = IDESidebarTab(rawValue: "explorer")
    static let structure = IDESidebarTab(rawValue: "structure")
    static let changes = IDESidebarTab(rawValue: "changes")
    static let history = IDESidebarTab(rawValue: "history")

    /// The Explorer is the sidebar's home: it stays when the others are closed.
    var isClosable: Bool { self != .explorer }
}

/// How a sidebar tab looks and what it shows. The built-in tabs' are in ``IDESidebarTabs``; a
/// language module adds its own (``IDELanguageModule/sidebarTabs``).
struct IDESidebarTabDescriptor {
    let tab: IDESidebarTab
    let title: String
    /// SF Symbol.
    let systemImage: String
    /// Where the tab sits in the tab bar and the tool-window stripe, lowest first.
    let order: Int
    var iconSize: CGFloat = 11
    /// Overrides the usual muted/foreground icon color (the breakpoint dot is always red).
    var iconColor: Color?
    /// The shortcut shown beside the stripe entry, and its tint.
    var shortcut: String?
    var tint: PaletteIcon.Tint = .secondary
    /// Whether the tab is offered now; an unavailable tab is hidden and cannot be shown.
    var isAvailable: @MainActor (IDEWorkspace) -> Bool = { _ in true }
    var badge: @MainActor (IDEWorkspace) -> Int = { _ in 0 }
    /// Runs when the tab is brought to the front.
    var onShow: @MainActor (IDEWorkspace) -> Void = { _ in }
    let content: @MainActor (IDEWorkspace) -> AnyView
}

/// The sidebar's tabs, built-in and from the language modules, in tab-bar order.
@MainActor
enum IDESidebarTabs {
    /// The positions the tabs have always had: Explorer, Structure, Changes, Breakpoints, History.
    enum Order {
        static let explorer = 0
        static let structure = 10
        static let changes = 20
        static let breakpoints = 30
        static let history = 40
    }

    static var builtIn: [IDESidebarTabDescriptor] {
        [
            IDESidebarTabDescriptor(
                tab: .explorer, title: "Explorer", systemImage: "folder", order: Order.explorer,
                shortcut: "⌘0", tint: .blue,
                // The Explorer stays mounted by the sidebar itself, so its filter, scroll position
                // and pending reveals survive a visit to another tab.
                content: { _ in AnyView(EmptyView()) }
            ),
            IDESidebarTabDescriptor(
                tab: .structure, title: "Structure", systemImage: "list.bullet.indent", order: Order.structure,
                shortcut: "⌘7", onShow: { $0.refreshStructure() },
                content: { _ in AnyView(IDEStructurePanel()) }
            ),
            IDESidebarTabDescriptor(
                tab: .changes, title: "Changes", systemImage: "arrow.triangle.branch", order: Order.changes,
                shortcut: "⌃⌘G", tint: .green,
                isAvailable: { $0.showsSourceControlTab },
                badge: { $0.gitStatus.changes.count },
                onShow: { $0.gitStatus.refresh() },
                content: { AnyView(IDEChangesPanel(gitStatus: $0.gitStatus)) }
            ),
            IDESidebarTabDescriptor(
                tab: .history, title: "History", systemImage: "clock.arrow.circlepath", order: Order.history,
                tint: .orange, content: { _ in AnyView(IDELocalHistoryPanel()) }
            )
        ]
    }

    /// Every tab, built-in and contributed, in order.
    static var all: [IDESidebarTabDescriptor] {
        (builtIn + IDELanguageModules.all.flatMap(\.sidebarTabs)).sorted { $0.order < $1.order }
    }

    static func descriptor(for tab: IDESidebarTab) -> IDESidebarTabDescriptor? {
        all.first { $0.tab == tab }
    }
}

extension IDESidebarTab {
    @MainActor var title: String {
        IDESidebarTabs.descriptor(for: self)?.title ?? rawValue.capitalized
    }

    @MainActor var systemImage: String {
        IDESidebarTabs.descriptor(for: self)?.systemImage ?? "questionmark.square"
    }
}
