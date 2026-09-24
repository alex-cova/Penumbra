import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaCodeActionProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let cannotFind = """
    cannot find symbol
      symbol:   class ArrayList
      location: class T
    """

    func testOffersEveryImportCandidateForAnUnresolvedClass() async throws {
        let provider = try await makeProvider(sources: [
            ("java/util/ArrayList.java", "package java.util; public class ArrayList { }"),
            ("org/acme/ArrayList.java", "package org.acme; public class ArrayList { }"),
            ("org/hidden/ArrayList.java", "package org.hidden; class ArrayList { }")
        ])
        let source = "class T {\n    ArrayList<String> names;\n}\n"
        let actions = await provider.codeActions(
            for: document(source, caretAt: "ArrayList"), at: position(of: "ArrayList", in: source),
            diagnostics: [diagnostic(cannotFind, line: 1, column: 4)]
        )
        XCTAssertEqual(actions.map(\.title), ["Import 'java.util.ArrayList'", "Import 'org.acme.ArrayList'"])
        XCTAssertEqual(actions.map(\.isPreferred), [true, false])
        XCTAssertEqual(apply(actions[0], to: source), "import java.util.ArrayList;\n\nclass T {\n    ArrayList<String> names;\n}\n")
    }

    func testImportIsInsertedInSortedPositionAmongExistingImports() async throws {
        let provider = try await makeProvider(sources: [("java/util/ArrayList.java", "package java.util; public class ArrayList { }")])
        let source = "package demo;\n\nimport java.io.File;\nimport java.util.Set;\n\nclass T {\n    ArrayList<File> a; Set<File> s;\n}\n"
        let actions = await provider.codeActions(
            for: document(source, caretAt: "ArrayList"), at: position(of: "ArrayList", in: source),
            diagnostics: [diagnostic(cannotFind, line: 6, column: 4)]
        )
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(
            apply(action, to: source),
            "package demo;\n\nimport java.io.File;\nimport java.util.ArrayList;\nimport java.util.Set;\n\nclass T {\n    ArrayList<File> a; Set<File> s;\n}\n"
        )
    }

    func testDiagnosticsOnOtherLinesAreIgnored() async throws {
        let provider = try await makeProvider(sources: [("java/util/ArrayList.java", "package java.util; public class ArrayList { }")])
        let source = "class T {\n    int a;\n    ArrayList<String> names;\n}\n"
        let actions = await provider.codeActions(
            for: document(source, caretAt: "int a"), at: position(of: "int a", in: source),
            diagnostics: [diagnostic(cannotFind, line: 2, column: 4)]
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func testOfferedOrganizeImportsWhenSomeImportIsUnused() async throws {
        let provider = try await makeProvider(sources: [])
        let source = "import java.util.List;\nimport java.util.Set;\n\nclass T { Set<String> s; }\n"
        let actions = await provider.codeActions(
            for: document(source, caretAt: "class"), at: position(of: "class", in: source), diagnostics: []
        )
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.kind, CodeAction.organizeImportsKind)
        XCTAssertEqual(action.title, "Optimize imports (remove 1 unused)")
        XCTAssertEqual(apply(action, to: source), "import java.util.Set;\n\nclass T { Set<String> s; }\n")
    }

    func testOnlySortingIsOfferedAsSortImports() async throws {
        let provider = try await makeProvider(sources: [])
        let source = "import java.util.Set;\nimport java.io.File;\n\nclass T { Set<String> s; File f; }\n"
        let actions = await provider.codeActions(
            for: document(source, caretAt: "class"), at: position(of: "class", in: source), diagnostics: []
        )
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.title, "Sort imports")
        XCTAssertEqual(apply(action, to: source), "import java.io.File;\nimport java.util.Set;\n\nclass T { Set<String> s; File f; }\n")
    }

    func testNoActionsWhenNothingIsWrongOrForOtherLanguages() async throws {
        let provider = try await makeProvider(sources: [])
        let clean = "import java.util.Set;\n\nclass T { Set<String> s; }\n"
        let none = await provider.codeActions(
            for: document(clean, caretAt: "class"), at: position(of: "class", in: clean), diagnostics: []
        )
        XCTAssertTrue(none.isEmpty)
        let other = await provider.codeActions(
            for: document("import java.util.List;\n", caretAt: "import", language: "swift"),
            at: position(of: "import", in: "import java.util.List;\n"), diagnostics: []
        )
        XCTAssertTrue(other.isEmpty)
    }

    func testAddOverrideQuickFixForMissingOverrideInspection() async throws {
        let provider = try await makeProvider(sources: [("Base.java", "class Base { void run() { } }")])
        let source = "class Child extends Base { void run() { } }"
        let runOffset = (source as NSString).range(of: "run").location
        let start = TextPosition(line: 0, column: runOffset, utf16Offset: runOffset)
        let end = TextPosition(line: 0, column: runOffset + 3, utf16Offset: runOffset + 3)
        let diagnostic = Diagnostic(
            severity: .warning, message: "missing override", range: TextRange(start: start, end: end),
            source: "java-inspection", code: "missing-override"
        )
        let actions = await provider.codeActions(
            for: document(source, caretAt: "void run"), at: position(of: "void run", in: source), diagnostics: [diagnostic]
        )
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.title, "Add @Override")
        XCTAssertTrue(apply(action, to: source).contains("@Override"))
    }

    func testSymbolClassNameParsing() {
        XCTAssertEqual(JavaCodeActionProvider.symbolClassName(in: cannotFind), "ArrayList")
        XCTAssertNil(JavaCodeActionProvider.symbolClassName(in: "cannot find symbol\n  symbol:   variable foo"))
    }

    // MARK: - Helpers

    private func makeProvider(sources: [(path: String, source: String)]) async throws -> JavaCodeActionProvider {
        var stubs: [JavaClassStub] = []
        for (path, source) in sources {
            let url = scratch.appendingPathComponent("src/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: url).classes)
        }
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return JavaCodeActionProvider(index: index)
    }

    private func position(of marker: String, in source: String) -> TextPosition {
        let offset = (source as NSString).range(of: marker).location
        return JavaNavigationText.position(utf16Offset: offset, in: source)
    }

    private func document(_ source: String, caretAt marker: String, language: String = "java") -> Document {
        let caret = position(of: marker, in: source)
        return Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: caret, end: caret)),
            cursor: Cursor(position: caret),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func diagnostic(_ message: String, line: Int, column: Int) -> Diagnostic {
        let start = TextPosition(line: line, column: column, utf16Offset: column)
        let end = TextPosition(line: line, column: column + 9, utf16Offset: column + 9)
        return Diagnostic(severity: .error, message: message, range: TextRange(start: start, end: end), source: "javac")
    }

    private func apply(_ action: CodeAction, to source: String) -> String {
        var result = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }
}
