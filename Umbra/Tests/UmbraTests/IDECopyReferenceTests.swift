import XCTest
@testable import Umbra

final class IDECopyReferenceTests: XCTestCase {
    private let roots = IDECopyReferenceRoots(
        projectRoot: "/work/repo/app",
        repositoryRoot: "/work/repo",
        contentRoots: ["/work/repo/app", "/work/repo/app/core"],
        sourceRoots: ["/work/repo/app/core/src/main/java"]
    )

    private func values(_ url: String, roots: IDECopyReferenceRoots? = nil) -> [String: String] {
        let sections = IDECopyReference.sections(for: URL(fileURLWithPath: url), roots: roots ?? self.roots)
        return Dictionary(uniqueKeysWithValues: sections.joined().map { ($0.label, $0.value) })
    }

    func testRowsForAFileInANestedModule() {
        let rows = values("/work/repo/app/core/src/main/java/com/foo/Bar.java")
        XCTAssertEqual(rows["Absolute Path"], "/work/repo/app/core/src/main/java/com/foo/Bar.java")
        XCTAssertEqual(rows["File Name"], "Bar.java")
        XCTAssertEqual(rows["Path from Project Root"], "core/src/main/java/com/foo/Bar.java")
        XCTAssertEqual(rows["Path from Content Root"], "src/main/java/com/foo/Bar.java")
        XCTAssertEqual(rows["Path from Source Root"], "com/foo/Bar.java")
        XCTAssertEqual(rows["Path from Repository Root"], "app/core/src/main/java/com/foo/Bar.java")
    }

    func testResourcesFolderFallsBackToTheSrcConvention() {
        let rows = values("/work/repo/app/core/src/main/resources/application.yaml")
        XCTAssertEqual(rows["Path from Source Root"], "application.yaml")
    }

    func testFileOutsideEverySourceRootHasNoSourceRow() {
        XCTAssertNil(values("/work/repo/app/README.md")["Path from Source Root"])
    }

    func testNoRepositoryLeavesOutThatRow() {
        var noRepository = roots
        noRepository.repositoryRoot = nil
        XCTAssertNil(values("/work/repo/app/README.md", roots: noRepository)["Path from Repository Root"])
    }

    func testSiblingFolderWithTheSamePrefixIsNotInside() {
        XCTAssertNil(IDECopyReference.relativePath("/work/repo/application/x", to: "/work/repo/app"))
    }

    func testJavaQualifiedName() {
        let url = URL(fileURLWithPath: "/work/repo/app/core/src/main/java/com/foo/Bar.java")
        XCTAssertEqual(IDECopyReference.javaQualifiedName(for: url, roots: roots), "com.foo.Bar")
        let info = URL(fileURLWithPath: "/work/repo/app/core/src/main/java/com/foo/package-info.java")
        XCTAssertNil(IDECopyReference.javaQualifiedName(for: info, roots: roots))
        let yaml = URL(fileURLWithPath: "/work/repo/app/core/src/main/resources/a.yaml")
        XCTAssertNil(IDECopyReference.javaQualifiedName(for: yaml, roots: roots))
    }

    func testReferencePathPrefersTheRepositoryRoot() {
        let url = URL(fileURLWithPath: "/work/repo/app/core/src/main/java/com/foo/Bar.java")
        XCTAssertEqual(IDECopyReference.referencePath(for: url, roots: roots), "app/core/src/main/java/com/foo/Bar.java")
        var noRepository = roots
        noRepository.repositoryRoot = nil
        XCTAssertEqual(IDECopyReference.referencePath(for: url, roots: noRepository), "core/src/main/java/com/foo/Bar.java")
    }

    func testLineReference() {
        XCTAssertEqual(IDECopyReference.lineReference(path: "a/B.java", lines: 42...42), "a/B.java:42")
        XCTAssertEqual(IDECopyReference.lineReference(path: "a/B.java", lines: 18...57), "a/B.java:18-57")
    }

    func testLineRangeOfASelection() {
        // Lines 17...56 (0-based) ending mid-line cover 18-57.
        XCTAssertEqual(IDECopyReference.lineRange(startLine: 17, endLine: 56, endColumn: 4, isEmpty: false), 18...57)
        // A selection ending at the start of the next line leaves that line out.
        XCTAssertEqual(IDECopyReference.lineRange(startLine: 17, endLine: 57, endColumn: 0, isEmpty: false), 18...57)
        // A caret, and a one-line selection, are one line.
        XCTAssertEqual(IDECopyReference.lineRange(startLine: 9, endLine: 9, endColumn: 3, isEmpty: true), 10...10)
        XCTAssertEqual(IDECopyReference.lineRange(startLine: 9, endLine: 9, endColumn: 8, isEmpty: false), 10...10)
    }
}
