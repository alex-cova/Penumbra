import Foundation
import GitIntelligence

extension IDEAgentController {
    /// Whether the selected chat works in a worktree Umbra created, rather than the project folder.
    var isWorktreeChat: Bool { selected.rootOverride != nil }

    /// Starts a chat in a fresh worktree: a folder under Application Support on a new branch named
    /// from `title`. The agent reads and writes only there; navigation answers still come from the
    /// window's index, so they may name files outside the worktree.
    func startWorktreeConversation(title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, let root = host.agentProjectRoot else {
            selected.appendNotice("Open a project folder first; a worktree needs a git repository.")
            return
        }
        Task {
            guard let repository = await GitRepository.discover(from: root) else {
                selected.appendNotice("This project is not inside a git repository, so it cannot start a worktree chat.")
                return
            }
            do {
                let (path, branch) = try await worktreeStore.create(
                    repository: repository, title: name.isEmpty ? "worktree" : name)
                let target = selected.isEmpty && !selected.isRunning ? selected : addConversation()
                target.rootOverride = path
                if !name.isEmpty { target.customTitle = String(name.prefix(80)) }
                target.appendNotice(
                    "Working in a worktree on \(branch). The main tree stays clean; navigation answers still come from its index.")
            } catch {
                selected.appendError(error.localizedDescription)
            }
        }
    }

    /// Removes the selected chat's worktree and deletes its branch, after the caller confirmed.
    /// Only a path from the manifest is ever removed. The chat keeps its transcript and goes back
    /// to the project folder.
    func discardWorktreeConversation() {
        guard let path = selected.rootOverride else {
            selected.appendNotice("This chat is not in a worktree.")
            return
        }
        guard let host, let root = host.agentProjectRoot else {
            selected.appendError("Open a project folder first; only then can its worktree be removed.")
            return
        }
        Task {
            guard let repository = await GitRepository.discover(from: root) else {
                selected.appendError("This project is not inside a git repository.")
                return
            }
            do {
                let report = try await worktreeStore.discard(repository: repository, path: path.path)
                selected.rootOverride = nil
                selected.appendNotice(report + " This chat now uses the project folder.")
            } catch {
                selected.appendError(error.localizedDescription)
            }
        }
    }
}
