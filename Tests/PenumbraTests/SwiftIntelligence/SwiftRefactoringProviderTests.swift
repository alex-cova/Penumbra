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
        XCTAssertEqual(namesOnName, ["Change Function Signature…", "Safe Delete"])
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

    func testExtractMethodIsOfferedAndPlansWithTheSuggestedName() async throws {
        let marked = SwiftRefactoringTests.parse("func f(items: [Int]) -> Int {\n    ⟦let total: Int = items.count\n    print(total)⟧\n    return total\n}\n")
        let (provider, document, url) = try await provider(files: [:], open: "A.swift", noting: marked)
        let available = await provider.availableRefactorings(context(document))
        let descriptor = try XCTUnwrap(available.first { $0.id == .extractMethod })
        XCTAssertEqual(descriptor.title, "Extract Method…")
        XCTAssertTrue(descriptor.requiresSelection)
        XCTAssertEqual(descriptor.parameterKeys, ["name"])
        let name = try XCTUnwrap(descriptor.suggestedParameters["name"])
        let plan = try await provider.plan(.extractMethod, context: context(document), parameters: ["name": name])
        XCTAssertNil(plan.blockingError, plan.blockingError ?? "")
        XCTAssertEqual(
            applied(plan, to: url, text: marked.text),
            "func f(items: [Int]) -> Int {\n    let total = \(name)(items)\n    return total\n}\nprivate func \(name)(_ items: [Int]) -> Int {\n    let total: Int = items.count\n    print(total)\n    return total\n}\n"
        )
    }

    func testExtractMethodRefusalBecomesABlockingError() async throws {
        let marked = SwiftRefactoringTests.parse("func f() {\n    var a = 0\n    ⟦a⟧ = 1\n}\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let available = await provider.availableRefactorings(context(document))
        XCTAssertNil(available.first { $0.id == .extractMethod })
        let plan = try await provider.plan(.extractMethod, context: context(document), parameters: ["name": "extracted"])
        XCTAssertEqual(plan.blockingError, "Cannot extract an assignment target.")
        XCTAssertTrue(plan.entries.isEmpty)
    }

    // MARK: - Change signature across files

    private func parametersJSON(of document: Document, at marked: SwiftRefactoringTests.Marked, _ transform: (inout [SwiftSignatureParameter]) -> Void) -> String {
        let subject = SwiftChangeSignature.subject(in: marked.text, caret: marked.caret)!
        var parameters = subject.parameters
        transform(&parameters)
        return SwiftSignatureChange(parameters: parameters).json
    }

    func testTheMenuOffersTheParameterListToEdit() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸scale(by factor: Int, _ x: Double = 1) {}\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let available = await provider.availableRefactorings(context(document))
        let descriptor = try XCTUnwrap(available.first { $0.id == .changeSignature })
        XCTAssertEqual(descriptor.parameterKeys, ["parameters"])
        let list = try XCTUnwrap(SwiftSignatureChange(json: descriptor.suggestedParameters["parameters"]))
        XCTAssertEqual(list.parameters.map(\.label), ["by", "_"])
        XCTAssertEqual(list.parameters.map(\.defaultValue), ["", "1"])
    }

    func testReorderingEditsTheDeclarationAndTheCallsInOtherFiles() async throws {
        let marked = SwiftRefactoringTests.parse("struct Greeter {\n    func ‸greet(name: String, times: Int) -> String { name }\n}\n")
        let useURL = root.appendingPathComponent("Use.swift")
        let use = "func use(g: Greeter) -> String { g.greet(name: \"a\", times: 2) + g.greet(name: \"b\", times: 3) }\n"
        let (provider, document, url) = try await provider(files: ["Use.swift": use], open: "Greeter.swift", noting: marked)
        let json = parametersJSON(of: document, at: marked) { $0.reverse() }
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": json])
        XCTAssertNil(plan.blockingError, plan.blockingError ?? "")
        XCTAssertEqual(applied(plan, to: url, text: marked.text), "struct Greeter {\n    func greet(times: Int, name: String) -> String { name }\n}\n")
        XCTAssertEqual(applied(plan, to: useURL, text: use), "func use(g: Greeter) -> String { g.greet(times: 2, name: \"a\") + g.greet(times: 3, name: \"b\") }\n")
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    func testAddingAParameterWithADefaultLeavesTheCallsAlone() async throws {
        let marked = SwiftRefactoringTests.parse("struct Greeter {\n    func ‸greet(name: String) -> String { name }\n}\n")
        let (provider, document, url) = try await provider(
            files: ["Use.swift": "func use(g: Greeter) -> String { g.greet(name: \"a\") }\n"], open: "Greeter.swift", noting: marked
        )
        let json = parametersJSON(of: document, at: marked) { $0.append(.init(label: "loud", name: "loud", type: "Bool", defaultValue: "false")) }
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": json])
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(
            applied(plan, to: url, text: marked.text),
            "struct Greeter {\n    func greet(name: String, loud: Bool = false) -> String { name }\n}\n"
        )
        XCTAssertEqual(plan.entries.count, 1, "the call is valid as it is")
    }

    func testRemovingAParameterRewritesEveryCallAndAProtocolsConformers() async throws {
        let marked = SwiftRefactoringTests.parse("protocol Greeter {\n    func ‸greet(name: String, times: Int) -> String\n}\n")
        let impl = "struct Polite: Greeter {\n    func greet(name: String, times: Int) -> String { name }\n}\nfunc use(g: Greeter) -> String { g.greet(name: \"a\", times: 2) }\n"
        let implURL = root.appendingPathComponent("Polite.swift")
        let (provider, document, url) = try await provider(files: ["Polite.swift": impl], open: "Greeter.swift", noting: marked)
        let json = parametersJSON(of: document, at: marked) { $0.removeLast() }
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": json])
        XCTAssertNil(plan.blockingError, plan.blockingError ?? "")
        XCTAssertEqual(applied(plan, to: url, text: marked.text), "protocol Greeter {\n    func greet(name: String) -> String\n}\n")
        XCTAssertEqual(
            applied(plan, to: implURL, text: impl),
            "struct Polite: Greeter {\n    func greet(name: String) -> String { name }\n}\nfunc use(g: Greeter) -> String { g.greet(name: \"a\") }\n"
        )
    }

    func testAParameterTheBodyUsesCannotBeRemoved() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸scale(a: Int, by factor: Int) -> Int { a * factor }\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let json = parametersJSON(of: document, at: marked) { $0.removeLast() }
        let plan = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": json])
        XCTAssertNotNil(plan.blockingError)
    }

    func testNothingToChangeAndNonsenseAreBlocked() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸scale(a: Int) -> Int { a }\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let same = parametersJSON(of: document, at: marked) { _ in }
        let unchanged = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": same])
        XCTAssertEqual(unchanged.blockingError, "Nothing to change.")
        let missing = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": "nonsense"])
        XCTAssertNotNil(missing.blockingError)
        let noValue = parametersJSON(of: document, at: marked) { $0.append(.init(label: "b", name: "b", type: "Int")) }
        let blocked = try await provider.plan(.changeSignature, context: context(document), parameters: ["parameters": noValue])
        XCTAssertTrue(blocked.blockingError?.contains("default") ?? false, "\(blocked.blockingError ?? "")")
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

    func testCodeActionsOfferExtractMethodUntilSourceKitDoes() async throws {
        let marked = SwiftRefactoringTests.parse("func f(items: [Int]) -> Int {\n    ⟦let total: Int = items.count\n    print(total)⟧\n    return total\n}\n")
        let (_, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let native = await SwiftCodeActionProvider().codeActions(for: document, at: document.cursor.position, diagnostics: [])
        let offered = try XCTUnwrap(native.first { $0.title.hasPrefix("Extract method") })
        XCTAssertEqual(offered.kind, "refactor.rewrite")
        XCTAssertFalse(offered.edits.isEmpty)
        let quiet = await SwiftCodeActionProvider(sourceKitOffersCodeActions: { true })
            .codeActions(for: document, at: document.cursor.position, diagnostics: [])
        XCTAssertNil(quiet.first { $0.title.hasPrefix("Extract method") }, "\(quiet.map(\.title))")
        // Everything else stays: only the server-twinned entry hides.
        XCTAssertEqual(Set(quiet.map(\.title)), Set(native.map(\.title)).subtracting([offered.title]))
    }

    // MARK: - Safe delete

    func testSafeDeleteIsOfferedDeletesTheUnusedAndBlocksOnUsages() async throws {
        let marked = SwiftRefactoringTests.parse("func ‸orphan() {}\n")
        let (provider, document, url) = try await provider(files: [:], open: "A.swift", noting: marked)
        let titles = await provider.availableRefactorings(context(document)).map(\.title)
        XCTAssertTrue(titles.contains("Safe Delete"), "\(titles)")
        let plan = try await provider.plan(.safeDelete, context: context(document), parameters: [:])
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(applied(plan, to: url, text: marked.text), "")

        let used = SwiftRefactoringTests.parse("func ‸orphan() {}\n")
        let (using, usingDocument, _) = try await self.provider(
            files: ["B.swift": "func caller() { orphan() }\n"], open: "A.swift", noting: used
        )
        let blocked = try await using.plan(.safeDelete, context: context(usingDocument), parameters: [:])
        XCTAssertEqual(blocked.blockingError, "1 usage in B.swift blocks safe delete.")
        XCTAssertTrue(blocked.entries.isEmpty)
    }

    func testSafeDeleteRefusalsBecomeBlockingErrors() async throws {
        let marked = SwiftRefactoringTests.parse("class B { func f() {} }\nclass D: B {\n    override func ‸f() {}\n}\n")
        let (provider, document, _) = try await provider(files: [:], open: "A.swift", noting: marked)
        let plan = try await provider.plan(.safeDelete, context: context(document), parameters: [:])
        XCTAssertEqual(plan.blockingError, "'f' overrides another declaration.")
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
