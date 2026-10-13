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

    private func document(_ language: String?, text: String = "") -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: nil, displayName: "x",
            contentSnapshot: TextSnapshot(version: 0, text: text),
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

    func testEngineProvidersAreOneTieredProviderPerLanguage() {
        let registry = LanguageServiceRegistry(services: [
            service("one", ["a"], LanguageProviders(completion: [FakeCompletion(name: "c1"), FakeCompletion(name: "c2")])),
            service("two", ["b"], LanguageProviders(completion: [FakeCompletion(name: "c3")]))
        ])
        XCTAssertEqual(registry.completionProviders.map(\.name), ["a", "b"])
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

    // MARK: Lifecycle

    private actor EventLog {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private struct RecordingService: LanguageService {
        let name: String
        let log: EventLog
        let languageIdentifiers: Set<String> = []
        let providers = LanguageProviders()
        func start(environment: LanguageEnvironment) async {
            let unit = await environment.indentUnit()
            await log.record("start \(name) indent=\(unit.debugDescription)")
        }
        func stop() async { await log.record("stop \(name)") }
    }

    func testStartRunsInRegistrationOrderAndStopInReverse() async {
        let log = EventLog()
        let registry = LanguageServiceRegistry(services: [
            RecordingService(name: "a", log: log), RecordingService(name: "b", log: log), RecordingService(name: "c", log: log)
        ])
        await registry.start(environment: LanguageEnvironment(indentUnit: { "\t" }))
        await registry.stop()
        let events = await log.events
        XCTAssertEqual(events, [
            "start a indent=\"\\t\"", "start b indent=\"\\t\"", "start c indent=\"\\t\"",
            "stop c", "stop b", "stop a"
        ])
    }

    /// Records into a class, not an actor: the project hooks are synchronous, so what they did is
    /// there the moment the registry call returns.
    private final class ProjectLog: @unchecked Sendable {
        var events: [String] = []
    }

    private struct ProjectObservingService: LanguageService {
        let name: String
        let log: ProjectLog
        let languageIdentifiers: Set<String> = []
        let providers = LanguageProviders()
        @MainActor func projectDidChange(root: URL?) { log.events.append("\(name) root=\(root?.path ?? "nil")") }
        @MainActor func filesDidChange(_ urls: [URL]) { log.events.append("\(name) files=\(urls.map(\.lastPathComponent).joined(separator: ","))") }
    }

    @MainActor
    func testProjectHooksReachEveryServiceInOrderBeforeTheCallReturns() {
        let log = ProjectLog()
        let registry = LanguageServiceRegistry(services: [
            ProjectObservingService(name: "a", log: log),
            service("plain", ["x"], LanguageProviders()),
            ProjectObservingService(name: "b", log: log)
        ])
        registry.projectDidChange(root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(log.events, ["a root=/proj", "b root=/proj"], "Synchronous: a read right after the call sees the effect")

        registry.filesDidChange([URL(fileURLWithPath: "/proj/A.java"), URL(fileURLWithPath: "/proj/B.java")])
        registry.projectDidChange(root: nil)
        XCTAssertEqual(log.events, [
            "a root=/proj", "b root=/proj",
            "a files=A.java,B.java", "b files=A.java,B.java",
            "a root=nil", "b root=nil"
        ])
    }

    @MainActor
    func testAServiceWithoutProjectHooksIgnoresThem() {
        let registry = LanguageServiceRegistry(services: [service("plain", ["x"], LanguageProviders())])
        registry.projectDidChange(root: URL(fileURLWithPath: "/proj"))
        registry.filesDidChange([URL(fileURLWithPath: "/proj/A.java")])
        registry.projectDidChange(root: nil)
    }

    func testAServiceThatDoesNotCareAboutTheLifecycleNeedsNothing() async {
        let registry = LanguageServiceRegistry(services: [service("plain", ["x"], LanguageProviders())])
        await registry.start(environment: LanguageEnvironment())
        await registry.stop()
    }

    func testTheDefaultEnvironmentKnowsNothingAndAgreesToNothing() async {
        let environment = LanguageEnvironment()
        let text = await environment.openBufferText(URL(fileURLWithPath: "/x"))
        XCTAssertNil(text)
        let unit = await environment.indentUnit()
        XCTAssertEqual(unit, "    ")
        let has = await environment.hasConsent("anything")
        let asked = await environment.requestConsent("anything")
        XCTAssertFalse(has)
        XCTAssertFalse(asked)
        XCTAssertEqual(ConsentTopic("a"), "a")
    }

    // MARK: Umbra's wiring reproduces what the hand-written lists said

    @MainActor
    func testUmbraRegistryOptsOutOfTheSameGenericFeaturesAsBefore() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertEqual(languages.identifiers(disabling: .snippets), ["http", "java", "javascript", "swift", "typescript"])
        XCTAssertEqual(languages.identifiers(disabling: .symbolHover), ["java", "javascript", "swift", "typescript"])
        XCTAssertEqual(languages.identifiers(disabling: .symbolNavigation), ["java", "javascript", "swift", "typescript"])
        XCTAssertEqual(languages.identifiers(disabling: .duplicateSymbolDiagnostics), ["http", "swift"])
    }

    @MainActor
    func testUmbraRegistryKeepsTheEngineProviderOrder() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertEqual(
            languages.completionProviders.map(\.name), ["java", "javascript", "typescript", "swift", "markdown", "http"],
            "one tiered completion provider per language, in registration order"
        )
        XCTAssertEqual(
            languages.hoverProviders.map(\.name), ["java", "javascript", "typescript", "swift", "http"],
            "`.http` adds the state of a `###@scheme:` line"
        )
        XCTAssertEqual(
            languages.diagnosticProviders.map(\.name), ["java", "javascript", "typescript", "swift"],
            "Java's javac and inspection providers share one tiered provider"
        )
        XCTAssertEqual(languages.navigationProviders.map(\.name), ["java", "javascript", "typescript", "swift"])
    }

    @MainActor
    func testUmbraGivesJavaEveryHostDrivenFeatureAndMarkdownNone() {
        let languages = IDEIntelligenceServices().languages
        XCTAssertNotNil(languages.semanticTokens(for: "java"))
        XCTAssertNotNil(languages.lineMarkers(for: "java"))
        XCTAssertNotNil(languages.structure(for: "java"))
        XCTAssertNotNil(languages.typeHierarchy(for: "java"))
        XCTAssertNotNil(languages.callHierarchy(for: "java"))
        XCTAssertNotNil(languages.semanticTokens(for: "typescript"))
        XCTAssertNotNil(languages.structure(for: "typescript"))
        XCTAssertNil(languages.lineMarkers(for: "typescript"))
        XCTAssertNil(languages.typeHierarchy(for: "typescript"))
        XCTAssertNil(languages.callHierarchy(for: "typescript"))
        XCTAssertNotNil(languages.semanticTokens(for: "swift"))
        XCTAssertNotNil(languages.structure(for: "swift"))
        XCTAssertNotNil(languages.lineMarkers(for: "swift"))
        XCTAssertNotNil(languages.typeHierarchy(for: "swift"))
        XCTAssertNotNil(languages.callHierarchy(for: "swift"))
        // `.http` colours `{{templates}}` and the `###@scheme:` line; it has no other host-driven feature.
        XCTAssertNotNil(languages.semanticTokens(for: "http"))
        for language in ["markdown", "json", "http", nil] as [String?] {
            if language != "http" {
                XCTAssertNil(languages.semanticTokens(for: language), language ?? "nil")
            }
            XCTAssertNil(languages.lineMarkers(for: language), language ?? "nil")
            XCTAssertNil(languages.structure(for: language), language ?? "nil")
            XCTAssertNil(languages.typeHierarchy(for: language), language ?? "nil")
            XCTAssertNil(languages.callHierarchy(for: language), language ?? "nil")
        }
    }

    @MainActor
    func testStartingTheRegistryGivesJavaTheHostsIndentUnitAndStopTakesItBack() async {
        let languages = IDEIntelligenceServices().languages
        let text = "class A {\nint x;\n}\n"
        let doc = document("java", text: text)

        func formatted() async -> String {
            let edits = await languages.formatting.formatDocument(doc)
            var result = text as NSString
            for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
                result = result.replacingCharacters(
                    in: NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset),
                    with: edit.replacement
                ) as NSString
            }
            return result as String
        }

        await languages.start(environment: LanguageEnvironment(indentUnit: { "\t" }))
        let withTabs = await formatted()
        XCTAssertEqual(withTabs, "class A {\n\tint x;\n}\n")
        await languages.stop()
        let afterStop = await formatted()
        XCTAssertEqual(afterStop, "class A {\n    int x;\n}\n", "Java falls back to its own default once the host's is gone")
    }

    @MainActor
    func testTheWorkspacesEnvironmentReadsTheTabSettingsAndKnowsTheDecompilerTopic() async {
        XCTAssertEqual(ConsentTopic.javaDecompiler.id, "java.decompiler")
        let unit = await IDEPreferences.currentIndentUnit()
        XCTAssertTrue(unit == "\t" || unit.allSatisfy { $0 == " " })
    }

    @MainActor
    func testUmbraRoutesFormattingByLanguage() {
        let formatting = IDEIntelligenceServices().languages.formatting
        XCTAssertTrue(formatting.supportsFormatting(document("java")))
        XCTAssertTrue(formatting.supportsFormatting(document("json")))
        XCTAssertFalse(formatting.supportsFormatting(document("markdown")))
        XCTAssertFalse(formatting.supportsFormatting(document(nil)))
    }

    func testASemanticServiceThatIsNotReadyFallsThroughAndAReadyOneWins() {
        let native = TieredFake(name: "native", tier: .syntactic, ready: true, hasHover: true)
        let server = TieredFake(name: "server", tier: .semantic, ready: false, hasHover: true)
        let starting = LanguageServiceRegistry(services: [native, server])
        XCTAssertEqual(starting.services(for: "swift").map(\.name), ["server", "native"])
        XCTAssertEqual(starting.services(for: "swift").first?.unavailableFeatures, [.hover])
        XCTAssertEqual(starting.capabilities(for: "swift").features[.hover]?.service, "native")
        XCTAssertEqual(starting.capabilities(for: "swift").features[.completion]?.service, "server")

        let ready = LanguageServiceRegistry(services: [
            native, TieredFake(name: "server", tier: .semantic, ready: true, hasHover: true)
        ])
        XCTAssertEqual(ready.capabilities(for: "swift").features[.hover]?.service, "server")
        XCTAssertEqual(ready.capabilities(for: "swift").features[.hover]?.fidelity, .semantic)
        XCTAssertEqual(ready.capabilities(for: "swift").features[.completion]?.service, "server")
    }

    func testABasicServicePassesConformance() async {
        let service = service("one", ["a"], LanguageProviders(hover: [TieredHover(name: "one")]))
        await LanguageServiceConformance.check(service)
    }

    func testAnUnreadySemanticTierFallsThroughAndAReadyOneReplacesCompletion() async {
        let native = BatchService(name: "native", tier: .syntactic, label: "native", hover: "native hover")
        let starting = BatchService(name: "server", tier: .semantic, label: "semantic", hover: "semantic hover", unavailable: [.completion, .hover])
        let registry = LanguageServiceRegistry(services: [native, starting])
        let context = completionContext(language: "swift")

        let whileStarting = await labels(from: registry, context: context)
        XCTAssertEqual(whileStarting, [["native"]])

        let ready = BatchService(name: "server", tier: .semantic, label: "semantic", hover: "semantic hover")
        let readyRegistry = LanguageServiceRegistry(services: [native, ready])
        let snapshots = await labels(from: readyRegistry, context: context)
        XCTAssertEqual(snapshots.first, ["native"])
        XCTAssertEqual(snapshots.last, ["semantic"], "the semantic batch replaces the syntactic one")
        XCTAssertFalse(snapshots.contains { $0.contains("native") && $0.contains("semantic") })
    }

    func testHoverAsksTheTopReadyTierAndFallsBackOnNil() async {
        let native = BatchService(name: "native", tier: .syntactic, label: "native", hover: "native hover")
        let silent = BatchService(name: "server", tier: .semantic, label: "semantic", hover: nil)
        let registry = LanguageServiceRegistry(services: [native, silent])
        let hover = await registry.hoverProviders.first?.provide(context: hoverContext(language: "swift"))
        XCTAssertEqual(hover?.contents, "native hover")

        let answering = BatchService(name: "server", tier: .semantic, label: "semantic", hover: "semantic hover")
        let both = LanguageServiceRegistry(services: [native, answering])
        var answers: [String] = []
        for _ in 0..<8 {
            let result = await both.hoverProviders.first?.provide(context: hoverContext(language: "swift"))
            answers.append(result?.contents ?? "")
        }
        XCTAssertEqual(Set(answers), ["semantic hover"])
    }

    func testDiagnosticsKeepBothTiersAndTheEngineDedupes() async {
        let range = EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0),
            end: TextPosition(line: 0, column: 1, utf16Offset: 1)
        )
        let native = BatchService(
            name: "native", tier: .syntactic, label: "native", hover: nil,
            diagnostics: [Diagnostic(severity: .warning, message: "syntax", range: range, source: "native")]
        )
        let server = BatchService(
            name: "server", tier: .semantic, label: "semantic", hover: nil,
            diagnostics: [
                Diagnostic(severity: .warning, message: "syntax", range: range, source: "server"),
                Diagnostic(severity: .error, message: "type", range: range, source: "server")
            ]
        )
        let registry = LanguageServiceRegistry(services: [native, server])
        let report = await DiagnosticEngine(providers: registry.diagnosticProviders).diagnostics(for: document("swift"))
        XCTAssertEqual(report.diagnostics.map(\.message).sorted(), ["syntax", "type"])
    }

    func testNavigationFallsBackWhenTheSemanticTierReturnsNil() async {
        let native = BatchService(name: "native", tier: .syntactic, label: "native", hover: nil, navigation: "native")
        let empty = BatchService(name: "server", tier: .semantic, label: "semantic", hover: nil, navigation: nil)
        let registry = LanguageServiceRegistry(services: [native, empty])
        let context = NavigationContext(
            document: document("swift"), cursor: document("swift").cursor,
            selection: document("swift").selection, kind: .definition
        )
        let result = await registry.navigationProviders.first?.provide(context: context)
        guard case .single(let location) = result else {
            return XCTFail("expected the native destination")
        }
        XCTAssertEqual(location.displayName, "native")
    }

    private func labels(from registry: LanguageServiceRegistry, context: CompletionContext) async -> [[String]] {
        let engine = CompletionEngine(providers: registry.completionProviders, debounceInterval: 0)
        var snapshots: [[String]] = []
        do {
            for try await update in await engine.completeUpdates(context: context) {
                snapshots.append(update.items.map(\.label))
            }
        } catch {
            XCTFail("\(error)")
        }
        return snapshots
    }

    private func completionContext(language: String) -> CompletionContext {
        let doc = document(language, text: "name")
        return CompletionContext(
            document: doc, cursor: doc.cursor, trigger: .manual, prefix: "", range: doc.selection.range
        )
    }

    private func hoverContext(language: String) -> HoverContext {
        let doc = document(language)
        return HoverContext(document: doc, cursor: doc.cursor, selection: doc.selection)
    }
}

