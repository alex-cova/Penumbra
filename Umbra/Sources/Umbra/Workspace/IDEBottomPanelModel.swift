import Foundation
import Observation
import Penumbra

/// How much of the editor column the bottom panel takes when it is not covering the editor.
enum IDEBottomPanelSize: CaseIterable {
    case half, third, quarter

    var fraction: Double {
        switch self {
        case .half: return 1.0 / 2
        case .third: return 1.0 / 3
        case .quarter: return 1.0 / 4
        }
    }

    var title: String {
        switch self {
        case .half: return "Half"
        case .third: return "Third"
        case .quarter: return "Quarter"
        }
    }
}

/// The bottom panel of one window: whether it shows, how tall it is, which tab is selected, and the
/// shell tabs (including the read-only tabs that display an agent's command). Reacting to a change
/// (saving the session, moving the keyboard, choosing what to show when the last shell closes) is the
/// window's job; this holds the state and the tab-list rules, which need no window to test.
@MainActor
@Observable
final class IDEBottomPanelModel {
    var isVisible = false
    /// The panel covers the whole editor area instead of sitting under it. The editor stays mounted
    /// underneath, so its layout and scroll positions are untouched. Not persisted.
    var isExpanded = false
    var height = IDEAppearance.Spacing.terminalDefaultHeight
    /// The size preset `height` follows as the window is resized; dragging the panel's edge clears it.
    /// Not persisted: the resulting `height` is.
    var sizePreset: IDEBottomPanelSize?
    /// How the shell tabs are arranged: the leaves are the tabs showing, the others wait in the tab
    /// bar. The selected tab is the focused pane. Not persisted.
    private(set) var tiling = IDETerminalTiling()
    /// A pane filling the panel while the others wait. Not persisted.
    private(set) var zoomedTabID: UUID?
    /// The tab being dragged out of the tab bar or a pane header, while a drag is under way.
    var draggedTabID: UUID?
    /// Height of the editor column the panel sits in, reported by the root view.
    @ObservationIgnored private var availableHeight = 0.0
    var focusRequestID: UInt64 = 0
    var tabs: [IDETerminalTab] = []
    var selectedTabID: UUID?
    /// Which tab the panel is showing. Not persisted in the session: each launch starts on a shell
    /// (or no terminal at all).
    var selectedTab: IDEBottomPanelTab = .terminal

    /// Agent command id → the terminal tab displaying it. Not saved.
    @ObservationIgnored private var agentCommandTabs: [UUID: UUID] = [:]
    /// Output a command tab's view has not fed yet, keyed by tab id.
    @ObservationIgnored private var agentCommandFeed: [UUID: String] = [:]
    /// Commands whose tab should ignore anything further, including a tab the user closed.
    @ObservationIgnored private var finishedAgentCommands: Set<UUID> = []

    /// True when a terminal tab (rather than one of the read-only tabs) is showing.
    var isShellSelected: Bool { selectedTab == .terminal }

    func requestFocus() {
        focusRequestID += 1
    }

    // MARK: Layout

    /// Applies `preset` as a fraction of the editor column, leaving fullscreen.
    func applySize(_ preset: IDEBottomPanelSize) {
        sizePreset = preset
        isExpanded = false
        resolveSizePreset()
    }

    /// The editor column changed height; a preset follows it.
    func columnHeightChanged(_ available: Double) {
        availableHeight = available
        resolveSizePreset()
    }

    private func resolveSizePreset() {
        guard let sizePreset, availableHeight > 0 else { return }
        let resolved = max((availableHeight * sizePreset.fraction).rounded(), IDEAppearance.Spacing.terminalMinHeight)
        if height != resolved { height = resolved }
    }

    // MARK: Tiling

    /// The panes showing now. A selected tab the tiling does not hold shows alone.
    var layout: IDETerminalTiling {
        guard isShellSelected, let selectedTabID else { return IDETerminalTiling() }
        if let zoomedTabID, tiling.contains(zoomedTabID) { return .single(zoomedTabID) }
        return tiling.contains(selectedTabID) ? tiling : .single(selectedTabID)
    }

    /// The shell tabs showing now, in reading order. Empty while another bottom tab is selected.
    var visibleTabIDs: [UUID] { layout.paneIDs }

    /// Shows `id` in the focused pane's place, or focuses its pane when it already shows.
    private func show(_ id: UUID) {
        if !tiling.contains(id) {
            if let current = selectedTabID, tiling.contains(current) {
                tiling.replace(current, with: id)
                if zoomedTabID == current { zoomedTabID = id }
            } else {
                tiling = .single(id)
            }
        } else if zoomedTabID != id {
            zoomedTabID = nil
        }
        selectedTabID = id
    }

