import EditorIntelligence
import XCTest
@testable import SwiftIntelligence

final class SwiftImportOrganizerTests: XCTestCase {
    private func organized(_ source: String) -> String {
        var result = source as NSString
        for edit in SwiftImportOrganizer.edits(in: source).sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }

    func testSortsDedupesAndGroupsTestableImports() {
        let source = """
        // File header.

        import Zoo
        import App
        @testable import Tests
        import App
        import struct Swift.Int

        struct Box {}
        """
        XCTAssertEqual(organized(source), """
        // File header.

        import App
        import struct Swift.Int
        import Zoo

        @testable import Tests

        struct Box {}
        """)
    }

    func testAnOrganizedFileIsLeftAlone() {
        let source = """
        import App
        import Zoo

        @testable import Tests

        struct Box {}
        """
        XCTAssertTrue(SwiftImportOrganizer.edits(in: source).isEmpty)
    }

    func testACommentInTheBlockIsLeftAlone() {
        let source = """
        import Zoo
        // keep this with Zoo
        import App

        struct Box {}
        """
        XCTAssertTrue(SwiftImportOrganizer.edits(in: source).isEmpty)
    }

    func testAFileWithoutImportsIsLeftAlone() {
        XCTAssertTrue(SwiftImportOrganizer.edits(in: "struct Box {}\n").isEmpty)
    }

    func testOrganizeImportsIsTheCodeAction() async {
        let source = "import Zoo\nimport App\nstruct Box {}\n"
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            displayName: "Box.swift",
            contentSnapshot: TextSnapshot(version: 1, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "swift"
        )
        let actions = await SwiftCodeActionProvider().codeActions(for: document, at: position, diagnostics: [])
        let action = actions.first
        XCTAssertEqual(action?.title, "Organize Imports")
        XCTAssertEqual(action?.kind, CodeAction.organizeImportsKind)
        XCTAssertEqual(action?.edits.count, 1)
        XCTAssertEqual(organized(source), "import App\nimport Zoo\nstruct Box {}\n")
    }
}
