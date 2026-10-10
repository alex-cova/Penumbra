import Penumbra

/// One tool window as the stripe and the Recent Files (⌘E) sidebar both show it. Built fresh from
/// the workspace's state, so only the tool windows available right now are listed.
struct IDEToolWindow: Identifiable {
    enum Placement {
        case leadingTop
        case leadingBottom
        case trailingTop
        case trailingBottom
    }

    let id: String
    let systemImage: String
    let title: String
    /// Menu shortcut, shown beside the Recent Files sidebar row.
    let shortcut: String?
    let tint: PaletteIcon.Tint
    let placement: Placement
    let isOpen: Bool
    let toggle: () -> Void
    /// Where it sits in the list the stripe and Recent Files show, lowest first. A module's windows
    /// slot in among the built-in ones by this number (see ``Order``).
    var order = 0

    /// The positions of the windows in the order the stripe has always shown them. Sparse, so a
    /// module can add one between two others.
    enum Order {
        static let sidebarTabs = 100
        static let findInFiles = 200
        static let history = 300
        static let debug = 310
        static let testResults = 320
        static let usages = 330
        static let typeHierarchy = 340
        static let callHierarchy = 350
        static let problems = 360
        static let terminal = 370
        static let gradleSidebar = 400
        static let gradleConsole = 410
        static let npmConsole = 415
        static let httpResponse = 420
    }
}

extension IDEWorkspace {
    /// Whether the leading stripe shows at all: it stays hidden until a folder or a file is open.
    var showsLeadingToolWindows: Bool { hasOpenProject || hasOpenDocuments }

    /// Available tool windows in stripe order (leading top, leading bottom, trailing): the built-in
    /// ones and the language modules', merged by ``IDEToolWindow/order``.
    var toolWindows: [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if showsLeadingToolWindows {
            for (index, tab) in sidebarTabs.enumerated() {
                windows.append(sidebarToolWindow(tab, order: IDEToolWindow.Order.sidebarTabs + index))
            }
            windows.append(IDEToolWindow(
                id: "find", systemImage: "magnifyingglass", title: "Find in Files", shortcut: "⌘⇧F",
                tint: .secondary, placement: .leadingTop, isOpen: isFindInFilesVisible, toggle: toggleFindInFiles,
                order: IDEToolWindow.Order.findInFiles
            ))
            if showsSourceControlTab {
                windows.append(bottomToolWindow(
                    .sourceControl, "clock.arrow.circlepath", "History", nil, .green, .leadingBottom,
                    order: IDEToolWindow.Order.history
                ))
            }
            if showsUsagesTab {
                windows.append(bottomToolWindow(
                    .usages, "text.magnifyingglass", "Usages", nil, .secondary, .leadingBottom,
                    order: IDEToolWindow.Order.usages
                ))
            }
            windows.append(bottomToolWindow(
                .problems, "exclamationmark.triangle", "Problems", "⌘⇧M", .orange, .leadingBottom,
                order: IDEToolWindow.Order.problems
            ))
            windows.append(bottomToolWindow(
                .terminal, "terminal", "Terminal", "⌃`", .secondary, .leadingBottom, order: IDEToolWindow.Order.terminal
            ))
        }
        windows.append(contentsOf: languageModuleToolWindows())
        return windows.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    /// Opens (`true`) or hides (`false`) a tool window; no-op when it is already in that state or
    /// no longer available. Unlike the stripe buttons, choosing an open tool window keeps it open.
    func setToolWindow(_ id: String, open: Bool) {
        guard let window = toolWindows.first(where: { $0.id == id }), window.isOpen != open else { return }
        window.toggle()
    }

    /// The sidebar's tabs are tool windows too: open while the sidebar is showing that tab.
    private func sidebarToolWindow(_ tab: IDESidebarTab, order: Int) -> IDEToolWindow {
        let descriptor = IDESidebarTabs.descriptor(for: tab)
        return IDEToolWindow(
            id: tab == .explorer ? "explorer" : tab.rawValue, systemImage: tab.systemImage, title: tab.title,
            shortcut: descriptor?.shortcut, tint: descriptor?.tint ?? .secondary, placement: .leadingTop,
            isOpen: showsSidebar && activeSidebarTab == tab,
            toggle: { [weak self] in self?.toggleSidebarTab(tab) },
            order: order
        )
    }

    /// A stripe entry that toggles bottom-panel tab `tab`. Also how a language module adds its tabs.
    func bottomToolWindow(
        _ tab: IDEBottomPanelTab,
        _ systemImage: String,
        _ title: String,
        _ shortcut: String?,
        _ tint: PaletteIcon.Tint,
        _ placement: IDEToolWindow.Placement,
        order: Int
    ) -> IDEToolWindow {
        IDEToolWindow(
            id: "\(tab)", systemImage: systemImage, title: title, shortcut: shortcut, tint: tint,
            placement: placement, isOpen: isBottomToolWindowOpen(tab),
            toggle: { [weak self] in self?.toggleBottomToolWindow(tab) },
            order: order
        )
    }
}