/// A service whose tier and readiness the registry tests can set.
private struct TieredFake: LanguageService {
    let name: String
    let languageIdentifiers: Set<String> = ["swift"]
    let providers: LanguageProviders
    let tier: LanguageServiceTier
    let unavailableFeatures: Set<LanguageFeature>

    init(name: String, tier: LanguageServiceTier, ready: Bool, hasHover: Bool) {
        self.name = name
        self.tier = tier
        unavailableFeatures = ready ? [] : [.hover]
        providers = LanguageProviders(
            completion: [TieredCompletion(name: name)],
            hover: hasHover ? [TieredHover(name: name)] : []
        )
    }
}

private struct TieredCompletion: CompletionProvider {
    let name: String
    func provide(context: CompletionContext) async -> [CompletionItem] { [] }
}

private struct TieredHover: HoverProvider {
    let name: String
    func provide(context: HoverContext) async -> HoverResult? { nil }
}

/// A syntactic or semantic service whose completion, hover, diagnostics and navigation the tier tests read.
private struct BatchService: LanguageService {
    let name: String
    let languageIdentifiers: Set<String> = ["swift"]
    let providers: LanguageProviders
    let tier: LanguageServiceTier
    let unavailableFeatures: Set<LanguageFeature>

    init(
        name: String,
        tier: LanguageServiceTier,
        label: String,
        hover: String?,
        unavailable: Set<LanguageFeature> = [],
        diagnostics: [Diagnostic] = [],
        navigation: String? = nil
    ) {
        self.name = name
        self.tier = tier
        unavailableFeatures = unavailable
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let range = EditorIntelligence.TextRange(start: position, end: position)
        providers = LanguageProviders(
            completion: [LabeledCompletion(name: name, label: label, range: range)],
            hover: [LabeledHover(name: name, contents: hover)],
            diagnostics: [FixedDiagnostics(name: name, items: diagnostics)],
            navigation: [LabeledNavigation(name: name, displayName: navigation)]
        )
    }
}

private struct LabeledCompletion: CompletionProvider {
    let name: String
    let label: String
    let range: EditorIntelligence.TextRange
    func isPrimary(for context: CompletionContext) -> Bool { true }
    func provide(context: CompletionContext) async -> [CompletionItem] {
        [CompletionItem(label: label, insertText: label, kind: .variable, range: range, source: name)]
    }
}

private struct LabeledHover: HoverProvider {
    let name: String
    let contents: String?
    func provide(context: HoverContext) async -> HoverResult? {
        contents.map { HoverResult(contents: $0, source: name) }
    }
}

private struct FixedDiagnostics: DiagnosticProvider {
    let name: String
    let items: [Diagnostic]
    func diagnostics(for document: Document) async -> [Diagnostic] { items }
}

private struct LabeledNavigation: NavigationProvider {
    let name: String
    let displayName: String?
    func isPrimary(for context: NavigationContext) -> Bool { true }
    func provide(context: NavigationContext) async -> NavigationResult? {
        guard let displayName else { return nil }
        return .single(Location(
            documentID: context.document.id, range: context.document.selection.range, displayName: displayName
        ))
    }
}
