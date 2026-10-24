import Foundation
import Observation
import Penumbra

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

    // MARK: Tabs

    /// Adds `tab`, selects it and opens the panel on the shell strip.
    func append(_ tab: IDETerminalTab) {
        tabs.append(tab)
        selectedTabID = tab.id
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
            return .lastClosed
        }
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
        return .removed
    }

    /// Selects a shell tab; false when there is no such tab.
    func selectTab(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        selectedTab = .terminal
        selectedTabID = id
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
        selectedTabID = id
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
