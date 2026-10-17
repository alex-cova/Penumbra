import XCTest
import AppKit
@testable import Penumbra
@testable import JavaIntelligence
import EditorIntelligence

final class InlineCompletionTests: XCTestCase {
    // MARK: - Formatter

    func testFormatterCutsAtFirstNewlineInSingleLineMode() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("get(0);\nreturn;", suffixLine: "", maxLines: 1),
            "get(0);"
        )
    }

    func testFormatterAppendsMissingClosersAndQuote() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("foo(bar, \"baz", suffixLine: "", maxLines: 1),
            "foo(bar, \"baz\")"
        )
    }

    func testFormatterDropsTailDuplicatingSuffix() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("get(0));", suffixLine: ");", maxLines: 1),
            "get(0)"
        )
    }

    func testFormatterReturnsNilForWhitespace() {
        XCTAssertNil(InlineSuggestionFormatter.format("  \n ", suffixLine: "", maxLines: 1))
    }

    // MARK: - Multi-line formatter

    func testFormatterStopsAtBlankLine() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("foo();\nbar();\n\nbaz();", suffixLine: "", maxLines: 8, indentation: "    "),
            "foo();\n    bar();"
        )
    }

    func testFormatterStopsAtDedentBelowStartingBlock() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("foo();\n    bar();\n  baz();", suffixLine: "", maxLines: 8, indentation: "    "),
            "foo();\n    bar();"
        )
    }

    func testFormatterCapsAtEightLinesAndBalancesBrackets() {
        let raw = (["if (x) {"] + (1...12).map { "    work\($0)();" }).joined(separator: "\n")
        let formatted = InlineSuggestionFormatter.format(raw, suffixLine: "", maxLines: 8, indentation: "    ")
        XCTAssertEqual(formatted?.components(separatedBy: "\n").count, 8)
        XCTAssertTrue(formatted?.hasSuffix("}") == true, "brackets balanced over the block: \(formatted ?? "")")
    }

    func testFormatterReindentsContinuationLines() {
        XCTAssertEqual(
            InlineSuggestionFormatter.format("foo();\nbar();", suffixLine: "", maxLines: 8, indentation: "    "),
            "foo();\n    bar();"
        )
    }

    // MARK: - Smart filter

    func testFilterDropsShortPunctuationAndRepeats() {
        let filter = InlineCompletionFilter()
        let request = InlineCompletionRequest(prefix: "int x = 1;\nfoo.", suffix: "")
        XCTAssertFalse(filter.accepts(";", for: request))
        XCTAssertFalse(filter.accepts(")", for: request))
        XCTAssertTrue(filter.accepts("bar()", for: request))
        let repeating = InlineCompletionRequest(prefix: "get(0);\n", suffix: "")
        XCTAssertFalse(filter.accepts("get(0);", for: repeating))
        filter.recordSuppressed(linePrefix: "foo.", suggestion: "bar()")
        XCTAssertFalse(filter.accepts("bar()", for: request))
    }

    // MARK: - Engine window

    func testEngineWindowIsBounded() {
        let text = String(repeating: "a", count: 20_000)
        let position = TextPosition(line: 0, column: 10_000, utf16Offset: 10_000)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "Big.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let window = InlineCompletionEngine.window(in: document, at: position)
        XCTAssertEqual(window.prefix.count, 6_144)
        XCTAssertEqual(window.suffix.count, 1_536)
    }

    private final class FakeModel: InlineCompletionModel, @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String]
        private(set) var callCount = 0

        init(_ texts: [String]) { self.texts = texts }

        func complete(_ request: InlineCompletionRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            callCount += 1
            let text = texts.isEmpty ? "" : texts.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    func testEngineFormatsAndFiltersModelOutput() async {
        let engine = InlineCompletionEngine(model: FakeModel(["get(0);\nignored"]), debounceInterval: 0)
        let source = "names."
        let position = TextPosition(line: 0, column: 6, utf16Offset: 6)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "Test.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let suggestion = await engine.suggest(
            request: InlineCompletionRequest(prefix: "", suffix: ""), document: document, position: position
        )
        XCTAssertEqual(suggestion?.text, "get(0);")
    }

    // MARK: - Java validation

    private func document(_ source: String) -> (Document, TextPosition) {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
        let document = Document(
            id: DocumentID(), url: URL(fileURLWithPath: "/tmp/Test.java"), displayName: "Test.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        return (document, position)
    }

    private func makeIndex(withStubs stubs: [JavaClassStub]) async throws -> JavaIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        return index
    }

    private func listStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.util.List", qualifiedName: "java.util.List", simpleName: "List", packageName: "java.util",
            kind: .interfaceKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "get", parameters: [JavaParameterStub(name: "i", type: .primitive(.int))], returnType: .unresolved(simpleName: "E", arguments: []), modifiers: [.publicFlag]),
                JavaMethodStub(name: "size", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
    }

    func testValidatorKeepsResolvedMember() async throws {
        let index = try await makeIndex(withStubs: [listStub()])
        let (document, position) = document("class Test { void m() { java.util.List<String> names = null; names.€ } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "get(0);"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "get(0);")
    }

    func testValidatorRejectsUnknownLeadingReference() async throws {
        let index = try await makeIndex(withStubs: [listStub()])
        let (document, position) = document("class Test { void m() { java.util.List<String> names = null; names.€ } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "frobnicate();"), in: document, at: position
        )
        XCTAssertNil(result)
    }

    func testValidatorTruncatesBeforeUnknownReference() async throws {
        let index = try await makeIndex(withStubs: [listStub()])
        let (document, position) = document("class Test { void m() { java.util.List<String> names = null; names.€ } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "size() + frobnicate"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "size() +")
    }

    func testValidatorAutoImportsUniqueType() async throws {
        let arrayList = JavaClassStub(
            binaryName: "java.util.ArrayList", qualifiedName: "java.util.ArrayList", simpleName: "ArrayList",
            packageName: "java.util", kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [arrayList])
        let (document, position) = document("class Test { Object make() { return €; } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "new ArrayList<>()"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "new ArrayList<>()")
        XCTAssertTrue(
            result?.additionalEdits.contains { $0.replacement.contains("import java.util.ArrayList;") } == true,
            "edits: \(String(describing: result?.additionalEdits))"
        )
    }

    func testValidatorRejectsSyntaxErrors() async throws {
        let index = try await makeIndex(withStubs: [listStub()])
        let (document, position) = document("class Test { void m() { java.util.List<String> names = null; names.€ } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "get(];;"), in: document, at: position
        )
        XCTAssertNil(result)
    }

    func testValidatorKeepsAnInheritedMemberOfAnIndexedClass() async throws {
        let base = JavaClassStub(
            binaryName: "Base", qualifiedName: "Base", simpleName: "Base", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "greet", parameters: [], returnType: .void, modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let child = JavaClassStub(
            binaryName: "Child", qualifiedName: "Child", simpleName: "Child", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            superclass: .classType(qualifiedName: "Base", arguments: [], outer: nil),
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [base, child])
        let (document, position) = document("class Child extends Base { void m() { € } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "greet();"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "greet();")
    }

    func testValidatorKeepsAnInheritedMemberWhenTheClassIsNotIndexed() async throws {
        let index = try await makeIndex(withStubs: [objectStub()])
        let (document, position) = document("class Test { void m() { € } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "toString();"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "toString();")
    }

    func testValidatorDropsAnInstanceMemberInsideAStaticMethod() async throws {
        let index = try await makeIndex(withStubs: [objectStub()])
        let (document, position) = document("class Test { static void m() { € } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "toString();"), in: document, at: position
        )
        XCTAssertNil(result)
    }

    func testValidatorRejectsAnUnknownBareName() async throws {
        let index = try await makeIndex(withStubs: [objectStub()])
        let (document, position) = document("class Test { void m() { € } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "frobnicate();"), in: document, at: position
        )
        XCTAssertNil(result)
    }

    func testValidatorKeepsAStarStaticImport() async throws {
        let math = JavaClassStub(
            binaryName: "java.lang.Math", qualifiedName: "java.lang.Math", simpleName: "Math", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(
                name: "max",
                parameters: [
                    JavaParameterStub(name: "a", type: .primitive(.int)),
                    JavaParameterStub(name: "b", type: .primitive(.int))
                ],
                returnType: .primitive(.int), modifiers: [.publicFlag, .staticFlag]
            )],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [math])
        let (document, position) = document("import static java.lang.Math.*; class Test { void m() { € } }")
        let result = await JavaCompletionProvider(index: index).validate(
            InlineSuggestion(text: "max(1, 2);"), in: document, at: position
        )
        XCTAssertEqual(result?.text, "max(1, 2);")
    }

    private func objectStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(
                name: "toString", parameters: [],
                returnType: .classType(qualifiedName: "java.lang.String", arguments: [], outer: nil),
                modifiers: [.publicFlag]
            )],
            origin: .jdkModule("test")
        )
    }
}

/// Controller-level: the ghost shows after typing, typing through consumes it, and the
/// accept action inserts it.
@MainActor
final class InlineCompletionControllerTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private final class OneShotModel: InlineCompletionModel, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0
        let text: String

        init(text: String) { self.text = text }

        func complete(_ request: InlineCompletionRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            callCount += 1
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    private func makeController(_ textView: TextView, model: OneShotModel) -> EditorIntelligenceController {
        let engine = InlineCompletionEngine(model: model, debounceInterval: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(inlineCompletionEngine: engine)
        )
        var settings = InlineCompletionSettings()
        settings.isEnabled = true
        settings.otherLanguagesEnabled = true
        controller.inlineCompletionSettings = settings
        return controller
    }

    private func makeTextView(_ text: String, caret: Int) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = text
        window.contentView = textView
        textView.selectedRange = NSRange(location: caret, length: 0)
        return textView
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1.5)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testGhostShowsTypesThroughAndAccepts() async throws {
        let model = OneShotModel(text: "get(0);")
        let textView = makeTextView("names", caret: 5)
        let controller = makeController(textView, model: model)
        try await Task.sleep(nanoseconds: 50_000_000)

        textView.insertText(".")
        try await waitFor { controller.hasInlineSuggestion }
        XCTAssertTrue(controller.hasInlineSuggestion)
        XCTAssertEqual(textView.inlineCompletion?.firstLine, "get(0);")

        // Typing through: the typed `g` is consumed from the ghost, no new request.
        textView.insertText("g")
        XCTAssertEqual(textView.text, "names.g")
        XCTAssertEqual(controller.inlineSuggestionFirstLine, "et(0);")
        XCTAssertEqual(model.callCount, 1)

        XCTAssertTrue(textView.perform(.acceptInlineProposal))
        XCTAssertEqual(textView.text, "names.get(0);")
        XCTAssertFalse(controller.hasInlineSuggestion)
    }

    func testMultiLineGhostReservesRoomAndAcceptsLineByLine() async throws {
        let model = OneShotModel(text: "first();\nsecond();\nthird();")
        let textView = makeTextView("start\nnext", caret: 5)
        let controller = makeController(textView, model: model)
        controller.inlineCompletionSettings.multiLineEnabled = true
        try await Task.sleep(nanoseconds: 50_000_000)

        let nextLineYBefore = textView.caretRectInViewport(at: 6).minY
        textView.insertText(";")
        try await waitFor { controller.hasInlineSuggestion }
        XCTAssertTrue(controller.hasInlineSuggestion)
        XCTAssertEqual(controller.inlineSuggestionFirstLine, "first();")
        XCTAssertEqual(textView.inlineCompletion?.extraLines, ["second();", "third();"])

        // The reserved room pushed the following line down by about two line heights.
        textView.layoutSubtreeIfNeeded()
        let nextLineYAfter = textView.caretRectInViewport(at: 7).minY
        XCTAssertGreaterThan(nextLineYAfter, nextLineYBefore + 10, "room reserved under the caret line")

        // ⌘→ accepts the current line; the next line becomes the new first ghost line.
        XCTAssertTrue(textView.perform(.acceptInlineProposalLine))
        XCTAssertEqual(textView.text, "start;first();\nnext")
        XCTAssertEqual(controller.inlineSuggestionFirstLine, "second();")

        // Tab (here the accept action) takes the rest.
        XCTAssertTrue(textView.perform(.acceptInlineProposal))
        XCTAssertEqual(textView.text, "start;first();second();\nthird();\nnext")
        XCTAssertFalse(controller.hasInlineSuggestion)

        // Clearing restored the layout.
        textView.layoutSubtreeIfNeeded()
        let restoredY = textView.caretRectInViewport(at: textView.text.count - 4).minY
        XCTAssertLessThan(restoredY, nextLineYAfter, "layout restored after the ghost went")
    }

    func testWordAcceptanceInsertsNextWord() async throws {
        let model = OneShotModel(text: "get(0);")
        let textView = makeTextView("names.", caret: 6)
        let controller = makeController(textView, model: model)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Move the caret somewhere and back to trigger a request through typing.
        textView.insertText("x")
        textView.deleteBackward()
        try await waitFor { controller.hasInlineSuggestion }
        XCTAssertTrue(controller.hasInlineSuggestion)

        XCTAssertTrue(textView.perform(.acceptInlineProposalWord))
        XCTAssertEqual(textView.text, "names.get(")
    }
}
