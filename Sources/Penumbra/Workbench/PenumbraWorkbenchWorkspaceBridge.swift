import EditorIntelligence
import Foundation

/// Pushes ``WorkbenchDocument`` snapshots into an EIP ``Workspace`` actor.
///
/// An actor so overlapping host `Task`s cannot race `versions` — a non-isolated class
/// crashed in `Dictionary.lookup` when `syncPane` ran concurrently.
public actor PenumbraWorkbenchWorkspaceBridge {
    public nonisolated let workspace: Workspace
    private var versions: [DocumentID: Int] = [:]

    public init(workspace: Workspace = Workspace()) {
        self.workspace = workspace
    }

    public func syncPane(_ pane: EditorPane) async {
        let documents = pane.documents
        let selectedID = pane.selectedDocument?.documentID
        let openIDs = Set(documents.map(\.documentID))
        for existing in await workspace.allOpenDocuments() {
            if !openIDs.contains(existing.id) {
                await workspace.closeDocument(existing.id)
                versions.removeValue(forKey: existing.id)
            }
        }
        for document in documents {
            let version = (versions[document.documentID] ?? 0) + 1
            versions[document.documentID] = version
            let snapshot = document.makeEIPDocument(version: version)
            if await workspace.document(withID: document.documentID) != nil {
                await workspace.updateDocument(snapshot)
            } else {
                await workspace.openDocument(snapshot)
            }
        }
        if let selectedID {
            await workspace.activateDocument(selectedID)
        }
    }

    public func syncWorkbench(_ workbench: EditorWorkbench) async {
        let panes = workbench.panes
        for pane in panes {
            await syncPane(pane)
        }
    }
}
