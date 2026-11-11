import Foundation
import Observation

/// The workspace's diff and merge tabs, without the workbench: which document shows which
/// session. The tabs themselves, the viewers and git stay on `IDEWorkspace` (F-11); this owns
/// only the registry both sides share, so a save, a close and a git refresh see the same
/// sessions the tabs show.
@MainActor
@Observable
final class IDEDiffSessionStore {
    private(set) var diffs: [UUID: IDEDiffSession] = [:]
    private(set) var merges: [UUID: IDEMergeSession] = [:]

    var isEmpty: Bool { diffs.isEmpty && merges.isEmpty }

    func session(for documentID: UUID) -> IDEDiffSession? {
        diffs[documentID]
    }

    func mergeSession(for documentID: UUID) -> IDEMergeSession? {
        merges[documentID]
    }

    func register(_ session: IDEDiffSession, for documentID: UUID) {
        diffs[documentID] = session
    }

    func register(_ merge: IDEMergeSession, for documentID: UUID) {
        merges[documentID] = merge
    }

    @discardableResult
    func removeSession(for documentID: UUID) -> IDEDiffSession? {
        diffs.removeValue(forKey: documentID)
    }

    @discardableResult
    func removeMerge(for documentID: UUID) -> IDEMergeSession? {
        merges.removeValue(forKey: documentID)
    }

    /// Every session, both registries emptied.
    func removeAll() -> (diffs: [IDEDiffSession], merges: [IDEMergeSession]) {
        let removed = (diffs: Array(diffs.values), merges: Array(merges.values))
        diffs.removeAll()
        merges.removeAll()
        return removed
    }

    /// After git or the disk changed (a save, a stage, a pull), every diff tab reloads; one whose
    /// texts did not change keeps its scroll position and caret.
    func reloadAll() {
        for session in diffs.values where !session.isRightDirty {
            session.reload()
        }
    }

    /// Reloads the sessions whose file is in `relativePaths`. Other tabs keep their texts.
    func reload(relativePaths: Set<String>) {
        guard !relativePaths.isEmpty else { return }
        for session in diffs.values where !session.isRightDirty {
            let paths = session.request.revisionPaths
            guard !paths.isDisjoint(with: relativePaths) else { continue }
            session.reload()
        }
    }
}
