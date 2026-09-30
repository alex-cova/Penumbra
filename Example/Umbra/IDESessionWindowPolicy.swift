import Foundation

/// Which window's layout is saved to `last-window.json`, who takes over when it closes, and when a
/// new window restores the last one. No AppKit and no workspaces, so the rules can be tested
/// directly; `IDEWindowRegistry` builds the inputs from its windows and acts on the answers.
///
/// Windows are always passed most recently key first.
enum IDESessionWindowPolicy {
    struct Window: Equatable {
        let id: UUID
        /// A blank window opened next to others that has not been used (`IDEWorkspace.isPristine`).
        var isPristine: Bool
    }

    /// The window whose layout is restored at the next launch: the one that was key last, skipping
    /// pristine windows, so a blank window opened next to others does not replace the project the
    /// user was working in just because it was clicked.
    static func sessionWindow(in windows: [Window]) -> UUID? {
        windows.first { !$0.isPristine }?.id
    }

    /// The window that takes over and saves its layout when `closing` goes away: only when the
    /// closing window was the session window, and only if another window with content remains. With
    /// none left the closing window's own save stands.
    static func successor(afterClosing closing: UUID, in windows: [Window]) -> UUID? {
        guard sessionWindow(in: windows) == closing else { return nil }
        return sessionWindow(in: windows.filter { $0.id != closing })
    }

    /// True while no other window is open and no new window was requested for a folder or file
    /// (`pendingNewWindowJobs` counts only requests that carry URLs; a plain New Window does not
    /// block restoring): the window opening now restores the last window.
    static func shouldRestoreLastWindow(openWindowCount: Int, pendingNewWindowJobs: Int) -> Bool {
        openWindowCount == 0 && pendingNewWindowJobs == 0
    }

    /// `order` after `id` became the key window. An id that is not registered is ignored: adding it
    /// would make `register` skip the window and count it as open while it is still deciding
    /// whether to restore.
    static func activated(_ id: UUID, in order: [UUID]) -> [UUID] {
        guard order.contains(id) else { return order }
        return [id] + order.filter { $0 != id }
    }

    /// `order` after `id` registered: a window that is already key (the first one, or a new one
    /// brought forward) leads, any other goes after the windows that have been key.
    static func registered(_ id: UUID, isKey: Bool, in order: [UUID]) -> [UUID] {
        guard !order.contains(id) else { return order }
        return isKey ? [id] + order : order + [id]
    }
}
