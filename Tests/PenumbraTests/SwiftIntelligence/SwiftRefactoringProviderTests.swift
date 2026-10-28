import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// The refactorings as the editor reaches them: the provider's menu and plans, change signature across
/// files, and the ⌥↩ actions.
final class SwiftRefactoringProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftRefactor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func document(_ marked: SwiftRefactoringTests.Marked, url: URL) -> Document {
        let map = SourceTextMap(marked.text)
        let caret = map.position(atByte: marked.caret)
        let range = marked.selection.map { EditorIntelligence.TextRange(start: map.position(atByte: $0.lowerBound), end: map.position(atByte: $0.upperBound)) }
            ?? EditorIntelligence.TextRange(start: caret, end: caret)
        return Document(
            url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 0, text: marked.text),
            selection: Selection(range: range), cursor: Cursor(position: caret),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "swift"
        )
    }

    private func context(_ document: Document) -> RefactoringContext {
        RefactoringContext(document: document, cursor: document.cursor, selection: document.selection)
    }

    private func provider(files: [String: String], open: String, noting marked: SwiftRefactoringTests.Marked) async throws -> (SwiftRefactoringProvider, Document, URL) {
        for (name, text) in files { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let url = root.appendingPathComponent(open)
        try marked.text.write(to: url, atomically: true, encoding: .utf8)
        let index = SwiftIndex()
        await index.setRoot(root)
        await index.noteOpenDocument(url: url, text: marked.text)
        return (SwiftRefactoringProvider(index: index), document(marked, url: url), url)
    }

    private func applied(_ plan: WorkspaceEditPlan, to url: URL, text: String) -> String {
        let map = SourceTextMap(text)
        var bytes = Array(text.utf8)
        let edits = plan.entries.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
            .map { (map.byteOffset(utf16: $0.range.start.utf16Offset) ..< map.byteOffset(utf16: $0.range.end.utf16Offset), $0.newText) }
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: Array(replacement.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Menu

    func testTheMenuOffersWhatAppliesAtTheCaretAndTheSelection() async throws {
        let selected = SwiftRefactoringTests.parse("func f(a: Int, b: Int) -> Int {\n    let y = ⟦a * b⟧\n    return y\n}\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: selected)
        let titles = await provider.availableRefactorings(context(document)).map(\.title)
        XCTAssertTrue(titles.contains("Introduce Variable…"), "\(titles)")
        XCTAssertTrue(titles.contains("Change Function Signature…") == false, "the caret is in the body")

        let onName = SwiftRefactoringTests.parse("func ‸run(a: Int) {}\n")
        let (second, secondDocument, _) = try await self.provider(files: [:], open: "B.swift", noting: onName)
        let namesOnName = await second.availableRefactorings(context(secondDocument)).map(\.title)
        XCTAssertEqual(namesOnName, ["Change Function Signature…"])
    }

    func testIntroduceVariablePlansWithTheSuggestedName() async throws {
        let marked = SwiftRefactoringTests.parse("func f(a: Int) {\n    print(⟦a * 2⟧)\n}\n")
        let (provider, document, url) = try await provider(files: [:], open: "A.swift", noting: marked)
        let available = await provider.availableRefactorings(context(document))
        let descriptor = try XCTUnwrap(available.first { $0.id == .extractVariable })
        let name = try XCTUnwrap(descriptor.suggestedParameters["name"])
        let plan = try await provider.plan(.extractVariable, context: context(document), parameters: ["name": name])
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(applied(plan, to: url, text: marked.text), "func f(a: Int) {\n    let result = a * 2\n    print(result)\n}\n")
    }

    func testARefusalBecomesABlockingError() async throws {
        let marked = SwiftRefactoringTests.parse("func f(a: Int?) -> Bool {\n    return a != nil && ⟦a!.isMultiple(of: 2)⟧\n}\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let plan = try await provider.plan(.extractVariable, context: context(document), parameters: ["name": "x"])
        XCTAssertNotNil(plan.blockingError)
        XCTAssertTrue(plan.entries.isEmpty)
    }

    // MARK: - Change signature across files

    func testAddingAParameterEditsTheDeclarationAndKeepsCallsInOtherFilesValid() async throws {
        let marked = SwiftRefactoringTests.parse("struct Greeter {\n    func ‸greet(name: String) -> String { \"Hi \" + name }\n}\n")
        let (provider, document, url) = try await provider(
            files: ["Use.swift": "func use(g: Greeter) -> String { g.greet(name: \"a\") }\n"], open: "Greeter.swift", noting: marked
        )
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: [
            "newName": "greet", "addParameterName": "loud", "addParameterType": "Bool", "addParameterDefault": "false",
        ])
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(
            applied(plan, to: url, text: marked.text),
            "struct Greeter {\n    func greet(name: String, loud: Bool = false) -> String { \"Hi \" + name }\n}\n"
        )
        XCTAssertEqual(plan.entries.count, 1, "the call is valid as it is")
    }

    func testRemovingTheLastParameterRewritesEveryCall() async throws {
        let marked = SwiftRefactoringTests.parse("struct Greeter {\n    func ‸greet(name: String, times: Int) -> String { name }\n}\n")
        let useURL = root.appendingPathComponent("Use.swift")
        let use = "func use(g: Greeter) -> String { g.greet(name: \"a\", times: 2) + g.greet(name: \"b\", times: 3) }\n"
        let (provider, document, url) = try await provider(files: ["Use.swift": use], open: "Greeter.swift", noting: marked)
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: [
            "newName": "greet", "removeLastParameter": "true",
        ])
        XCTAssertNil(plan.blockingError, plan.blockingError ?? "")
        XCTAssertEqual(applied(plan, to: url, text: marked.text), "struct Greeter {\n    func greet(name: String) -> String { name }\n}\n")
        XCTAssertEqual(applied(plan, to: useURL, text: use), "func use(g: Greeter) -> String { g.greet(name: \"a\") + g.greet(name: \"b\") }\n")
    }

    func testAParameterTheBodyUsesCannotBeRemoved() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸scale(a: Int, by factor: Int) -> Int { a * factor }\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["newName": "scale", "removeLastParameter": "true"])
        XCTAssertNotNil(plan.blockingError)
    }

    func testRenamingIsLeftToRename() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸scale(a: Int) -> Int { a }\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["newName": "resize", "addParameterName": "b", "addParameterType": "Int", "addParameterDefault": "0"])
        XCTAssertNotNil(plan.blockingError)
    }

    // MARK: - ⌥↩

    func testCodeActionsOfferTheRefactoringsThatNeedNoInput() async throws {
        let marked = SwiftRefactoringTests.parse("func f(x: Int?) {\n    let ‸label = \"a\"\n    print(label)\n}\n")
        let (_, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let actions = await SwiftCodeActionProvider().codeActions(for: document, at: document.cursor.position, diagnostics: [])
        let titles = actions.map(\.title)
        XCTAssertTrue(titles.contains("Add explicit type"), "\(titles)")
        XCTAssertTrue(titles.contains("Inline variable"), "\(titles)")
        let add = try XCTUnwrap(actions.first { $0.title == "Add explicit type" })
        XCTAssertEqual(add.kind, "refactor.rewrite")
        XCTAssertEqual(add.edits.first?.replacement, ": String")

        let selected = SwiftRefactoringTests.parse("func f(a: Int) {\n    print(⟦a * 2⟧)\n}\n")
        let (_, selectedDocument, _) = try await provider(files: [:], open: "B.swift", noting: selected)
        let selectedActions = await SwiftCodeActionProvider().codeActions(for: selectedDocument, at: selectedDocument.cursor.position, diagnostics: [])
        XCTAssertTrue(selectedActions.map(\.title).contains("Introduce variable 'result'"), "\(selectedActions.map(\.title))")
    }

    func testNothingIsOfferedForAFileThatDoesNotParseOrIsNotSwift() async throws {
        let broken = SwiftRefactoringTests.parse("func f( {\n    let ‸label = \"a\"\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: broken)
        let none = await provider.availableRefactorings(context(document))
        XCTAssertTrue(none.isEmpty)
        let other = Document(
            url: URL(fileURLWithPath: "/tmp/x.txt"), displayName: "x.txt", contentSnapshot: TextSnapshot(version: 0, text: "let a = \"a\""),
            selection: document.selection, cursor: document.cursor, viewport: document.viewport, languageIdentifier: "plaintext"
        )
        let noneForOther = await provider.availableRefactorings(context(other))
        XCTAssertTrue(noneForOther.isEmpty)
    }
}
