import EditorIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEFindInFilesModelTests: XCTestCase {
    func testOptionsDescribeTheQuery() {
        let model = IDEFindInFilesModel()
        model.query = "foo"
        model.isCaseSensitive = true
        model.matchesWholeWord = true
        let query = model.searchQuery
        XCTAssertEqual(query.text, "foo")
        XCTAssertTrue(query.isCaseSensitive)
        XCTAssertTrue(query.matchWholeWord)
        XCTAssertFalse(query.useRegularExpression)
    }

    func testShowSaysWhatToDoOnlyTheFirstTime() {
        let model = IDEFindInFilesModel()
        model.show(hasProject: false)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.status, "Open a folder to search the project")
        model.status = "3 results"
        model.show(hasProject: true)
        XCTAssertEqual(model.status, "3 results", "a result line is not overwritten")
        let fresh = IDEFindInFilesModel()
        fresh.show(hasProject: true)
        XCTAssertEqual(fresh.status, "Enter a query and press Return")
    }

    func testResultsSetTheStatusLine() {
        let model = IDEFindInFilesModel()
        model.setResults([])
        XCTAssertEqual(model.status, "No results")
        model.fail("Not a valid regular expression")
        XCTAssertEqual(model.status, "Not a valid regular expression")
        XCTAssertTrue(model.hits.isEmpty)
    }

    func testAnInvalidMaskIsNamed() {
        let model = IDEFindInFilesModel()
        XCTAssertNil(model.maskProblem)
        model.mask = "*.java, !*Test.java"
        XCTAssertNil(model.maskProblem)
    }

    func testTheFileListScopesUseTheWindowsFiles() {
        let model = IDEFindInFilesModel()
        model.scope = .openFiles
        let open = model.filter(openFilePaths: ["/p/A.java"], changedFilePaths: ["/p/B.java"])
        XCTAssertEqual(open.onlyFiles, [URL(fileURLWithPath: "/p/A.java")])
        model.scope = .changedFiles
        let changed = model.filter(openFilePaths: ["/p/A.java"], changedFilePaths: ["/p/B.java"])
        XCTAssertEqual(changed.onlyFiles, [URL(fileURLWithPath: "/p/B.java")])
        model.scope = .project
        XCTAssertTrue(model.filter(openFilePaths: [], changedFilePaths: []).isUnrestricted)
    }

    func testAScopeFolderOutsideTheProjectFallsBackToTheProject() {
        let model = IDEFindInFilesModel()
        let root = URL(fileURLWithPath: "/tmp/project")
        model.scope = .directory(root.appendingPathComponent("src"))
        model.resetStaleScope(root: root)
        XCTAssertEqual(model.scope, .directory(root.appendingPathComponent("src")), "inside: kept")
        model.scope = .directory(URL(fileURLWithPath: "/elsewhere"))
        model.resetStaleScope(root: root)
        XCTAssertEqual(model.scope, .project)
    }

    func testTheScopeIsDescribedForTheReplaceWarning() {
        let model = IDEFindInFilesModel()
        model.mask = "*.java"
        model.scope = .openFiles
        let filter = model.filter(openFilePaths: [], changedFilePaths: [])
        XCTAssertEqual(model.scopeDescription(for: filter), "files matching *.java in open files")
    }

    func testResultsSelectTheFirstHitAndKeepItAcrossARerun() {
        let model = IDEFindInFilesModel()
        let first = hit("/p/A.java", line: 1, offset: 10)
        let second = hit("/p/B.java", line: 2, offset: 20)
        model.setResults([first, second])
        XCTAssertEqual(model.selectedHitID, first.id)
        XCTAssertEqual(model.selectedHit?.url.lastPathComponent, "A.java")

        model.moveSelection(1)
        XCTAssertEqual(model.selectedHitID, second.id)
        model.setResults([first, second])
        XCTAssertEqual(model.selectedHitID, second.id, "a re-run that still contains the hit must not jump")

        model.setResults([first])
        XCTAssertEqual(model.selectedHitID, first.id, "a missing hit falls back to the first")
    }

    func testArrowKeysClampAtTheEnds() {
        let model = IDEFindInFilesModel()
        XCTAssertFalse(model.moveSelection(1))
        model.setResults([hit("/p/A.java", line: 0, offset: 0), hit("/p/B.java", line: 1, offset: 4)])
        XCTAssertEqual(model.selectedHitID, model.hits[0].id)
        XCTAssertTrue(model.moveSelection(1))
        XCTAssertEqual(model.selectedHitID, model.hits[1].id)
        XCTAssertTrue(model.moveSelection(1), "down past the last hit stays on it")
        XCTAssertEqual(model.selectedHitID, model.hits[1].id)
        XCTAssertTrue(model.moveSelection(-1))
        XCTAssertEqual(model.selectedHitID, model.hits[0].id)
        XCTAssertTrue(model.moveSelection(-1), "up past the first hit stays on it")
        XCTAssertEqual(model.selectedHitID, model.hits[0].id)
    }

    func testASupersededSearchDoesNotReplaceNewerResults() {
        let model = IDEFindInFilesModel()
        let first = model.beginSearch()
        let second = model.beginSearch()
        XCTAssertEqual(model.status, "Searching…")
        model.setResults([hit("/p/stale.java", line: 0, offset: 0)], generation: first)
        XCTAssertTrue(model.hits.isEmpty, "the older search must not land")
        XCTAssertEqual(model.status, "Searching…")
        model.setResults([hit("/p/fresh.java", line: 1, offset: 8)], generation: second)
        XCTAssertEqual(model.hits.first?.url.lastPathComponent, "fresh.java")
        XCTAssertEqual(model.selectedHit?.url.lastPathComponent, "fresh.java")
        model.fail("ignored", generation: first)
        XCTAssertEqual(model.hits.count, 1, "a stale failure must not clear newer hits")
    }

    func testFailClearsTheSelectionAndTheFocusRequest() {
        let model = IDEFindInFilesModel()
        model.setResults([hit("/p/A.java", line: 0, offset: 0)])
        model.wantsResultsFocus = true
        model.wantsQueryFocus = true
        model.fail("Not a valid regular expression")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertNil(model.selectedHitID)
        XCTAssertFalse(model.wantsResultsFocus)
        XCTAssertFalse(model.wantsQueryFocus)
    }

    func testEscapeFromTheEditorDoesNothingWhileHidden() {
        let model = IDEFindInFilesModel()
        XCTAssertFalse(model.requestFocusFromEditor())
        XCTAssertFalse(model.wantsQueryFocus)
        XCTAssertFalse(model.wantsResultsFocus)
        XCTAssertEqual(model.focusGeneration, 0)
    }

    func testEscapeFromTheEditorReturnsToTheQueryWhenThereIsNoHit() {
        let model = IDEFindInFilesModel()
        model.show(hasProject: true)
        model.editorEscapeReturnsToDrawer = true
        XCTAssertTrue(model.requestFocusFromEditor())
        XCTAssertTrue(model.wantsQueryFocus)
        XCTAssertFalse(model.wantsResultsFocus)
        XCTAssertEqual(model.focusGeneration, 1)
    }

    func testTheWorkspaceOffersEditorEscapeToFindInFiles() {
        let workspace = IDEWorkspace()
        XCTAssertFalse(workspace.handleEditorEscape())
        workspace.findInFiles.isVisible = true
        XCTAssertFalse(workspace.handleEditorEscape(), "the editor was not reached from the drawer")
        workspace.findInFiles.editorEscapeReturnsToDrawer = true
        XCTAssertTrue(workspace.handleEditorEscape())
        XCTAssertTrue(workspace.findInFiles.wantsQueryFocus)
        workspace.findInFiles.isVisible = false
        XCTAssertFalse(workspace.handleEditorEscape())
    }

    func testEscapeFromTheEditorReturnsToTheSelectedHit() {
        let model = IDEFindInFilesModel()
        model.show(hasProject: true)
        model.setResults([hit("/p/A.java", line: 0, offset: 0)])
        XCTAssertNotNil(model.selectedHitID)
        model.editorEscapeReturnsToDrawer = true
        XCTAssertTrue(model.requestFocusFromEditor())
        XCTAssertTrue(model.wantsResultsFocus)
        XCTAssertFalse(model.wantsQueryFocus)
        XCTAssertEqual(model.focusGeneration, 1)

        model.wantsResultsFocus = false
        XCTAssertFalse(model.requestFocusFromEditor(), "one Escape per trip: the next is the editor's")

        model.editorEscapeReturnsToDrawer = true
        XCTAssertTrue(model.requestFocusFromEditor(), "after opening another hit, Escape returns again")
        XCTAssertTrue(model.wantsResultsFocus)
        XCTAssertEqual(model.focusGeneration, 2)
    }

    func testEscapeIsLeftToTheEditorUnlessAHitWasOpenedFromTheDrawer() {
        let model = IDEFindInFilesModel()
        model.show(hasProject: true)
        model.setResults([hit("/p/A.java", line: 0, offset: 0)])
        XCTAssertFalse(model.requestFocusFromEditor(), "the drawer is open, but the user came to the editor on their own")
        XCTAssertEqual(model.focusGeneration, 0)
    }

    func testANewSearchEndsTheEscapeTrip() {
        let model = IDEFindInFilesModel()
        model.show(hasProject: true)
        model.editorEscapeReturnsToDrawer = true
        model.beginSearch()
        XCTAssertFalse(model.editorEscapeReturnsToDrawer)
        XCTAssertFalse(model.requestFocusFromEditor())
    }

    func testOpeningAHitStartsAndHidingTheDrawerEndsTheEscapeTrip() {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.windowWillClose() }
        workspace.findInFiles.isVisible = true
        workspace.findInFiles.setResults([hit("/p/A.java", line: 0, offset: 0)])
        let opened = workspace.findInFiles.hits[0]

        workspace.openFindInFilesHit(opened)
        XCTAssertTrue(workspace.findInFiles.editorEscapeReturnsToDrawer)

        workspace.hideFindInFiles()
        XCTAssertFalse(workspace.findInFiles.editorEscapeReturnsToDrawer)
        XCTAssertFalse(workspace.handleEditorEscape())
    }

    private func hit(_ path: String, line: Int, offset: Int) -> ProjectSearchResult {
        ProjectSearchResult(
            url: URL(fileURLWithPath: path),
            line: line,
            column: 0,
            preview: "match",
            range: TextRange(
                start: TextPosition(line: line, column: 0, utf16Offset: offset),
                end: TextPosition(line: line, column: 3, utf16Offset: offset + 3)
            )
        )
    }
}
