import EditorIntelligence
import XCTest
@testable import Umbra

/// The router: which service answers for which language, and how services that share one combine.
final class LanguageServiceRegistryTests: XCTestCase {
    // MARK: Fakes

    private struct FakeFormatting: FormattingProviding {
        let tag: String
        var supports = true
        func supportsFormatting(_ document: Document) -> Bool { supports }
        func formatDocument(_ document: Document) async -> [TextEdit] { [edit(tag)] }
        func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] { [edit(tag + "-selection")] }
    }

    private struct FakeActions: CodeActionProviding {
        let titles: [String]
        func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
            titles.map { CodeAction(title: $0, edits: []) }
        }
    }

    private struct FakeSignatureHelp: SignatureHelpProviding {
        let signature: String?
        func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
            signature.map { ParameterHintsModel(signatures: [$0]) }
        }
    }

    private struct FakeRename: RenameProviding {
        let name: String
        func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
            RenameTarget(range: Self.range, currentName: name)
        }
        func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
            throw FakeError.thrownBy(name)
        }
        static let range = EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0), end: TextPosition(line: 0, column: 0, utf16Offset: 0)
        )
    }

    private struct FakeVision: CodeVisionProviding {
        let anchors: [Int]
        func codeVisionAnchors(for document: Document) async -> [Int] { anchors }
        func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] { [] }
    }

    private struct FakeCompletion: CompletionProvider {
        let name: String
        func provide(context: CompletionContext) async -> [CompletionItem] { [] }
    }

    private struct FakeTokens: SemanticTokenProviding {
        let name: String
        func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
            [SemanticHighlight(range: 0..<1, highlightName: name)]
        }
    }

    private struct FakeStructure: StructureProviding {
        let title: String
        func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
            StructureNode(id: title, title: title, kind: .type, nameRange: 0..<1, bodyRange: 0..<2)
        }
        func allStructure(forSource source: String) async -> [StructureNode]? { nil }
    }

    private enum FakeError: Error, Equatable { case thrownBy(String) }

    private static func edit(_ text: String) -> TextEdit {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: text)
    }

    private func document(_ language: String?) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: nil, displayName: "x",
            contentSnapshot: TextSnapshot(version: 0, text: ""),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func service(_ name: String, _ languages: Set<String>, _ providers: LanguageProviders,
                         policy: LanguagePolicy = .none) -> BasicLanguageService {
        BasicLanguageService(name: name, languageIdentifiers: languages, providers: providers, policy: policy)
    }

    // MARK: Lookup

    func testServicesAreFoundByIdentifierInRegistrationOrder() {
        let a = service("a", ["x", "y"], LanguageProviders())
        let b = service("b", ["y"], LanguageProviders())
        let registry = LanguageServiceRegistry(services: [a, b])
        XCTAssertEqual(registry.services(for: "x").map(\.name), ["a"])
        XCTAssertEqual(registry.services(for: "y").map(\.name), ["a", "b"])
        XCTAssertTrue(registry.services(for: "z").isEmpty)
        XCTAssertTrue(registry.services(for: nil).isEmpty)
    }

    func testPolicyNamesTheLanguagesThatOptedOut() {
        let registry = LanguageServiceRegistry(services: [
            service("java", ["java"], LanguageProviders(), policy: LanguagePolicy(disabling: [.snippets, .symbolHover])),
            service("http", ["http", "rest"], LanguageProviders(), policy: LanguagePolicy(disabling: [.snippets]))
        ])
        XCTAssertEqual(registry.identifiers(disabling: .snippets), ["java", "http", "rest"])
        XCTAssertEqual(registry.identifiers(disabling: .symbolHover), ["java"])
        XCTAssertEqual(registry.identifiers(disabling: .duplicateSymbolDiagnostics), [])
    }

    func testEngineProvidersAreAllServicesProvidersInServiceOrder() {
        let registry = LanguageServiceRegistry(services: [
            service("one", ["a"], LanguageProviders(completion: [FakeCompletion(name: "c1"), FakeCompletion(name: "c2")])),
            service("two", ["b"], LanguageProviders(completion: [FakeCompletion(name: "c3")]))
        ])
        XCTAssertEqual(registry.completionProviders.map(\.name), ["c1", "c2", "c3"])
    }

    // MARK: Routing

    func testFormattingGoesToTheFirstServiceThatSupportsTheDocument() async {
        let registry = LanguageServiceRegistry(services: [
            service("declines", ["x"], LanguageProviders(formatting: FakeFormatting(tag: "declines", supports: false))),
            service("takes", ["x"], LanguageProviders(formatting: FakeFormatting(tag: "takes"))),
            service("other", ["y"], LanguageProviders(formatting: FakeFormatting(tag: "other")))
        ])
        let formatting = registry.formatting
        XCTAssertTrue(formatting.supportsFormatting(document("x")))
        let whole = await formatting.formatDocument(document("x"))
        XCTAssertEqual(whole.map(\.replacement), ["takes"])
        let selection = await formatting.formatSelection(in: document("y"), range: FakeRename.range)
        XCTAssertEqual(selection.map(\.replacement), ["other-selection"])

        XCTAssertFalse(formatting.supportsFormatting(document("z")))
        XCTAssertFalse(formatting.supportsFormatting(document(nil)))
        let none = await formatting.formatDocument(document("z"))
        XCTAssertTrue(none.isEmpty)
    }

    func testCodeActionsOfServicesSharingALanguageAreConcatenatedInOrder() async {
        let registry = LanguageServiceRegistry(services: [
            service("first", ["x"], LanguageProviders(codeActions: FakeActions(titles: ["a", "b"]))),
            service("second", ["x"], LanguageProviders(codeActions: FakeActions(titles: ["c"]))),
            service("elsewhere", ["y"], LanguageProviders(codeActions: FakeActions(titles: ["no"])))
        ])
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let x = await registry.codeActions.codeActions(for: document("x"), at: position, diagnostics: [])
        XCTAssertEqual(x.map(\.title), ["a", "b", "c"])
        let none = await registry.codeActions.codeActions(for: document("z"), at: position, diagnostics: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testSignatureHelpIsTheFirstNonNilAnswer() async {
        let registry = LanguageServiceRegistry(services: [
            service("silent", ["x"], LanguageProviders(signatureHelp: FakeSignatureHelp(signature: nil))),
            service("helps", ["x"], LanguageProviders(signatureHelp: FakeSignatureHelp(signature: "f(a)"))),
            service("late", ["x"], LanguageProviders(signatureHelp: FakeSignatureHelp(signature: "g(b)")))
        ])
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let model = await registry.signatureHelp.signatureHelp(for: document("x"), at: position)
        XCTAssertEqual(model?.signatures, ["f(a)"])
        let none = await registry.signatureHelp.signatureHelp(for: document("y"), at: position)
        XCTAssertNil(none)
    }

    func testSingleOwnerFeaturesUseTheFirstServiceThatHasOne() async throws {
        let registry = LanguageServiceRegistry(services: [
            service("no-rename", ["x"], LanguageProviders()),
            service("owner", ["x"], LanguageProviders(rename: FakeRename(name: "owner"), codeVision: FakeVision(anchors: [1]))),
            service("second", ["x"], LanguageProviders(rename: FakeRename(name: "second"), codeVision: FakeVision(anchors: [2])))
        ])
        let context = NavigationContext(
            document: document("x"), cursor: document("x").cursor, selection: document("x").selection,
            trigger: .manual, kind: .definition
        )
        let target = await registry.rename.prepareRename(context)
        XCTAssertEqual(target?.currentName, "owner")
        do {
            _ = try await registry.rename.rename(context, to: "n")
            XCTFail("the owner's rename should have thrown")
        } catch let error as FakeError {
            XCTAssertEqual(error, .thrownBy("owner"))
        }
        let anchors = await registry.codeVision.codeVisionAnchors(for: document("x"))
        XCTAssertEqual(anchors, [1])
    }

    func testALanguageNobodyClaimsGetsNothing() async {
        let registry = LanguageServiceRegistry(services: [
            service("only-x", ["x"], LanguageProviders(rename: FakeRename(name: "x"), codeVision: FakeVision(anchors: [1])))
        ])
        let doc = document("y")
        let context = NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, trigger: .manual, kind: .definition)
        let target = await registry.rename.prepareRename(context)
        XCTAssertNil(target)
        do {
            _ = try await registry.rename.rename(context, to: "n")
            XCTFail("expected a routing error")
        } catch let error as LanguageRoutingError {
            XCTAssertEqual(error.languageIdentifier, "y")
        } catch {
            XCTFail("unexpected \(error)")
        }
        let anchors = await registry.codeVision.codeVisionAnchors(for: doc)
        XCTAssertTrue(anchors.isEmpty)
        let breadcrumbs = await registry.breadcrumbs.breadcrumbs(for: doc)
        XCTAssertNil(breadcrumbs)
        let hints = await registry.inlayHints.inlayHints(for: doc, in: FakeRename.range)
        XCTAssertTrue(hints.isEmpty)
    }

    func testCodeGenerationWithoutAnOwnerIsABlockedPlanNotACrash() async {
        let registry = LanguageServiceRegistry(services: [])
        let doc = document("y")
        let context = RefactoringContext(
            document: doc, cursor: doc.cursor, selection: doc.selection, workspace: nil, index: nil, documentURL: nil
        )
        let menu = await registry.codeGeneration.generationMenu(context)
        XCTAssertNil(menu)
        let plan = await registry.codeGeneration.generate(CodeGenerationKind("toString"), fieldNames: [], context: context)
        XCTAssertTrue(plan.isBlocked)
    }

    func testHostDrivenFeaturesComeFromTheFirstServiceThatHasOneForTheLanguage() async {
        let registry = LanguageServiceRegistry(services: [
            service("empty", ["x"], LanguageProviders()),
            service("first", ["x"], LanguageProviders(semanticTokens: FakeTokens(name: "first"), structure: FakeStructure(title: "first"))),
            service("second", ["x"], LanguageProviders(semanticTokens: FakeTokens(name: "second"))),
            service("elsewhere", ["y"], LanguageProviders(semanticTokens: FakeTokens(name: "y")))
        ])
        let tokens = await registry.semanticTokens(for: "x")?.semanticHighlights(forSource: "")
        XCTAssertEqual(tokens?.map(\.highlightName), ["first"])
        let structure = await registry.structure(for: "x")?.structure(forSource: "", atUTF16Offset: 0)
        XCTAssertEqual(structure?.title, "first")

        XCTAssertNil(registry.semanticTokens(for: "z"))
        XCTAssertNil(registry.semanticTokens(for: nil))
        XCTAssertNil(registry.lineMarkers(for: "x"), "nobody provides line markers for x")
        XCTAssertNil(registry.typeHierarchy(for: "x"))
        XCTAssertNil(registry.callHierarchy(for: "x"))
        XCTAssertNil(registry.structure(for: "y"), "y's service has no structure provider")
    }

    func testStructureNodeFindsTheDeepestNodeAndPathsByName() {
        let method = StructureNode(id: "m", title: "f()", kind: .method, nameRange: 20..<21, bodyRange: 18..<30)
        let inner = StructureNode(id: "i", title: "B", kind: .type, nameRange: 10..<11, bodyRange: 8..<40, children: [method])
        let outer = StructureNode(id: "o", title: "A", kind: .type, nameRange: 2..<3, bodyRange: 0..<50, children: [inner])
        XCTAssertEqual(outer.deepestNode(containing: 25).id, "m")
        XCTAssertEqual(outer.deepestNode(containing: 30).id, "m", "the end of a body still counts, as a caret at its end does")
        XCTAssertEqual(outer.deepestNode(containing: 35).id, "i")
        XCTAssertEqual(outer.deepestNode(containing: 45).id, "o")
        XCTAssertEqual(outer.deepestNode(containing: 99).id, "o", "outside every body falls back to the node asked")
        XCTAssertEqual(StructureNode.path(toNameAt: 20, in: [outer])?.map(\.id), ["o", "i", "m"])
        XCTAssertNil(StructureNode.path(toNameAt: 5, in: [outer]))
    }

    func testHierarchyItemsAreEqualByTheirFieldsNotTheirPayload() {
        struct One: Sendable {}
        struct Two: Sendable {}
        let a = HierarchyItem(id: "x", name: "X", kind: .classType, origin: .project, payload: One())
        let b = HierarchyItem(id: "x", name: "X", kind: .classType, origin: .project, payload: Two())
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNotEqual(a, HierarchyItem(id: "x", name: "X", kind: .classType, origin: .library, badge: "jar"))
    }

    // MARK: Umbra's wiring reproduces what the hand-written lists said

    @MainActor
    func testUmbraRegistryOptsOutOfTheSameGenericFeaturesAsBefore() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertEqual(languages.identifiers(disabling: .snippets), ["java", "http"])
        XCTAssertEqual(languages.identifiers(disabling: .symbolHover), ["java"])
        XCTAssertEqual(languages.identifiers(disabling: .symbolNavigation), ["java"])
        XCTAssertEqual(languages.identifiers(disabling: .duplicateSymbolDiagnostics), ["http"])
    }

    @MainActor
    func testUmbraRegistryKeepsTheEngineProviderOrder() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertEqual(
            languages.completionProviders.map(\.name), ["Java", "Markdown File Mention", "HTTP"],
            "completion: Java, then Markdown mentions, then HTTP"
        )
        XCTAssertEqual(languages.hoverProviders.count, 1)
        XCTAssertEqual(languages.diagnosticProviders.count, 2, "javac, then inspections")
        XCTAssertEqual(languages.navigationProviders.count, 2, "go to definition / implementation, then usages")
    }

    @MainActor
    func testUmbraGivesJavaEveryHostDrivenFeatureAndMarkdownNone() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertNotNil(languages.semanticTokens(for: "java"))
        XCTAssertNotNil(languages.lineMarkers(for: "java"))
        XCTAssertNotNil(languages.structure(for: "java"))
        XCTAssertNotNil(languages.typeHierarchy(for: "java"))
        XCTAssertNotNil(languages.callHierarchy(for: "java"))
        for language in ["markdown", "json", "http", "swift", nil] as [String?] {
            XCTAssertNil(languages.semanticTokens(for: language), language ?? "nil")
            XCTAssertNil(languages.lineMarkers(for: language), language ?? "nil")
            XCTAssertNil(languages.structure(for: language), language ?? "nil")
            XCTAssertNil(languages.typeHierarchy(for: language), language ?? "nil")
            XCTAssertNil(languages.callHierarchy(for: language), language ?? "nil")
        }
    }

    @MainActor
    func testUmbraRoutesFormattingByLanguage() {
        let formatting = IDEIntelligenceServices().languages.formatting
        XCTAssertTrue(formatting.supportsFormatting(document("java")))
        XCTAssertTrue(formatting.supportsFormatting(document("json")))
        XCTAssertFalse(formatting.supportsFormatting(document("markdown")))
        XCTAssertFalse(formatting.supportsFormatting(document(nil)))
    }
}
