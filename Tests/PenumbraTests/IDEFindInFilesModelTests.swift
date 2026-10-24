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
}
