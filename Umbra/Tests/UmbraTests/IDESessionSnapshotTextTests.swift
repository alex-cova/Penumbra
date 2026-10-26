import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

/// The session restores an editor tab from `WorkbenchDocument.text`, which the live buffer only
/// refreshes after a debounce. A session captured sooner (quit right after typing and saving)
/// must still hold what the editor shows, not what the file had when it was opened.
@MainActor
final class IDESessionSnapshotTextTests: XCTestCase {
    private func makeProject(contents: String) throws -> (project: URL, file: URL) {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-text-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("requests.http")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return (project, file)
    }

    func testSessionCapturedRightAfterSavingHoldsTheEditedText() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let stale = "###\nGET ttps://api.example.com/product\n"
        let (project, file) = try makeProject(contents: stale)
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        workspace.project.setRoot(project)
        workspace.bootstrap()

        let documentID = UUID()
        let snapshot = WorkbenchDocumentSnapshot(
            id: UUID(), documentID: documentID, url: file, displayName: "requests.http", text: stale,
            languageIdentifier: "http", isDirty: true, selectedRangeLocation: 8, isFileBacked: false
        )
        let pane = EditorPaneSnapshot(id: workspace.workbench.activePaneID, documents: [snapshot], selectedDocumentID: snapshot.id)
        workspace.workbench.restore(from: EditorRestorationState(activePaneID: pane.id, layout: .pane(pane)), languageResolver: IDELanguageSupport.languageResolver)
        await workspace.openDocument(from: file)
        try await Task.sleep(nanoseconds: 700_000_000)

        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        XCTAssertEqual(textView.text as String, stale)
        textView.replace(NSRange(location: 8, length: 0), withText: "h")
        await workspace.saveActiveDocument()

        let after = try documentSnapshot(of: workspace)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "###\nGET https://api.example.com/product\n")
        XCTAssertFalse(after.isFileBacked)
        XCTAssertEqual(after.text, "###\nGET https://api.example.com/product\n")
    }

    private func documentSnapshot(of workspace: IDEWorkspace) throws -> WorkbenchDocumentSnapshot {
        let restoration = try XCTUnwrap(workspace.makeSession().restoration)
        func documents(in layout: EditorLayoutSnapshot) -> [WorkbenchDocumentSnapshot] {
            switch layout {
            case .pane(let pane): pane.documents
            case .vertical(let split), .horizontal(let split): split.children.flatMap(documents)
            }
        }
        return try XCTUnwrap(documents(in: restoration.layout).first { $0.url?.lastPathComponent == "requests.http" })
    }
}
