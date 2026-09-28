import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

final class TypeDefinitionNavigationTests: XCTestCase {
    private actor RecordingClient: LSPClient {
        private(set) var typeDefinitionRequests = 0
        let locations: [LSPLocation]

        init(locations: [LSPLocation]) {
            self.locations = locations
        }

        func requestDiagnostics(for document: Document) async throws -> [LSPDiagnostic] { [] }
        func requestHover(for document: Document, at position: TextPosition) async throws -> LSPHover? { nil }
        func requestCompletions(for document: Document, at position: TextPosition) async throws -> [LSPCompletionItem] { [] }
        func requestTypeDefinition(for document: Document, at position: TextPosition) async throws -> [LSPLocation] {
            typeDefinitionRequests += 1
            return locations
        }
    }

    private final class RecordingProvider: NavigationProvider, @unchecked Sendable {
        let name = "Recording"
        private let lock = NSLock()
        private var seen: [NavigationKind] = []

        var kinds: [NavigationKind] { lock.withLock { seen } }

        func provide(context: NavigationContext) async -> NavigationResult? {
            lock.withLock { seen.append(context.kind) }
            return nil
        }
    }

    private func makeContext(kind: NavigationKind) -> NavigationContext {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "test",
            contentSnapshot: TextSnapshot(version: 0, text: "Foo foo"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
        )
        return NavigationContext(document: document, cursor: document.cursor, selection: document.selection, kind: kind)
    }

    private func location(_ uri: String) -> LSPLocation {
        LSPLocation(uri: uri, range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)))
    }

    // MARK: LSP

    func testLSPProviderAnswersOnlyTypeDefinitionRequests() async {
        let client = RecordingClient(locations: [location("file:///Foo.swift")])
        let provider = LSPTypeDefinitionProvider(client: client)

        let other = await provider.provide(context: makeContext(kind: .definition))
        XCTAssertNil(other)
        let requestsAfterOther = await client.typeDefinitionRequests
        XCTAssertEqual(requestsAfterOther, 0)

        let result = await provider.provide(context: makeContext(kind: .typeDefinition))
        guard case .single(let found) = result else {
            return XCTFail("Expected one location, got \(String(describing: result))")
        }
        XCTAssertEqual(found.displayName, "file:///Foo.swift")
    }

    func testLSPProviderReturnsEveryLocation() async {
        let client = RecordingClient(locations: [location("file:///A.swift"), location("file:///B.swift")])
        let result = await LSPTypeDefinitionProvider(client: client).provide(context: makeContext(kind: .typeDefinition))
        guard case .multiple(let found) = result else {
            return XCTFail("Expected several locations, got \(String(describing: result))")
        }
        XCTAssertEqual(found.count, 2)
    }

    func testGenericNameMatchingProviderIgnoresTypeDefinition() async {
        let provider = GoToDefinitionProvider(index: SymbolIndex())
        let result = await provider.provide(context: makeContext(kind: .typeDefinition))
        XCTAssertNil(result, "A name match must never answer for a type request")
    }

    // MARK: Action and keymap

    @MainActor
    func testTheActionAsksTheNavigationEngineForATypeDefinition() async throws {
        let provider = RecordingProvider()
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "Foo foo"
        textView.selectedRange = NSRange(location: 5, length: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            navigationEngine: NavigationEngine(providers: [provider])
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        withExtendedLifetime(controller) {
            XCTAssertTrue(textView.perform(.goToTypeDefinition))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.kinds, [.typeDefinition])
    }

    func testControlShiftBIsBoundOnlyInTheIntelliJKeymap() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("b", [.control, .shift]))), .goToTypeDefinition)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord("b", [.control, .shift]))))
        XCTAssertNil(Keymap.sublime.action(for: KeyStroke(KeyChord("b", [.control, .shift]))))
    }

    @MainActor
    func testTheActionHasATitleAndIsListedInFindAction() {
        XCTAssertEqual(EditorActionID.goToTypeDefinition.title, "Go to Type Declaration")
        XCTAssertTrue(CommandRegistry.findActionIDs.contains(.goToTypeDefinition))
        XCTAssertTrue(CommandRegistry.findActionIDs.contains(.showParameterInfo))
    }

    @MainActor
    func testNoResultTextNamesTheTypeDeclaration() {
        XCTAssertEqual(
            EditorIntelligenceController.noResultText(for: .typeDefinition, languageIdentifier: "java"),
            "No type declaration found"
        )
    }
}
