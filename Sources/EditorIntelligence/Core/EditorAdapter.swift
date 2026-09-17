import Foundation

/// Interface an editor must provide to the Editor Intelligence Platform.
///
/// Implementations are editor-specific (e.g., `PenumbraEditorAdapter`) and bridge the
/// editor's native document model to the EIP's `Document`, `Cursor`, `Selection`, and
/// `Viewport` abstractions. The adapter emits events through an `AsyncSequence` event
/// stream and applies edits back to the editor asynchronously.
public protocol EditorAdapter: AnyObject {
    /// Stable identifier for this editor instance.
    var id: EditorAdapterID { get }

    /// Context describing the editor and its root project.
    var context: EditorContext { get }

    /// Snapshot of the currently active document, if any.
    var currentDocument: Document? { get }

    /// Snapshots of all open documents in the editor.
    var openDocuments: [Document] { get }

    /// Stream of editor events consumed by the EIP.
    var events: AsyncStream<EditorEvent> { get }

    /// Retrieve a snapshot of a specific document by ID.
    func document(withID id: DocumentID) -> Document?

    /// Apply an edit to the document identified by `documentID`.
    func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws

    /// Move the cursor/selection to a specific range in a document.
    func focusRange(_ range: TextRange, inDocumentWithID documentID: DocumentID) async throws
}
