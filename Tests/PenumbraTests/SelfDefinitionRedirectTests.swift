import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

/// A Go to Definition answer that is the queried identifier itself shows usages instead of
/// reselecting the name (IntelliJ's Go to Declaration or Usages). Both delivery paths — ⌘-click
/// in `JumpToDefinitionController` and keyboard in `EditorIntelligenceController` — redirect
/// through `NavigationSelfRedirect`; these tests pin the redirect and its boundaries.
@MainActor
final class SelfDefinitionRedirectTests: XCTestCase {
    private struct StubResult {
        var definition: NavigationResult?
        var references: [Location]
    }

    private final class StubProvider: NavigationProvider, @unchecked Sendable {
        let name = "SelfRedirectStub"
        let stub: StubResult
        private let lock = NSLock()
        private var kinds: [NavigationKind] = []
        init(stub: StubResult) { self.stub = stub }
        var requestedKinds: [NavigationKind] { lock.withLock { kinds } }
        func provide(context: NavigationContext) async -> NavigationResult? {
            lock.withLock { kinds.append(context.kind) }
            switch context.kind {
            case .definition:
                return stub.definition
            case .references:
                if stub.references.isEmpty { return nil }
                if stub.references.count == 1 { return .single(stub.references[0]) }
                return .multiple(stub.references)
            default:
                return nil
            }
        }
        func isPrimary(for context: NavigationContext) -> Bool { true }
    }

    private func makeLocation(range: NSRange, url: URL? = nil, target: Location.Target = .source) -> Location {
        let start = TextPosition(line: 0, column: range.location, utf16Offset: range.location)
        let end = TextPosition(line: 0, column: NSMaxRange(range), utf16Offset: NSMaxRange(range))
        return Location(
            id: UUID(), documentID: DocumentID(), url: url,
            range: TextRange(start: start, end: end), displayName: "count", target: target
        )
    }

