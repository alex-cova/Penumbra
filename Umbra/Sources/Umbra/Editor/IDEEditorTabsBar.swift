import SwiftUI

struct IDEEditorTabsBar: View {
    /// The panes' shared space, in which pane frames and tab-drag points live.
    nonisolated static let panesSpace = "UmbraEditorPanes"

    let paneID: UUID
    @Environment(IDEWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tabs: [IDETabRow] {
        workspace.tabsByPane[paneID] ?? []
    }

    private var isActivePane: Bool {
        workspace.activePaneID == paneID
    }

    /// Fixed regardless of dirty/hover state, so the tab itself never resizes as the pointer
    /// crosses it — only what's drawn inside this slot changes.
    nonisolated static let trailingSlotSide: CGFloat = 14
    private var trailingSlotSide: CGFloat { Self.trailingSlotSide }

    private var session: IDETabDragSession { workspace.tabDrag }

    @State private var barWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat = 0
    /// Where the bar starts in the panes' space, which a drag is measured in.
    @State private var barOrigin: CGPoint = .zero
    @State private var tabWidths: [UUID: CGFloat] = [:]
    /// What the tabs measure (they are all alike), for the floating copy to be the same size and
    /// sit the same way: the height, and how far down in the panes' space the tabs start.
    @State private var tabHeight: CGFloat = IDEAppearance.Spacing.tabHeight
    @State private var tabTop: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(idType: Never.self)
    @State private var edgeFades = IDEEdgeFades()

    private static let spacing = IDEAppearance.Spacing.xs
    private static let inset = IDEAppearance.Spacing.sm
    private static let reorderAnimation = Animation.snappy(duration: 0.2)
    /// How far in from an end of the row the row fades out.
    private static let fadeWidth: CGFloat = 20

    private var selectedTabID: UUID? {
        tabs.first(where: \.isSelected)?.id
    }

    /// The strip is wider than the pane. Measured against the whole bar, not the scroll view, so
    /// showing the overflow menu cannot change the answer.
    private var isOverflowing: Bool {
        tabsWidth > barWidth + 1
    }

    private var layout: IDETabBarLayout {
        IDETabBarLayout(
            tabs: tabs.map(\.id), widths: tabWidths, spacing: Self.spacing, inset: Self.inset,
            barWidth: barWidth, scrollOffset: scrollOffset
        )
    }

    /// The pointer is over this bar's tabs with a tab to put among them: it opens a gap there.
    private var dropIndex: Int? {
        guard let target = session.target, target.paneID == paneID, target.edge == nil else { return nil }
        return target.index
    }

    /// How far each tab sits from its place while a tab is dragged: the tab being dragged leaves
    /// its slot, and the slot it would drop into opens. The tab keeps its own slot while the pointer
    /// is nowhere it could land (it goes back there on release).
    private var gapOffsets: [UUID: CGFloat] {
        guard let dragged = session.tab, let ghost = session.ghost else { return [:] }
        let isSource = session.sourcePaneID == paneID
        var index = dropIndex
        if isSource, session.target == nil { index = tabs.firstIndex { $0.id == dragged } }
        guard isSource || index != nil else { return [:] }
        return layout.gapOffsets(excluding: isSource ? dragged : nil, insertingAt: index, gapWidth: ghost.width)
    }

    /// The row scrolls under a dragged tab held near this bar's ends.
    private var autoscrollKey: UUID? {
        dropIndex == nil ? nil : session.tab
    }

    var body: some View {
        let offsets = gapOffsets
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                        ForEach(tabs) { tab in
                            let offset = offsets[tab.id] ?? 0
                            let isDragged = session.tab == tab.id
                            IDEChromeTabItem(
                                title: tab.title,
                                isSelected: tab.isSelected,
                                isDimmed: !isActivePane,
                                onSelect: { workspace.selectTab(tab.id, in: paneID) },
                                leading: {
                                    Image(systemName: tab.symbolName ?? IDEFileIcon.systemName(forFilename: tab.title))
                                        .font(.system(size: IDEAppearance.IconSize.smallGlyph))
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                },
                                trailing: {
                                    IDEEditorTabCloseButton(
                                        isDirty: tab.isDirty && workspace.preferences.markModifiedTabs,
                                        side: trailingSlotSide,
                                        onClose: { workspace.requestCloseTab(tab.id, in: paneID) }
                                    )
                                }
                            )
                            // The floating copy stands in for it while it is dragged.
                            .opacity(isDragged ? 0 : 1)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                                tabWidths[tab.id] = $0.width
                                if tabHeight != $0.height { tabHeight = $0.height }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.panesSpace)).minY } action: { tabTop = $0 }
                            // Room the row scrolls into view with the tab, clear of
                            // the faded ends; spacing and padding take it back out.
                            .padding(.horizontal, Self.fadeWidth)
                            .offset(x: offset)
                            .animation(reduceMotion ? nil : Self.reorderAnimation, value: offset)
                            .id(tab.id)
                            .contextMenu { tabMenu(for: tab) }
                        }
                    }
                    .padding(.horizontal, Self.inset - Self.fadeWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                    scrollOffset = offset
                }
                .onScrollGeometryChange(for: IDEEdgeFades.self) { geometry in
                    let offset = geometry.contentOffset.x
                    let hiddenAfter = geometry.contentSize.width - geometry.containerSize.width - offset
                    return IDEEdgeFades(leading: offset, trailing: hiddenAfter, over: Self.fadeWidth)
                } action: { _, fades in
                    edgeFades = fades
                }
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Self.panesSpace)).origin } action: { barOrigin = $0 }
                // A tab scrolled part of the way out fades rather than ending in a cut.
                .mask { fadeMask }
                .background(IDEWheelScrollsSideways())
                .background(
                    IDEMiddleClickClosesTab(tab: tab(at:)) { id in
                        workspace.requestCloseTab(id, in: paneID)
                    }
                )
                .background(
                    IDETabDragTracker(
                        tab: dragCandidate(at:),
                        geometry: IDETabBarGeometry(layout: layout, origin: barOrigin),
                        publish: publishGeometry,
                        begin: { id, grab, point in beginDrag(id, grab: grab, at: point) },
                        move: { workspace.updateTabDrag(to: $0) },
                        drop: { workspace.dropDraggedTab() },
                        cancel: { workspace.cancelTabDrag() }
                    )
                )
                // A tab chosen from the menu, a keyboard shortcut or a file opened elsewhere must
                // not stay out of sight.
                .onChange(of: selectedTabID) { _, id in
                    guard let id else { return }
                    IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { proxy.scrollTo(id) }
                }
                .onAppear {
                    if let id = selectedTabID { proxy.scrollTo(id) }
                }
                .onChange(of: tabs.map(\.id)) { _, ids in
                    tabWidths = tabWidths.filter { ids.contains($0.key) }
                }
                .onDisappear {
                    if session.sourcePaneID == paneID { workspace.cancelTabDrag() }
                }
                // A pointer resting near an end sends no events, so a timer keeps
                // the row scrolling under it for as long as the drag lasts.
                .task(id: autoscrollKey) {
                    guard autoscrollKey != nil else { return }
                    var last = Date.now
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(16))
                        let now = Date.now
                        autoscroll(elapsed: now.timeIntervalSince(last))
                        last = now
                    }
                }
            }

            if isOverflowing {
                overflowMenu
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.tabBar)
        .focusable(false)
    }

    /// Opaque across the bar, clearing towards an end with tabs scrolled out past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - edgeFades.leading), .black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(1 - edgeFades.trailing)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
        }
    }

    /// The tab a press at a horizontal position in the bar picks up, and where it starts. Not the
    /// ×: a press there that wanders a few points is still a click on it.
    private func dragCandidate(at x: CGFloat) -> (id: UUID, minX: CGFloat)? {
        guard let id = layout.tab(at: x), let minX = layout.minX(of: id), let width = tabWidths[id],
              x < minX + width - trailingSlotSide - IDEAppearance.Spacing.cozy else { return nil }
        return (id, minX)
    }

    /// Where the tabs are is what a drag finds its slot in, so the workspace keeps it.
    private func publishGeometry(_ geometry: IDETabBarGeometry) {
        workspace.tabBarGeometry[paneID] = geometry
        // A row that scrolled or changed width under a still pointer has a new slot under it.
        if workspace.tabDrag.isActive {
            DispatchQueue.main.async { workspace.retargetTabDrag() }
        }
    }

    private func beginDrag(_ id: UUID, grab: CGPoint, at point: CGPoint) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // The row is centred in the bar, so a tab's top is measured from the pane's, which is where
        // the bar starts; the pointer's hold on it from the row, which is where the press was read.
        let paneTop = workspace.editorPaneFrames[paneID]?.minY ?? barOrigin.y
        let ghost = IDETabDragSession.Ghost(
            title: tab.title,
            symbolName: tab.symbolName ?? IDEFileIcon.systemName(forFilename: tab.title),
            isDirty: tab.isDirty && workspace.preferences.markModifiedTabs,
            width: tabWidths[id] ?? 0,
            height: tabHeight,
            top: tabTop - paneTop
        )
        let grabOffset = CGPoint(x: grab.x, y: grab.y - (tabTop - barOrigin.y))
        workspace.beginTabDrag(id, in: paneID, ghost: ghost, grabOffset: grabOffset, at: point)
    }

    private func autoscroll(elapsed: TimeInterval) {
        let pointerX = session.location.x - barOrigin.x
        guard let target = layout.autoscrollOffset(pointerX: pointerX, elapsed: elapsed) else { return }
        scrollPosition.scrollTo(x: target)
        scrollOffset = target
    }

    /// The tab at a horizontal position in the bar, if there's one.
    private func tab(at x: CGFloat) -> UUID? {
        session.isActive ? nil : layout.tab(at: x)
    }

    /// Every tab of the pane in one list, for the ones scrolled out of view.
    private var overflowMenu: some View {
        IDEIconMenu(systemImage: "chevron.down", help: "Show All Tabs") {
            ForEach(tabs) { tab in
                Button {
                    workspace.selectTab(tab.id, in: paneID)
                } label: {
                    let title = tab.isDirty && workspace.preferences.markModifiedTabs ? "\(tab.title) •" : tab.title
                    if tab.isSelected {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        }
        .padding(.trailing, IDEAppearance.Spacing.xs)
    }

    @ViewBuilder
    private func tabMenu(for tab: IDETabRow) -> some View {
        Button("Split Editor Right") { workspace.splitRight(in: paneID) }
        Button("Split Editor Down") { workspace.splitDown(in: paneID) }
        Divider()
        Button("Rename File…") { workspace.renameTab(tab.id, in: paneID) }
        if let document = workspace.workbench.panes.flatMap(\.documents).first(where: { $0.id == tab.id }),
           let url = document.url {
            if document.contentKind == .text {
                Button("Reload from Disk") { workspace.reloadTabFromDisk(tab.id, in: paneID) }
                Button("Reopen as Hex") { workspace.reopenDocumentAsHex(tab.id) }
            }
            if document.contentKind == .binary {
                Button("Reload from Disk") { workspace.reloadTabFromDisk(tab.id, in: paneID) }
                Button("Reopen as Text") { workspace.reopenDocumentAsText(tab.id) }
            }
            Button("Show History") { workspace.showLocalHistory(for: url) }
        }
        Divider()
        Button("Close") { workspace.requestCloseTab(tab.id, in: paneID) }
        Button("Close Other Tabs") { workspace.requestCloseOtherTabs(tab.id, in: paneID) }
            .disabled(!hasOtherTabs)
        Button("Close Tabs to the Right") { workspace.requestCloseTabsToRight(tab.id, in: paneID) }
            .disabled(!hasTabsToRight(tab))
        Button("Close All") { workspace.requestCloseAllTabs(in: paneID) }
        Divider()
        Button("Unsplit") { workspace.unsplit(from: paneID) }
            .disabled(!hasMultiplePanes)
    }

    private var hasOtherTabs: Bool {
        tabs.count > 1
    }

    private func hasTabsToRight(_ tab: IDETabRow) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return index < tabs.count - 1
    }

    private var hasMultiplePanes: Bool {
        workspace.tabsByPane.count > 1
    }
}

/// Always shows a close button. A dirty tab shows its dot in the slot until the pointer is over
/// it; then the × takes the slot and the dot moves to its corner, so "unsaved" never disappears.
private struct IDEEditorTabCloseButton: View {
    let isDirty: Bool
    let side: CGFloat
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClose) {
            ZStack {
                if isDirty && !isHovering {
                    dot
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: IDEAppearance.IconSize.closeGlyph, weight: .bold))
                        .foregroundStyle(isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                if isDirty && isHovering {
                    dot.offset(x: IDEAppearance.Spacing.xxs, y: -IDEAppearance.Spacing.xxs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isDirty ? "Close (unsaved changes)" : "Close")
        .accessibilityLabel(isDirty ? "Close Tab (Edited)" : "Close Tab")
        .accessibilityAddTraits(.isButton)
    }

    private var dot: some View {
        Circle()
            .fill(IDEAppearance.ColorToken.accent)
            .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
    }
}

#Preview {
    IDEEditorTabsBar(paneID: UUID())
        .environment({
            let workspace = IDEWorkspace()
            let paneID = UUID()
            workspace.tabsByPane = [
                paneID: [
                    IDETabRow(id: UUID(), title: "sample.js", isDirty: true, isSelected: true),
                    IDETabRow(id: UUID(), title: "README.md", isDirty: false, isSelected: false)
                ]
            ]
            return workspace
        }())
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
