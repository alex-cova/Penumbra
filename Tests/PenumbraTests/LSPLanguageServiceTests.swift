import EditorIntelligence
import EditorIntelligenceLSP
import XCTest

final class LSPLanguageServiceTests: XCTestCase {
    func testADisconnectedServerLeavesTheNativeTierInFront() async {
        let box = LSPConnectionBox()
        let service = makeService(box)
        XCTAssertEqual(service.tier, .semantic)
        XCTAssertTrue(service.unavailableFeatures.contains(.hover))
        XCTAssertTrue(service.unavailableFeatures.contains(.completion))

        let native = SyntacticHover(name: "swift")
        let registry = LanguageServiceRegistry(services: [native, service])
        XCTAssertEqual(registry.capabilities(for: "swift").features[.hover]?.service, "swift")
        XCTAssertEqual(registry.capabilities(for: "swift").features[.hover]?.fidelity, .syntactic)

        let hover = await service.providers.hover.first?.provide(context: hoverContext(language: "swift"))
        XCTAssertNil(hover)
        await LanguageServiceConformance.check(service)
    }

    func testAConnectedServerAnswersAndPublishesDiagnostics() async {
        let box = LSPConnectionBox(client: FakeLSP())
        let service = makeService(box)
        XCTAssertTrue(service.unavailableFeatures.isEmpty)
        XCTAssertEqual(service.lspLanguageID(for: document(language: "typescript", url: URL(fileURLWithPath: "/tmp/A.tsx"))), "typescriptreact")

        let published = PublicationBox()
        await service.start(environment: LanguageEnvironment(publishDiagnostics: { published.append($0) }))

        let hover = await service.providers.hover.first?.provide(context: hoverContext(language: "swift"))
        XCTAssertEqual(hover?.contents, "Box.moved()")
        let javaHover = await service.providers.hover.first?.provide(context: hoverContext(language: "java"))
        XCTAssertNil(javaHover)

        let diagnostics = await service.providers.diagnostics.first?.diagnostics(for: document(language: "swift", url: URL(fileURLWithPath: "/tmp/A.swift")))
        XCTAssertEqual(diagnostics?.map(\.message), ["unused"])
        XCTAssertEqual(diagnostics?.first?.source, DiagnosticSourceID.sourceKitLSP.rawValue)
        XCTAssertEqual(published.items.map(\.source), [.sourceKitLSP])
        XCTAssertEqual(published.items.first?.diagnostics.map(\.message), ["unused"])

        let registry = LanguageServiceRegistry(services: [SyntacticHover(name: "swift"), service])
        XCTAssertEqual(registry.capabilities(for: "swift").features[.hover]?.service, "sourcekit-lsp")
        XCTAssertEqual(registry.capabilities(for: "swift").features[.hover]?.fidelity, .semantic)

        box.setCurrent(nil)
        XCTAssertTrue(service.unavailableFeatures.contains(.hover))
        XCTAssertNil(box.supportedFeatures)
        await service.stop()
    }

    func testADisconnectedServerLeavesRenameAndCallHierarchyOnTheNativeTier() {
        let box = LSPConnectionBox()
        let service = LSPLanguageService(
            configuration: LSPLanguageConfiguration(
                name: "sourcekit-lsp", languageIdentifiers: ["swift"],
                enabledFeatures: [.rename, .callHierarchy],
                diagnosticSource: .sourceKitLSP
            ),
            connections: box
        )
        let registry = LanguageServiceRegistry(services: [NativeRenameAndCalls(), service])
        XCTAssertEqual(registry.capabilities(for: "swift").features[.rename]?.service, "native")
        XCTAssertEqual(registry.capabilities(for: "swift").features[.callHierarchy]?.service, "native")

        box.setCurrent(FakeLSP())
        box.setSupportedFeatures([.rename])
        XCTAssertEqual(registry.capabilities(for: "swift").features[.rename]?.service, "sourcekit-lsp")
        XCTAssertEqual(registry.capabilities(for: "swift").features[.callHierarchy]?.service, "native")
    }

    func testAServerThatDoesNotAdvertiseHoverLeavesThatFeatureToTheNativeTier() {
        let box = LSPConnectionBox(client: FakeLSP())
        box.setSupportedFeatures([.completion, .diagnostics])
        let service = makeService(box)
        XCTAssertTrue(service.unavailableFeatures.contains(.hover))
        XCTAssertFalse(service.unavailableFeatures.contains(.completion))
        let registry = LanguageServiceRegistry(services: [SyntacticHover(name: "swift"), service])
        XCTAssertEqual(registry.capabilities(for: "swift").features[.hover]?.service, "swift")
        XCTAssertEqual(registry.capabilities(for: "swift").features[.completion]?.service, "sourcekit-lsp")
    }

    private func makeService(_ box: LSPConnectionBox) -> LSPLanguageService {
        LSPLanguageService(
            configuration: LSPLanguageConfiguration(
                name: "sourcekit-lsp",
                languageIdentifiers: ["swift", "typescript"],
                lspLanguageID: { url, identifier in
                    url?.pathExtension == "tsx" ? "typescriptreact" : identifier
                },
                enabledFeatures: [.completion, .hover, .diagnostics],
                diagnosticSource: .sourceKitLSP
            ),
            connections: box
        )
    }

    private func hoverContext(language: String) -> HoverContext {
        let document = document(language: language, url: nil)
        return HoverContext(document: document, cursor: document.cursor, selection: document.selection)
    }

    private func document(language: String, url: URL?) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: "A",
            contentSnapshot: TextSnapshot(version: 2, text: "let x = 1"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }
}

private final class PublicationBox: @unchecked Sendable {
    var items: [DiagnosticPublication] = []
    func append(_ publication: DiagnosticPublication) { items.append(publication) }
}

private struct SyntacticHover: LanguageService {
    let name: String
    let languageIdentifiers: Set<String> = ["swift"]
    let providers: LanguageProviders

    init(name: String) {
        self.name = name
        providers = LanguageProviders(hover: [QuietHover(name: name)])
    }
}

private struct QuietHover: HoverProvider {
    let name: String
    func provide(context: HoverContext) async -> HoverResult? { nil }
}

private struct NativeRenameAndCalls: LanguageService {
    let name = "native"
    let languageIdentifiers: Set<String> = ["swift"]
    let providers = LanguageProviders(
        rename: QuietRename(),
        callHierarchy: QuietCalls()
    )
}

private struct QuietRename: RenameProviding {
    func prepareRename(_ context: NavigationContext) async -> RenameTarget? { nil }
    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        RenamePlan(title: "Rename")
    }
}

private struct QuietCalls: CallHierarchyProviding {
    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? { nil }
    func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
    func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? { nil }
}

private struct FakeLSP: LSPClient {
    func requestDiagnostics(for document: Document) async throws -> [LSPDiagnostic] {
        [LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 1)),
            severity: 2, message: "unused"
        )]
    }

    func requestHover(for document: Document, at position: TextPosition) async throws -> LSPHover? {
        LSPHover(contents: "Box.moved()")
    }

    func requestCompletions(for document: Document, at position: TextPosition) async throws -> [LSPCompletionItem] { [] }
}