    private func makeController(text: String, stub: StubResult) async throws -> (JumpToDefinitionController, TextView, StubProvider) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = text
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        let provider = StubProvider(stub: stub)
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [provider])
        )
        textView.navigationHistory = NavigationHistory()
        return (controller, textView, provider)
    }

    private func waitFor(_ textView: TextView, timeout: TimeInterval = 3) async throws {
        // The redirect runs navigation twice; wait until the references answer has landed
        // instead of sleeping a fixed amount.
        let deadline = Date().addingTimeInterval(timeout)
        while textView.navigationHistory.backEntries.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testClickSelfResultPresentsReferenceChoicesAtClick() async throws {
        // `count` declared at 4..<9; the provider answers the name itself, plus three uses.
        let selfRange = NSRange(location: 4, length: 5)
        let (controller, textView, provider) = try await makeController(
            text: "int count = 0;\ncount = 1;\ncount = 2;\ncount = 3;\n",
            stub: StubResult(
                definition: .single(makeLocation(range: selfRange)),
                references: [
                    makeLocation(range: NSRange(location: 20, length: 5)),
                    makeLocation(range: NSRange(location: 40, length: 5)),
                    makeLocation(range: NSRange(location: 60, length: 5)),
                ]
            )
        )
        textView.selectedRange = NSRange(location: 4, length: 0)
        var presented: (kind: NavigationKind, locations: [Location], identifier: NSRange, name: String)?
        controller.onPresentChoicesAtClick = { kind, locations, identifier, name in
            presented = (kind, locations, identifier, name)
        }
        controller.navigate(
            at: TextPosition(line: 0, column: 4, utf16Offset: 4),
            kind: .definition, clickedIdentifier: selfRange
        )
        let deadline = Date().addingTimeInterval(3)
        while presented == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shown = try XCTUnwrap(presented, "self + 3 references presents choices at the click")
        XCTAssertEqual(shown.kind, .references)
        XCTAssertEqual(shown.locations.count, 3)
        XCTAssertEqual(shown.identifier, selfRange)
        XCTAssertEqual(shown.name, "count")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0), "no reselect")
        XCTAssertTrue(textView.navigationHistory.backEntries.isEmpty, "no checkpoint for a self result")
        XCTAssertEqual(provider.requestedKinds, [.definition, .references])
    }

    func testSelfResultWithOneReferenceGoesToIt() async throws {
        let selfRange = NSRange(location: 4, length: 5)
        let target = NSRange(location: 20, length: 5)
        let (controller, textView, provider) = try await makeController(
            text: "int count = 0;\ncount = 1;\n",
            stub: StubResult(
                definition: .single(makeLocation(range: selfRange)),
                references: [makeLocation(range: target)]
            )
        )
        textView.selectedRange = NSRange(location: 4, length: 0)
        controller.navigate(
            at: TextPosition(line: 0, column: 4, utf16Offset: 4),
            kind: .definition, clickedIdentifier: selfRange
        )
        try await waitFor(textView)
        XCTAssertEqual(textView.selectedRange, target, "the single reference is focused")
        XCTAssertEqual(textView.navigationHistory.backEntries.count, 1, "going elsewhere checkpoints")
        XCTAssertEqual(provider.requestedKinds, [.definition, .references])
    }

    func testSelfResultWithNoReferencesLeavesSelectionAlone() async throws {
        let selfRange = NSRange(location: 4, length: 5)
        let (controller, textView, provider) = try await makeController(
            text: "int count = 0;\n",
            stub: StubResult(definition: .single(makeLocation(range: selfRange)), references: [])
        )
        textView.selectedRange = NSRange(location: 4, length: 0)
        controller.navigate(
            at: TextPosition(line: 0, column: 4, utf16Offset: 4),
            kind: .definition, clickedIdentifier: selfRange
        )
        let deadline = Date().addingTimeInterval(3)
        while provider.requestedKinds.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(provider.requestedKinds, [.definition, .references])
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertTrue(textView.navigationHistory.backEntries.isEmpty)
    }

    func testNonSelfDefinitionGoesThereAsBefore() async throws {
        // The definition is on another line, outside the caret identifier: no redirect,
        // and the references provider is never consulted.
        let (controller, textView, provider) = try await makeController(
            text: "int count = 0;\ncount = 1;\n",
            stub: StubResult(
                definition: .single(makeLocation(range: NSRange(location: 20, length: 5))),
                references: [makeLocation(range: NSRange(location: 40, length: 5))]
            )
        )
        textView.selectedRange = NSRange(location: 4, length: 0)
        controller.navigate(
            at: TextPosition(line: 0, column: 4, utf16Offset: 4),
            kind: .definition, clickedIdentifier: NSRange(location: 4, length: 5)
        )
        try await waitFor(textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 20, length: 5))
        XCTAssertEqual(textView.navigationHistory.backEntries.count, 1)
        XCTAssertEqual(provider.requestedKinds, [.definition])
    }

    func testStaleSelfResultRunsNoReferencesSearch() async throws {
        // The provider edits the buffer before answering, so its self result is about
        // older text: F24 drops it and no references search runs.
        final class EditingProvider: NavigationProvider, @unchecked Sendable {
            let name = "Editing"
            let textView: TextView
            let location: Location
            private let lock = NSLock()
            private var kinds: [NavigationKind] = []
            init(textView: TextView, location: Location) {
                self.textView = textView
                self.location = location
            }
            var requestedKinds: [NavigationKind] { lock.withLock { kinds } }
            func provide(context: NavigationContext) async -> NavigationResult? {
                lock.withLock { kinds.append(context.kind) }
                guard context.kind == .definition else { return nil }
                await MainActor.run { textView.insertText("X") }
                return .single(location)
            }
            func isPrimary(for context: NavigationContext) -> Bool { true }
        }
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "int count = 0;\n"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        let selfRange = NSRange(location: 4, length: 5)
        let provider = EditingProvider(textView: textView, location: makeLocation(range: selfRange))
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [provider])
        )
        textView.navigationHistory = NavigationHistory()
        textView.selectedRange = NSRange(location: 4, length: 0)
        controller.navigate(
            at: TextPosition(line: 0, column: 4, utf16Offset: 4),
            kind: .definition, clickedIdentifier: selfRange
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(provider.requestedKinds, [.definition], "the stale self result runs no references search")
        XCTAssertTrue(textView.navigationHistory.backEntries.isEmpty)
    }

    func testHoverDoesNotRunReferencesSearch() async throws {
        let selfRange = NSRange(location: 22, length: 3)
        let (controller, _, provider) = try await makeController(
            text: "int count = Box;\n",
            stub: StubResult(
                definition: .single(makeLocation(range: selfRange)),
                references: [makeLocation(range: NSRange(location: 0, length: 3))]
            )
        )
        await controller.resolveHover(
            at: TextPosition(line: 0, column: 22, utf16Offset: 22), identifier: selfRange
        )
        XCTAssertNotNil(controller.cachedHoverResult(for: selfRange))
        XCTAssertEqual(provider.requestedKinds, [.definition], "hover never runs a references search")
    }

    // MARK: - Keyboard path (EditorIntelligenceController)

    private func makeEditorController(
        text: String, caret: Int, stub: StubResult
    ) async throws -> (EditorIntelligenceController, TextView, StubProvider, NSWindow) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        let provider = StubProvider(stub: stub)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            navigationEngine: NavigationEngine(providers: [provider])
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.navigationHistory = NavigationHistory()
        textView.selectedRange = NSRange(location: caret, length: 0)
        return (controller, textView, provider, window)
    }

    func testKeyboardSelfResultPresentsChoicesViaHost() async throws {
        let (controller, textView, provider, window) = try await makeEditorController(
            text: "int count = 0;\ncount = 1;\ncount = 2;\ncount = 3;\n", caret: 4,
            stub: StubResult(
                definition: .single(makeLocation(range: NSRange(location: 4, length: 5))),
                references: [
                    makeLocation(range: NSRange(location: 20, length: 5)),
                    makeLocation(range: NSRange(location: 40, length: 5)),
                    makeLocation(range: NSRange(location: 60, length: 5)),
                ]
            )
        )
        _ = window
        var presented: (kind: NavigationKind, locations: [Location])?
        controller.onPresentNavigationChoices = { kind, locations in presented = (kind, locations) }
        XCTAssertTrue(controller.navigate(kind: .definition))
        let deadline = Date().addingTimeInterval(3)
        while presented == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shown = try XCTUnwrap(presented, "keyboard self + 3 references presents choices via the host")
        XCTAssertEqual(shown.kind, .references)
        XCTAssertEqual(shown.locations.count, 3)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0), "no reselect")
        XCTAssertTrue(textView.navigationHistory.backEntries.isEmpty, "no checkpoint for a self result")
        XCTAssertEqual(provider.requestedKinds, [.definition, .references])
    }

    // MARK: - Helper rule

    func testIdentifierRangeFindings() {
        let text = "int count = 0;" as NSString
        XCTAssertEqual(
            NavigationSelfRedirect.identifierRange(at: 4, in: text), NSRange(location: 4, length: 5)
        )
        XCTAssertEqual(
            NavigationSelfRedirect.identifierRange(at: 8, in: text), NSRange(location: 4, length: 5)
        )
        XCTAssertNil(NavigationSelfRedirect.identifierRange(at: 3, in: text), "the space is not an identifier")
        XCTAssertNil(NavigationSelfRedirect.identifierRange(at: 100, in: text))
        let digits = "9lives" as NSString
        XCTAssertNil(NavigationSelfRedirect.identifierRange(at: 0, in: digits))
        XCTAssertNil(
            NavigationSelfRedirect.identifierRange(at: 1, in: digits), "a leading digit disqualifies"
        )
    }

    func testIsSelfResultMatrix() {
        let identifier = NSRange(location: 4, length: 5)
        let here = URL(fileURLWithPath: "/tmp/A.swift")
        let inner = makeLocation(range: NSRange(location: 5, length: 2))
        let elsewhere = URL(fileURLWithPath: "/tmp/B.swift")

        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(inner), kind: .references, identifier: identifier, documentURL: here
            ), "only .definition redirects"
        )
        XCTAssertNotNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(inner), kind: .definition, identifier: identifier, documentURL: here
            ), "a self range with no url is the current document"
        )
        let sameFile = Location(
            id: inner.id, documentID: inner.documentID, url: here, range: inner.range,
            displayName: inner.displayName, target: inner.target
        )
        XCTAssertNotNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(sameFile), kind: .definition, identifier: identifier, documentURL: here
            )
        )
        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(makeLocation(range: NSRange(location: 5, length: 2), url: elsewhere)),
                kind: .definition, identifier: identifier, documentURL: here
            ), "another document is not self"
        )
        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(makeLocation(range: NSRange(location: 5, length: 2), target: .directory)),
                kind: .definition, identifier: identifier, documentURL: here
            ), "a non-source target is not self"
        )
        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(makeLocation(range: NSRange(location: 40, length: 5))),
                kind: .definition, identifier: identifier, documentURL: here
            ), "a location outside the identifier is not self"
        )
        XCTAssertNotNil(
            NavigationSelfRedirect.selfLocation(
                in: .multiple([inner]), kind: .definition, identifier: identifier, documentURL: here
            ), "a single-element multiple counts as one"
        )
        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .multiple([inner, inner]), kind: .definition, identifier: identifier, documentURL: here
            ), "several targets are not self"
        )
        XCTAssertNil(
            NavigationSelfRedirect.selfLocation(
                in: .single(inner), kind: .definition,
                identifier: NSRange(location: 4, length: 0), documentURL: here
            ), "an empty identifier never matches"
        )
    }
}
