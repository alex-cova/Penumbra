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
    private let trailingSlotSide: CGFloat = 14

    @State private var barWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat = 0
    /// Where the bar starts in the panes' space, which a drag is measured in.
    @State private var barOrigin: CGFloat = 0
    /// The tab being dragged, and how far the pointer has carried it.
    @State private var drag: IDETabDrag?
    /// True while a tab drag gesture is live; a cancelled gesture resets it
    /// without calling `onEnded`, which is how a cancel is seen.
    @GestureState private var isDraggingTab = false
    @State private var tabWidths: [UUID: CGFloat] = [:]
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

    var body: some View {
        let offsets = drag?.reorder(in: layout)?.offsets ?? [:]
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                        ForEach(tabs) { tab in
                            let offset = offsets[tab.id] ?? 0
                            let isDragged = drag?.tab == tab.id
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
                            .opacity(isDragged && workspace.tabDropPaneID != nil ? 0.4 : 1)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[tab.id] = $0 }
                            // Room the row scrolls into view with the tab, clear of
                            // the faded ends; spacing and padding take it back out.
                            .padding(.horizontal, Self.fadeWidth)
                            .offset(x: offset)
                            .zIndex(isDragged ? 1 : 0)
                            .animation(isDragged || reduceMotion ? nil : Self.reorderAnimation, value: offset)
                            .gesture(tabDragGesture(for: tab.id, proxy: proxy))
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
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.panesSpace)).minX } action: { barOrigin = $0 }
                // A tab scrolled part of the way out fades rather than ending in a cut.
                .mask { fadeMask }
                .background(IDEWheelScrollsSideways())
                .background(
                    IDEMiddleClickClosesTab(tab: tab(at:)) { id in
                        workspace.requestCloseTab(id, in: paneID)
                    }
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
                    if let drag, !ids.contains(drag.tab) { endDrag() }
                }
                .onDisappear {
                    if drag != nil { workspace.tabDropPaneID = nil }
                }
                // A cancelled drag (Esc) resets the gesture state without a drop:
                // the tabs settle back and no order changes.
                .onChange(of: isDraggingTab) { _, isDragging in
                    if !isDragging, let drag {
                        handleDrag(.cancelled, at: .zero, of: drag.tab, proxy: proxy)
                    }
                }
                // A pointer resting near an end sends no events, so a timer keeps
                // the row scrolling under it for as long as the drag lasts.
                .task(id: drag?.tab) {
                    guard drag != nil else { return }
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

    private func tabDragGesture(for id: UUID, proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.panesSpace))
            .updating($isDraggingTab) { _, state, _ in state = true }
            .onChanged { value in
                handleDrag(.moved(translation: value.translation.width, location: value.location.x), at: value.location, of: id, proxy: proxy)
            }
            .onEnded { value in
                handleDrag(.dropped(translation: value.translation.width), at: value.location, of: id, proxy: proxy)
            }
    }

    private func endDrag() {
        drag = nil
        if workspace.tabDropPaneID != nil { workspace.tabDropPaneID = nil }
    }

    private func handleDrag(_ event: IDETabDragEvent, at point: CGPoint, of id: UUID, proxy: ScrollViewProxy) {
        switch event {
        case .moved(let translation, let location):
            let barLocation = location - barOrigin
            let target = workspace.editorPane(at: point).flatMap { $0 == paneID ? nil : $0 }
            if workspace.tabDropPaneID != target { workspace.tabDropPaneID = target }
            if let drag, drag.tab == id {
                self.drag = IDETabDrag(tab: id, translation: translation, location: barLocation, startScrollOffset: drag.startScrollOffset)
            } else {
                workspace.selectTab(id, in: paneID)
                drag = IDETabDrag(tab: id, translation: translation, location: barLocation, startScrollOffset: scrollOffset)
            }
        case .dropped(let translation):
            guard var dropped = drag, dropped.tab == id else { return }
            if let target = workspace.tabDropPaneID {
                endDrag()
                workspace.moveTab(id, from: paneID, toPane: target)
                return
            }
            dropped.translation = translation
            let destination = dropped.reorder(in: layout)?.destination
            withAnimation(reduceMotion ? nil : Self.reorderAnimation) {
                if let destination { workspace.reorderTab(id, in: paneID, to: destination) }
                drag = nil
            }
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? nil : Self.reorderAnimation) { proxy.scrollTo(id) }
            }
        case .cancelled:
            if drag?.tab == id {
                withAnimation(reduceMotion ? nil : Self.reorderAnimation) { endDrag() }
            }
        }
    }

    private func autoscroll(elapsed: TimeInterval) {
        guard let target = drag?.autoscrollOffset(in: layout, elapsed: elapsed) else { return }
        scrollPosition.scrollTo(x: target)
        scrollOffset = target
    }

    /// The tab at a horizontal position in the bar, if there's one.
    private func tab(at x: CGFloat) -> UUID? {
        drag == nil ? layout.tab(at: x) : nil
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
