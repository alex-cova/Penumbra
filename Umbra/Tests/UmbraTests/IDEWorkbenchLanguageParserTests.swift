import EditorIntelligence
import XCTest
@testable import Umbra

/// F19: the workbench's index parser keeps one parser per language, so an edited document is
/// reparsed against its previous tree instead of from scratch.
final class IDEWorkbenchLanguageParserTests: XCTestCase {
    private func document(_ text: String, id: DocumentID, language: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).x"),
            displayName: "x",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 1, height: 1),
            languageIdentifier: language
        )
    }

    private func signature(_ tree: SyntaxTree) -> [String] {
        tree.symbols.map { "\($0.name)|\($0.kind)|\($0.range.start.utf16Offset)-\($0.range.end.utf16Offset)" }
            + ["words:" + tree.words.joined(separator: ",")] + ["imports:" + tree.imports.joined(separator: ",")]
    }

    func testRepeatedPassesOverEditedDocumentsMatchFreshParsers() async {
        let shared = IDEWorkbenchLanguageParser()
        let javaID = DocumentID()
        let tsID = DocumentID()
        var java = "package a;\nimport java.util.List;\npublic class A {\n  int f() { return 1; }\n}\n"
        var ts = "import { x } from 'y';\nexport function run(a: number) { return a + 1; }\n"
        for step in 0 ..< 12 {
            java = java.replacingOccurrences(of: "return \(step == 0 ? 1 : step)", with: "return \(step + 1)")
                + (step % 3 == 0 ? "// \(step)\n" : "")
            ts += step % 2 == 0 ? "const v\(step) = '日本\(step)';\n" : ""
            for (id, text, language) in [(javaID, java, "java"), (tsID, ts, "typescript")] {
                let actual = await shared.parse(document: document(text, id: id, language: language))
                let fresh = await IDEWorkbenchLanguageParser().parse(document: document(text, id: id, language: language))
                XCTAssertEqual(signature(actual), signature(fresh), "\(language) step \(step)")
                XCTAssertTrue(actual.symbols.contains { $0.name == "A" || $0.name == "run" }, "\(language) produced no symbols")
            }
        }
    }

    func testAnUnknownLanguageStillGetsWords() async {
        let tree = await IDEWorkbenchLanguageParser().parse(document: document("alpha beta gamma", id: DocumentID(), language: "no-such-language"))
        XCTAssertTrue(tree.symbols.isEmpty)
        XCTAssertTrue(tree.words.contains("alpha"))
    }
}
