import XCTest
import EditorIntelligence

final class NavigationTests: XCTestCase {
    func testGoToDefinitionReturnsSingleLocation() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let range = makeRange(line: 0, startColumn: 0, endColumn: 4)
        let symbol = Symbol(name: "greet", kind: .function, documentID: documentID, range: range)
        await index.index([symbol], for: documentID)

        let provider = GoToDefinitionProvider(index: index)
        let context = makeNavigationContext(documentID: documentID, text: "greet()", offset: 2)
        let result = await provider.provide(context: context)

        guard case .single(let location) = result else {
            return XCTFail("Expected a single location")
        }
        XCTAssertEqual(location.displayName, "greet")
        XCTAssertEqual(location.documentID, documentID)
    }

    func testFindReferencesReturnsMultipleLocations() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let first = Symbol(name: "greet", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 5))
        let second = Symbol(name: "greet", kind: .function, documentID: documentID, range: makeRange(line: 1, startColumn: 0, endColumn: 5))
        await index.index([first, second], for: documentID)

        let provider = FindReferencesProvider(index: index)
        let context = makeNavigationContext(documentID: documentID, text: "greet()", offset: 2, kind: .references)
        let result = await provider.provide(context: context)

        guard case .multiple(let locations) = result else {
            return XCTFail("Expected multiple locations")
        }
        XCTAssertEqual(locations.count, 2)
    }

    func testBreadcrumbReturnsEnclosingSymbols() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let outer = Symbol(name: "outer", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 50))
        let inner = Symbol(name: "inner", kind: .variable, documentID: documentID, range: makeRange(line: 0, startColumn: 10, endColumn: 20))
        await index.index([outer, inner], for: documentID)

        let provider = BreadcrumbProvider(index: index)
        let context = makeNavigationContext(documentID: documentID, text: String(repeating: "x", count: 50), offset: 15)
        let result = await provider.provide(context: context)

        guard case .multiple(let locations) = result else {
            return XCTFail("Expected multiple locations")
        }
        XCTAssertEqual(locations.map(\.displayName), ["outer", "inner"])
    }

    func testNavigationEngineReturnsFirstResult() async {
        let first = MockNavigationProvider(name: "First", result: .single(makeLocation(name: "first")))
        let second = MockNavigationProvider(name: "Second", result: .single(makeLocation(name: "second")))
        let engine = NavigationEngine(providers: [first, second])
        let context = makeNavigationContext(documentID: DocumentID(), text: "foo", offset: 0)
        let result = await engine.navigate(context: context)
        guard case .single(let location) = result else {
            return XCTFail("Expected single result")
        }
        XCTAssertEqual(location.displayName, "first")
    }

    func testNavigationEngineAsksOnlyPrimaryProvidersWhenOneClaimsTheContext() async {
        let fallback = MockNavigationProvider(name: "Fallback", result: .single(makeLocation(name: "fallback")))
        let primary = MockNavigationProvider(name: "Primary", result: nil, isPrimary: true)
        let engine = NavigationEngine(providers: [primary, fallback])
        let context = makeNavigationContext(documentID: DocumentID(), text: "foo", offset: 0)
        let navigated = await engine.navigate(context: context)
        XCTAssertNil(navigated, "A primary provider with no answer must not fall through to a fallback")
        let collected = await engine.collect(context: context)
        XCTAssertTrue(collected.isEmpty)
    }

    func testNavigationEngineUsesPrimaryResultOverEarlierFallback() async {
        let fallback = MockNavigationProvider(name: "Fallback", result: .single(makeLocation(name: "fallback")))
        let primary = MockNavigationProvider(name: "Primary", result: .single(makeLocation(name: "primary")), isPrimary: true)
        let engine = NavigationEngine(providers: [fallback, primary])
        let context = makeNavigationContext(documentID: DocumentID(), text: "foo", offset: 0)
        guard case .single(let location)? = await engine.navigate(context: context) else {
            return XCTFail("Expected single result")
        }
        XCTAssertEqual(location.displayName, "primary")
    }

    func testFindReferencesProviderSkipsConfiguredLanguages() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = Symbol(name: "foo", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 3))
        await index.index([symbol], for: documentID)
        let context = makeNavigationContext(documentID: documentID, text: "foo", offset: 0, kind: .references, languageIdentifier: "java")
        let skipping = FindReferencesProvider(index: index, skippingLanguages: ["java"])
        let skipped = await skipping.provide(context: context)
        XCTAssertNil(skipped)
        let plain = FindReferencesProvider(index: index)
        let found = await plain.provide(context: context)
        XCTAssertNotNil(found)
    }

    func testNavigationEngineCollectsAllResults() async {
        let first = MockNavigationProvider(name: "First", result: .single(makeLocation(name: "first")))
        let second = MockNavigationProvider(name: "Second", result: .single(makeLocation(name: "second")))
        let engine = NavigationEngine(providers: [first, second])
        let context = makeNavigationContext(documentID: DocumentID(), text: "foo", offset: 0)
        let results = await engine.collect(context: context)
        XCTAssertEqual(results.count, 2)
    }

    func testSymbolSearchEngine() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let alpha = Symbol(name: "alpha", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 5))
        let beta = Symbol(name: "beta", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 4))
        await index.index([alpha, beta], for: documentID)

        let engine = SymbolSearchEngine(index: index)
        let prefixResults = await engine.search(prefix: "al")
        XCTAssertEqual(prefixResults.map(\.name), ["alpha"])

        let exactResults = await engine.search(exact: "beta")
        XCTAssertEqual(exactResults.map(\.name), ["beta"])
    }
}

private actor MockNavigationProvider: NavigationProvider {
    let name: String
    let result: NavigationResult?
    private let primary: Bool

    init(name: String, result: NavigationResult?, isPrimary: Bool = false) {
        self.name = name
        self.result = result
        self.primary = isPrimary
    }

    nonisolated func isPrimary(for context: NavigationContext) -> Bool {
        primary
    }

    func provide(context: NavigationContext) async -> NavigationResult? {
        result
    }
}

private func makeNavigationContext(
    documentID: DocumentID,
    text: String,
    offset: Int,
    kind: NavigationKind = .definition,
    languageIdentifier: String? = nil
) -> NavigationContext {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: documentID,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
        languageIdentifier: languageIdentifier
    )
    return NavigationContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position)),
        kind: kind
    )
}

private func makeRange(line: Int, startColumn: Int, endColumn: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: line, column: startColumn, utf16Offset: startColumn),
        end: TextPosition(line: line, column: endColumn, utf16Offset: endColumn)
    )
}

private func makeLocation(name: String) -> Location {
    Location(
        documentID: DocumentID(),
        url: nil,
        range: makeRange(line: 0, startColumn: 0, endColumn: 0),
        displayName: name
    )
}