    /// Puts the keyboard in `id`'s pane. A tab that is not showing is left alone.
    func focus(_ id: UUID) {
        guard tiling.contains(id), selectedTabID != id else { return }
        if zoomedTabID != id { zoomedTabID = nil }
        selectedTabID = id
    }

    /// Where a dragged tab lands on a pane: on one of its edges (a new split) or in its middle.
    enum DropZone: Equatable {
        case edge(IDETerminalTiling.Edge)
        case center
    }

    /// Drops `id` on the pane `target`: on an edge it splits, in the middle it takes the pane's place
    /// (a tab already showing swaps places with it).
    func drop(_ id: UUID, onto target: UUID, at zone: DropZone) {
        guard id != target, tabs.contains(where: { $0.id == id }), tabs.contains(where: { $0.id == target }) else { return }
        switch zone {
        case .edge(let edge):
            place(id, beside: target, edge: edge)
        case .center:
            if !tiling.contains(target) { tiling = .single(target) }
            if tiling.contains(id) { tiling.swap(id, target) } else { tiling.replace(target, with: id) }
            zoomedTabID = nil
            selectedTab = .terminal
            selectedTabID = id
            isVisible = true
        }
    }

    /// Shows `id` (a tab from the bar, or one just made) on `edge` of the pane `target`, moving it
    /// out of its old place, and focuses it.
    func place(_ id: UUID, beside target: UUID, edge: IDETerminalTiling.Edge) {
        guard tabs.contains(where: { $0.id == id }), tabs.contains(where: { $0.id == target }), id != target else { return }
        if !tiling.contains(target) { tiling = .single(target) }
        tiling.move(id, beside: target, edge: edge)
        zoomedTabID = nil
        selectedTab = .terminal
        selectedTabID = id
        isVisible = true
    }

    /// Arranges `ids` as `preset`; the focused tab stays focused when it is among them.
    func apply(_ preset: IDETerminalTiling.Preset, filling ids: [UUID]) {
        guard ids.count >= preset.paneCount else { return }
        let shown = Array(ids.prefix(preset.paneCount))
        tiling = .preset(preset, ids: shown)
        zoomedTabID = nil
        selectedTab = .terminal
        if selectedTabID.map(shown.contains) != true { selectedTabID = shown[0] }
        isVisible = true
    }

    /// Shows only `id`.
    func showOnly(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tiling = .single(id)
        zoomedTabID = nil
        selectedTab = .terminal
        selectedTabID = id
    }

    /// Fills the panel with the focused pane, or puts the others back.
    func toggleZoom() {
        guard let selectedTabID, tiling.paneCount > 1 else { return }
        zoomedTabID = zoomedTabID == nil ? selectedTabID : nil
    }

    /// The tab in the pane next to the focused one.
    func neighborID(toward edge: IDETerminalTiling.Edge) -> UUID? {
        guard let selectedTabID, zoomedTabID == nil else { return nil }
        return tiling.neighbor(of: selectedTabID, toward: edge)
    }

    func moveDivider(_ divider: IDETerminalTiling.Divider, toFraction fraction: Double) {
        tiling.moveDivider(path: divider.path, index: divider.index, toFraction: fraction)
    }

    // MARK: Tabs

    /// Adds `tab`, selects it and opens the panel on the shell strip.
    func append(_ tab: IDETerminalTab) {
        tabs.append(tab)
        show(tab.id)
        selectedTab = .terminal
        isVisible = true
    }

    enum Closing {
        case notFound
        /// It was the only tab; none are left and nothing is selected.
        case lastClosed
        case removed
    }

