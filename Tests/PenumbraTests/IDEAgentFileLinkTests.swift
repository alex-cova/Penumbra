import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentFileLinkTests: XCTestCase {
    private let path = "perkeo/src/main/java/com/balatro/LongArrayLock.java"

    private func linkify(_ text: String, exists: @escaping (String) -> Bool = { _ in false }) -> String {
        IDEAgentFileLinks.linkify(text, exists: exists)
    }

    func testAParenthesizedProjectPathBecomesALinkAndARepeatedOneDoesToo() throws {
        let text = "See (\(path)) and (\(path))."
        let linked = linkify(text) { $0 == self.path }
        XCTAssertTrue(linked.hasPrefix("See (["))
        XCTAssertEqual(linked.components(separatedBy: "umbra-file://").count - 1, 2)
        XCTAssertTrue(linked.contains(")) and (["), linked)

        let styled = IDEAgentFormat.markdown(linked)
        XCTAssertEqual(String(styled.characters), text)
        let links = styled.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 2)
        let reference = try XCTUnwrap(IDEAgentFileLinks.reference(from: links[0]))
        XCTAssertEqual(reference, IDEAgentFileLinks.Reference(path: path, line: nil, column: nil))
        XCTAssertEqual(links[0].scheme, IDEAgentFileLinks.scheme)
    }

    func testALineColumnAndRangeStayInTheLabelAndTheLink() throws {
        let line = linkify("\(path):42.") { $0 == self.path }
        XCTAssertTrue(line.hasPrefix("[\(path):42]("), line)
        XCTAssertTrue(line.hasSuffix(")."))
        let lineStyled = IDEAgentFormat.markdown(line)
        XCTAssertEqual(String(lineStyled.characters), "\(path):42.")
        XCTAssertEqual(try XCTUnwrap(IDEAgentFileLinks.reference(from: try XCTUnwrap(lineStyled.runs.compactMap(\.link).first))).line, 42)

        let column = linkify("at \(path):12:8: cannot find symbol") { $0 == self.path }
        XCTAssertTrue(column.hasPrefix("at [\(path):12:8]("), column)
        XCTAssertTrue(column.hasSuffix(": cannot find symbol"))
        let columnReference = try XCTUnwrap(IDEAgentFileLinks.reference(from: try XCTUnwrap(urlInMarkdown(column))))
        XCTAssertEqual(columnReference.line, 12)
        XCTAssertEqual(columnReference.column, 8)

        let range = linkify("\(path):3-19") { $0 == self.path }
        let rangeReference = try XCTUnwrap(IDEAgentFileLinks.reference(from: try XCTUnwrap(urlInMarkdown(range))))
        XCTAssertEqual(rangeReference, IDEAgentFileLinks.Reference(path: path, line: 3, column: nil))
        XCTAssertEqual(String(IDEAgentFormat.markdown(range).characters), "\(path):3-19")
    }

    func testUnderscoresInTheNameSurviveMarkdownAndADotSlashIsDroppedFromThePath() throws {
        let named = "src/my_file_name.java"
        let styled = IDEAgentFormat.markdown(linkify(named) { $0 == named })
        XCTAssertEqual(String(styled.characters), named)
        XCTAssertEqual(try XCTUnwrap(IDEAgentFileLinks.reference(from: try XCTUnwrap(styled.runs.compactMap(\.link).first))).path, named)

        let dotted = linkify("./src/Foo.java:4") { $0 == "src/Foo.java" }
        XCTAssertTrue(dotted.hasPrefix("[./src/Foo.java:4]("), dotted)
        XCTAssertEqual(try XCTUnwrap(IDEAgentFileLinks.reference(from: try XCTUnwrap(urlInMarkdown(dotted)))).path, "src/Foo.java")
    }

    func testAMissingFileCodeAURLAndALinkAlreadyWrittenStayAsTheyWere() {
        let missing = "(\(path))"
        var lookedUp: [String] = []
        XCTAssertEqual(linkify(missing) { lookedUp.append($0); return false }, missing)
        XCTAssertEqual(lookedUp, [path])

        let coded = "Run `\(path):12` then open \(path) please"
        let linked = linkify(coded) { $0 == self.path }
        XCTAssertTrue(linked.hasPrefix("Run `\(path):12` then open ["), linked)
        XCTAssertEqual(linked.components(separatedBy: "umbra-file://").count - 1, 1)

        let url = "https://example.com/src/Foo.java"
        XCTAssertEqual(linkify(url) { _ in true }, url)
        let existing = "See [the docs](https://example.com/src/Foo.java) and src/Foo.java"
        let rewritten = linkify(existing) { $0 == "src/Foo.java" }
        XCTAssertTrue(rewritten.contains("[the docs](https://example.com/src/Foo.java)"))
        XCTAssertEqual(rewritten.components(separatedBy: "umbra-file://").count - 1, 1)

        XCTAssertEqual(linkify("**src/Foo.java**") { $0 == "src/Foo.java" }.hasPrefix("**[src/Foo.java]("), true)
    }

    func testAPathThatLeavesTheProjectOrHasNoFileIsNotALink() {
        var lookups = 0
        let untouched = "../secret/Foo.java and src/../../etc/passwd.java and /tmp/src/Foo.java and LongArrayLock.java and src/main/java"
        XCTAssertEqual(linkify(untouched) { _ in lookups += 1; return true }, untouched)
        XCTAssertEqual(lookups, 0, "those are not citations, so nothing is looked up")
        XCTAssertEqual(linkify("src/My File.java") { _ in true }, "src/My File.java")
    }

    func testResolveFindsAFileStripsTheProjectFolderAndRefusesToLeaveIt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-links-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("perkeo")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("src/main/java/com/balatro/LongArrayLock.java")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "class LongArrayLock {}\n".write(to: file, atomically: true, encoding: .utf8)
        let outside = base.appendingPathComponent("secret/Foo.java")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nope".write(to: outside, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("src/Notes.java")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let found = try XCTUnwrap(IDEAgentFileLinks.resolve(path, under: root))
        XCTAssertEqual(found.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(IDEAgentFileLinks.resolve("src/main/java/com/balatro/LongArrayLock.java", under: root)?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(IDEAgentFileLinks.resolve("./src/main/java/com/balatro/LongArrayLock.java", under: root)?.standardizedFileURL, file.standardizedFileURL)
        // The folder on disk is `perkeo`; the model may not match its case.
        XCTAssertNotNil(IDEAgentFileLinks.resolve("Perkeo/src/main/java/com/balatro/LongArrayLock.java", under: root))
        XCTAssertNil(IDEAgentFileLinks.resolve("src/Notes.java", under: root), "a directory is not a file")
        XCTAssertNil(IDEAgentFileLinks.resolve("no/Such.java", under: root))
        XCTAssertNil(IDEAgentFileLinks.resolve("../secret/Foo.java", under: root))
        XCTAssertNil(IDEAgentFileLinks.resolve("src/../../secret/Foo.java", under: root))
        XCTAssertNil(IDEAgentFileLinks.resolve("/etc/passwd", under: root))

        let nested = root.appendingPathComponent("perkeo/src/main/java/com/balatro/LongArrayLock.java")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nested".write(to: nested, atomically: true, encoding: .utf8)
        XCTAssertEqual(IDEAgentFileLinks.resolve(path, under: root)?.standardizedFileURL, nested.standardizedFileURL, "a real nested file wins over stripping the folder name")
    }

    func testALineRangeClampsToTheText() {
        let text = "alpha\nbeta\ngamma\n"
        XCTAssertEqual(IDEWorkspace.utf16Range(ofLine: 2, column: 3, in: text), NSRange(location: 8, length: 0))
        XCTAssertEqual(IDEWorkspace.utf16Range(ofLine: 99, column: 1, in: text), NSRange(location: 11, length: 0))
        XCTAssertEqual(IDEWorkspace.utf16Range(ofLine: 2, column: 100, in: text), NSRange(location: 10, length: 0))
        XCTAssertEqual(IDEWorkspace.utf16Range(ofLine: 1, column: 1, in: ""), NSRange(location: 0, length: 0))
    }

    func testClickingACitationOpensTheFileAtThatLineAndKeepsADirtyBuffer() async throws {
        let wasPersistent = IDEWorkspace.isSessionPersistenceEnabled
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = wasPersistent }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-link-open-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let project = base.appendingPathComponent("perkeo")
        let file = project.appendingPathComponent("src/main/java/com/balatro/LongArrayLock.java")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = "class LongArrayLock {\n    void hold() {\n        return;\n    }\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let workspace = IDEWorkspace()
        defer {
            workspace.teardown()
            try? FileManager.default.removeItem(at: base)
        }
        workspace.project.setRoot(project)
        workspace.bootstrap()

        await workspace.openAgentCitedFile(IDEAgentFileLinks.Reference(path: "src/Missing.java", line: 1, column: nil))
        XCTAssertNil(workspace.workbench.activePane.selectedDocument)

        await workspace.openAgentCitedFile(IDEAgentFileLinks.Reference(path: path, line: 2, column: 5))
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        let onLineTwo = IDEWorkspace.utf16Range(ofLine: 2, column: 5, in: source)
        XCTAssertEqual(document.url?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(document.selectedRange, onLineTwo)
        XCTAssertEqual(host.textView.selectedRange, onLineTwo)

        await workspace.openAgentCitedFile(IDEAgentFileLinks.Reference(path: "src/main/java/com/balatro/LongArrayLock.java", line: 4, column: 1))
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.id, document.id, "the open tab is focused, not loaded again")
        let onLineFour = IDEWorkspace.utf16Range(ofLine: 4, column: 1, in: source)
        XCTAssertEqual(host.textView.selectedRange, onLineFour)

        let dirty = source + "// cited\n"
        host.textView.text = dirty
        await workspace.openAgentCitedFile(IDEAgentFileLinks.Reference(path: path, line: 6, column: 3))
        let inBuffer = IDEWorkspace.utf16Range(ofLine: 6, column: 3, in: dirty)
        XCTAssertNotEqual(inBuffer, IDEWorkspace.utf16Range(ofLine: 6, column: 3, in: source))
        XCTAssertEqual(host.textView.selectedRange, inBuffer, "the caret uses the unsaved text")
    }

    private func urlInMarkdown(_ markdown: String) -> URL? {
        IDEAgentFormat.markdown(markdown).runs.compactMap(\.link).first
    }
}
