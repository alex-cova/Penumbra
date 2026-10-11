import EditorIntelligence
import Foundation

/// Pushes ``WorkbenchDocument`` snapshots into an EIP ``Workspace`` actor.
///
/// Main-actor isolated because panes and documents are main-thread state: the snapshots are taken
/// here, synchronously, and only those values travel to the workspace. (As an actor it read
/// `pane.documents` and each document's selection on a background thread while the editor changed
/// them — data races the thread sanitizer reported.) Syncs apply one after another in call order,
/// so overlapping calls cannot race `versions` and an older snapshot never lands after a newer one.
@MainActor
public final class PenumbraWorkbenchWorkspaceBridge {
    public nonisolated let workspace: Workspace
    private var versions: [DocumentID: Int] = [:]
    /// The sync applied last; the next one waits for it.
    private var tail: Task<Void, Never>?

    private struct PaneSnapshot: Sendable {
        var documents: [Document]
        var selectedID: DocumentID?
    }

    public nonisolated init(workspace: Workspace = Workspace()) {
        self.workspace = workspace
    }

    public func syncPane(_ pane: EditorPane) async {
        let snapshot = snapshot(of: pane)
        await enqueue([snapshot])
    }

    public func syncWorkbench(_ workbench: EditorWorkbench) async {
        let snapshots = workbench.panes.map { snapshot(of: $0) }
        await enqueue(snapshots)
    }

    private func snapshot(of pane: EditorPane) -> PaneSnapshot {
        let documents = pane.documents.map { document -> Document in
            let version = (versions[document.documentID] ?? 0) + 1
            versions[document.documentID] = version
            return document.makeEIPDocument(version: version)
        }
        return PaneSnapshot(documents: documents, selectedID: pane.selectedDocument?.documentID)
    }

    private func enqueue(_ snapshots: [PaneSnapshot]) async {
        let previous = tail
        let workspace = workspace
        let task = Task<[DocumentID], Never> {
            await previous?.value
            var closed: [DocumentID] = []
            for snapshot in snapshots {
                closed += await Self.apply(snapshot, to: workspace)
            }
            return closed
        }
        tail = Task { _ = await task.value }
        for id in await task.value { versions.removeValue(forKey: id) }
    }

    /// Makes the workspace hold exactly this pane's documents. Returns the ids it closed.
    private nonisolated static func apply(_ snapshot: PaneSnapshot, to workspace: Workspace) async -> [DocumentID] {
        let openIDs = Set(snapshot.documents.map(\.id))
        var closed: [DocumentID] = []
        for existing in await workspace.allOpenDocuments() where !openIDs.contains(existing.id) {
            await workspace.closeDocument(existing.id)
            closed.append(existing.id)
        }
        for document in snapshot.documents {
            if await workspace.document(withID: document.id) != nil {
                await workspace.updateDocument(document)
            } else {
                await workspace.openDocument(document)
            }
        }
        if let selectedID = snapshot.selectedID {
            await workspace.activateDocument(selectedID)
        }
        return closed
    }
}
