import XCTest
import EditorIntelligence

final class WorkspaceTests: XCTestCase {
    func testAddAndRemoveProject() async {
        let workspace = Workspace()
        let project = Project(url: URL(fileURLWithPath: "/tmp/test"), name: "test")
        await workspace.addProject(project)
        var projects = await workspace.allProjects()
        XCTAssertEqual(projects.count, 1)
        await workspace.removeProject(project.id)
        projects = await workspace.allProjects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testOpenDocumentBecomesActive() async {
        let workspace = Workspace()
        let document = makeDocument(id: DocumentID(), text: "hello")
        await workspace.openDocument(document)
        let active = await workspace.activeDocument()
        XCTAssertEqual(active?.id, document.id)
        let all = await workspace.allOpenDocuments()
        XCTAssertEqual(all.count, 1)
    }

    func testHandleDocumentChangedEvent() async {
        let workspace = Workspace()
        let document = makeDocument(id: DocumentID(), text: "hello")
        await workspace.openDocument(document)
        let newSnapshot = TextSnapshot(version: 1, text: "hello world")
        await workspace.handleEditorEvent(.documentChanged(document.id, newSnapshot))
        let updated = await workspace.document(withID: document.id)
        XCTAssertEqual(updated?.text, "hello world")
        XCTAssertEqual(updated?.version, 1)
    }

    func testHandleDocumentEditedEventUpdatesSnapshotWithoutFullDocumentChanged() async {
        let workspace = Workspace()
        let document = makeDocument(id: DocumentID(), text: "hello")
        await workspace.openDocument(document)

        let stream = workspace.eventBus.events
        let task = Task { () -> (Document?, [TextEdit], Bool) in
            var editedDocument: Document?
            var editedEdits: [TextEdit] = []
            var sawDocumentChangedAfterOpen = false
            for await event in stream {
                switch event {
                case .documentEdited(let doc, let edits):
                    editedDocument = doc
                    editedEdits = edits
                    return (editedDocument, editedEdits, sawDocumentChangedAfterOpen)
                case .documentChanged:
                    sawDocumentChangedAfterOpen = true
                default:
                    break
                }
            }
            return (editedDocument, editedEdits, sawDocumentChangedAfterOpen)
        }

        let start = TextPosition(line: 0, column: 5, utf16Offset: 5)
        let edit = TextEdit(
            range: TextRange(start: start, end: start),
            replacement: " world"
        )
        let newSnapshot = TextSnapshot(version: 1, text: "hello world")
        await workspace.handleEditorEvent(.documentEdited(document.id, [edit], newSnapshot: newSnapshot))
        let (editedDocument, editedEdits, sawDocumentChangedAfterOpen) = await task.value

        let updated = await workspace.document(withID: document.id)
        XCTAssertEqual(updated?.text, "hello world")
        XCTAssertEqual(editedDocument?.text, "hello world")
        XCTAssertEqual(editedEdits.count, 1)
        XCTAssertEqual(editedEdits.first?.replacement, " world")
        XCTAssertFalse(sawDocumentChangedAfterOpen)
    }
}

private func makeDocument(id: DocumentID, text: String) -> Document {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: id,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
}