    /// Removes a tab and picks the neighbour to select. An agent command tab is also marked finished,
    /// so output that arrives later does not open it again.
    func closeTab(_ id: UUID) -> Closing {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return .notFound }
        if let commandID = tabs[index].agentCommandID {
            agentCommandTabs[commandID] = nil
            agentCommandFeed[id] = nil
            finishedAgentCommands.insert(commandID)
        }
        if tabs.count == 1 {
            tabs.removeAll()
            selectedTabID = nil
            tiling = IDETerminalTiling()
            zoomedTabID = nil
            return .lastClosed
        }
        let wasSelected = selectedTabID == id
        let shownBefore = tiling.paneIDs
        tiling.remove(id)
        if zoomedTabID == id { zoomedTabID = nil }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let countBeforeRemoval = tabs.count
        tabs.remove(at: index)
        if let newIndex = TabListEngine.selectionIndexAfterClose(
            closing: index, selected: selectedIndex, count: countBeforeRemoval
        ) {
            selectedTabID = tabs[newIndex].id
        } else {
            selectedTabID = tabs.first?.id
        }
        // The pane that was next to the closed one takes the keyboard.
        if wasSelected, let position = shownBefore.firstIndex(of: id) {
            let remaining = Set(tiling.paneIDs)
            let neighbor = shownBefore[..<position].last { remaining.contains($0) }
                ?? shownBefore[(position + 1)...].first { remaining.contains($0) }
            if let neighbor { selectedTabID = neighbor }
        }
        if let selectedTabID, !tiling.contains(selectedTabID) {
            if tiling.isEmpty { tiling = .single(selectedTabID) } else { show(selectedTabID) }
        }
        return .removed
    }

    /// Selects a shell tab; false when there is no such tab.
    func selectTab(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        selectedTab = .terminal
        show(id)
        return true
    }

    /// The tab after the selected one, wrapping, while the panel shows.
    func nextTabID() -> UUID? {
        guard isVisible, let current = selectedIndex else { return nil }
        return TabListEngine.nextIndex(after: current, count: tabs.count).map { tabs[$0].id }
    }

    func previousTabID() -> UUID? {
        guard isVisible, let current = selectedIndex else { return nil }
        return TabListEngine.previousIndex(before: current, count: tabs.count).map { tabs[$0].id }
    }

    private var selectedIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    func updateTitle(_ id: UUID, to title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, tabs[index].title != trimmed else { return }
        tabs[index].title = trimmed
    }

    func updateDirectory(_ id: UUID, to url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].workingDirectory.path != url.path else { return }
        tabs[index].workingDirectory = url
    }

    /// Wipes the visible shell's screen and scrollback; the shell redraws its prompt.
    func requestClear() {
        guard isVisible, isShellSelected, let index = selectedIndex else { return }
        tabs[index].clearRequestID += 1
    }

    /// Restarts a shell (the selected one for `nil`) and selects it. An agent command tab has no shell
    /// to restart: starting one would replace the output. Returns whether a shell was restarted.
    func requestRestart(_ id: UUID?) -> Bool {
        guard let id = id ?? selectedTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        guard tabs[index].agentCommandID == nil else { return false }
        tabs[index].restartRequestID += 1
        show(id)
        return true
    }

    /// Points every shell at `directory` (the one a new tab would use) and restarts a shell that was
    /// somewhere else.
    func resetShells(to directory: URL) {
        let title = IDETerminalTab.defaultTitle(for: directory)
        let path = directory.standardizedFileURL.path
        for index in tabs.indices where tabs[index].agentCommandID == nil {
            let same = tabs[index].workingDirectory.standardizedFileURL.path == path
            tabs[index].workingDirectory = directory
            tabs[index].title = title
            if !same {
                tabs[index].restartRequestID += 1
            }
        }
    }

    // MARK: Agent commands

    /// Appends text to the command's display tab, opening one in `directory` the first time. `nil`
    /// ends the command: a closed tab, and anything sent after this, is dropped rather than opening
    /// another tab. Returns true when it opened a tab, which the window saves.
    func showAgentCommand(id: UUID, title: String, line: String?, directory: @autoclosure () -> URL) -> Bool {
        guard let line else {
            finishedAgentCommands.insert(id)
            return false
        }
        guard !finishedAgentCommands.contains(id) else { return false }
        let tabID: UUID
        var opened = false
        if let existing = agentCommandTabs[id] {
            guard tabs.contains(where: { $0.id == existing }) else { return false }
            tabID = existing
        } else {
            let tab = IDETerminalTab(
                id: UUID(), title: IDETerminalTab.commandTitle(for: title),
                workingDirectory: directory(), agentCommandID: id)
            append(tab)
            agentCommandTabs[id] = tab.id
            tabID = tab.id
            opened = true
        }
        agentCommandFeed[tabID, default: ""] += line
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].agentFeedGeneration += 1
        }
        return opened
    }

    /// The output waiting for an agent command tab, consumed once by its view.
    func takeAgentCommandFeed(tabID: UUID) -> String {
        let text = agentCommandFeed[tabID] ?? ""
        agentCommandFeed[tabID] = nil
        return text
    }
}
