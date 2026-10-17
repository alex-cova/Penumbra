import XCTest
import AppKit
@testable import Penumbra
@testable import JavaIntelligence
import EditorIntelligence

final class CommandCompletionTests: XCTestCase {
    private func document(_ text: String, caret: Int, language: String? = nil) -> Document {
        let position = TextPosition(line: 0, column: caret, utf16Offset: caret)
        return Document(
            id: DocumentID(), url: URL(fileURLWithPath: "/tmp/Test.java"), displayName: "Test.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func context(_ text: String, caret: Int, mode: CompletionContext.CommandMode?) -> CompletionContext {
        let doc = document(text, caret: caret)
        let caret = doc.cursor.position
        return CompletionContext(
            document: doc, cursor: doc.cursor, trigger: .manual, prefix: "",
            range: TextRange(start: caret, end: caret), commandMode: mode
        )
    }

    // MARK: - Generic provider

    func testDotDotOffersEditorCommandsInCommandSection() async {
        let provider = EditorCommandCompletionProvider()
        let items = await provider.commandItems(context: context("foo..", caret: 5, mode: .dotDot))
        let labels = Set(items.map(\.label))
        XCTAssertTrue(labels.contains("Rename…"))
        XCTAssertTrue(labels.contains("Go to Definition"))
        XCTAssertTrue(labels.contains("Optimize Imports"))
        XCTAssertTrue(items.allSatisfy { $0.kind == .command && $0.section == .commands && $0.command != nil })
    }

    func testReadOnlyOffersNavigationAndCopyReferenceOnly() async {
        let box = CommandCompletionSettingsBox(CommandCompletionSettings(readOnlyEnabled: true))
        let provider = EditorCommandCompletionProvider(settingsBox: box)
        let items = await provider.commandItems(context: context("foo.", caret: 4, mode: .readOnly))
        let labels = Set(items.map(\.label))
        XCTAssertEqual(labels, ["Go to Definition", "Go to Implementation(s)", "Go to Type Declaration", "Find Usages", "Type Hierarchy", "Quick Documentation", "Copy Reference"])
    }

    func testReadOnlyDisabledByDefault() async {
        let provider = EditorCommandCompletionProvider()
        let items = await provider.commandItems(context: context("foo.", caret: 4, mode: .readOnly))
        XCTAssertEqual(items, [])
    }

    func testSeparateGroupOffSuppressesSingleDotCommands() async {
        let box = CommandCompletionSettingsBox(CommandCompletionSettings(showsSeparateGroup: false))
        let provider = EditorCommandCompletionProvider(settingsBox: box)
        let items = await provider.commandItems(context: context("foo.", caret: 4, mode: .singleDot))
        XCTAssertEqual(items, [])
    }

    func testCodeActionPreviewShowsChangedLines() async {
        let doc = document("int x = 1;", caret: 0)
        let position = TextPosition(line: 0, column: 4, utf16Offset: 4)
        let action = CodeAction(title: "Rename x", edits: [
            TextEdit(range: TextRange(start: position, end: TextPosition(line: 0, column: 5, utf16Offset: 5)), replacement: "y")
        ])
        let preview = EditorCommandCompletionProvider.preview(of: action, in: doc)
        XCTAssertEqual(preview, "Rename x\n- x\n+ y")
    }

    // MARK: - Engine ordering

    private struct MixedProvider: CompletionProvider {
        let name = "Mixed"
        func provide(context: CompletionContext) async -> [CompletionItem] {
            [
                CompletionItem(
                    label: "Aardvark", insertText: "", kind: .command, range: context.range, source: name,
                    command: .editorAction(id: "rename", selecting: nil), section: .commands
                ),
                CompletionItem(label: "zebra", insertText: "zebra", kind: .variable, range: context.range, source: name)
            ]
        }
    }

    func testCommandSectionSortsLast() async throws {
        let engine = CompletionEngine(providers: [MixedProvider()], debounceInterval: 0)
        let items = try await engine.complete(context: context("x", caret: 1, mode: .dotDot))
        XCTAssertEqual(items.map(\.label), ["zebra", "Aardvark"])
    }

    // MARK: - Java targets

    private func javaContext(_ source: String, mode: CompletionContext.CommandMode) -> CompletionContext {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let doc = document(text, caret: offset, language: "java")
        return makeCompletionContext(document: doc, trigger: .manual, commandMode: mode)
    }

    func testJavaDotDotSelectsReceiverExpression() async {
        let source = "class Test { void m() { String foo = \"x\"; foo..€ } }"
        let items = await JavaCompletionProvider(index: JavaIndex()).provide(context: javaContext(source, mode: .dotDot))
        let extract = items.first { $0.label == "Extract Variable…" }
        let item = try? XCTUnwrap(extract)
        XCTAssertNotNil(item)
        guard case .editorAction(_, let selecting) = item?.command, let selecting else {
            XCTFail("expected an editor action with a selection")
            return
        }
        let text = source.replacingOccurrences(of: "€", with: "") as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: selecting.start.utf16Offset, length: selecting.end.utf16Offset - selecting.start.utf16Offset)),
            "foo"
        )
    }

    func testJavaDotDotAfterForBlockSelectsStatement() async {
        let source = "class Test { void m() { for (int i = 0; i < 3; i++) { work(); }..€ } void work() {} }"
        let items = await JavaCompletionProvider(index: JavaIndex()).provide(context: javaContext(source, mode: .dotDot))
        let extract = items.first { $0.label == "Extract Method…" }
        guard case .editorAction(_, let selecting) = extract?.command, let selecting else {
            XCTFail("expected Extract Method with a block selection, got \(items.map(\.label))")
            return
        }
        let text = source.replacingOccurrences(of: "€", with: "") as NSString
        let selected = text.substring(with: NSRange(location: selecting.start.utf16Offset, length: selecting.end.utf16Offset - selecting.start.utf16Offset))
        XCTAssertTrue(selected.hasPrefix("for ("), "selected: \(selected)")
        XCTAssertTrue(selected.hasSuffix("}"), "selected: \(selected)")
    }

    func testStatementBlockRangeRejectsMethodBody() {
        let bytes = Array("class Test { void m() { work(); }..".utf8)
        XCTAssertNil(JavaCompletionProvider.statementBlockRange(beforeDotAt: bytes.count - 1, bytes: bytes))
    }

    func testASecondDotIsNotMemberAccess() throws {
        let source = "class Test { void m() { String s = \"x\"; s.. } }"
        let bytes = Array(source.utf8)
        let prefixStart = (source as NSString).range(of: "s..").location + 3
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let site = JavaCompletionContextClassifier.classify(bytes: bytes, tree: tree, prefixStart: prefixStart)
        if case .memberAccess = site {
            XCTFail("s.. is command completion, classified as \(site)")
        }
    }

    func testASingleDotStaysMemberAccess() throws {
        let source = "class Test { void m() { String s = \"x\"; s. } }"
        let bytes = Array(source.utf8)
        let prefixStart = (source as NSString).range(of: "s.").location + 2
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let site = JavaCompletionContextClassifier.classify(bytes: bytes, tree: tree, prefixStart: prefixStart)
        guard case .memberAccess = site else {
            XCTFail("s. classified as \(site)")
            return
        }
    }

    func testJavaDotDotAfterAForOnThePreviousLineSelectsTheStatement() async {
        let source = """
        class Test { void m() {
            for (int i = 0; i < 3; i++) {
                tick();
            }
            ..€
        } void tick() {} }
        """
        let selected = await selectedText(of: "Extract Method…", in: source)
        XCTAssertEqual(selected?.hasPrefix("for (int i = 0; i < 3; i++) {"), true, "selected: \(selected ?? "nil")")
        XCTAssertEqual(selected?.contains("tick();"), true, "selected: \(selected ?? "nil")")
        XCTAssertEqual(selected?.hasSuffix("}"), true, "selected: \(selected ?? "nil")")
        XCTAssertEqual(selected?.contains("void m"), false, "selected: \(selected ?? "nil")")
    }

    func testABraceInsideAStringDoesNotStealTheForStatement() async {
        let source = "class Test { void m() { for (int i = 0; i < 3; i++) { String s = \"}\"; }..€ } }"
        let selected = await selectedText(of: "Extract Method…", in: source)
        XCTAssertEqual(selected, "for (int i = 0; i < 3; i++) { String s = \"}\"; }")
    }

    /// The text of the range attached to `label` for a `..` completion of `source` (`€` is the caret).
    private func selectedText(of label: String, in source: String) async -> String? {
        let items = await JavaCompletionProvider(index: JavaIndex()).provide(context: javaContext(source, mode: .dotDot))
        guard case .editorAction(_, let selecting) = items.first(where: { $0.label == label })?.command, let selecting else {
            return nil
        }
        let text = source.replacingOccurrences(of: "€", with: "") as NSString
        return text.substring(with: NSRange(
            location: selecting.start.utf16Offset, length: selecting.end.utf16Offset - selecting.start.utf16Offset
        ))
    }

    // MARK: - Copy Reference

    func testJavaSymbolReference() async {
        let source = "package com.example;\nclass Widget {\n    int count;\n    void render(int width) {}\n}\n"
        let provider = JavaSymbolReferenceProvider(index: JavaIndex())
        func reference(at needle: String) async -> String? {
            let range = (source as NSString).range(of: needle)
            let doc = document(source, caret: range.location + 1, language: "java")
            return await provider.symbolReference(for: doc, at: doc.cursor.position)
        }
        let method = await reference(at: "render")
        XCTAssertEqual(method, "com.example.Widget#render(int)")
        let field = await reference(at: "count")
        XCTAssertEqual(field, "com.example.Widget.count")
        let type = await reference(at: "Widget")
        XCTAssertEqual(type, "com.example.Widget")
    }
}

/// Controller-level `..`: typing the second dot opens commands, and accepting one deletes
/// both dots and the filter text instead of inserting anything.
@MainActor
final class CommandCompletionControllerTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private struct CommandStub: CompletionProvider {
        let name = "CommandStub"
        func provide(context: CompletionContext) async -> [CompletionItem] {
            guard context.commandMode == .dotDot else { return [] }
            return [CompletionItem(
                label: "Rename…", insertText: "", kind: .command, range: context.range, source: name,
                allowsAutoInsert: false,
                command: .editorAction(id: EditorActionID.rename.rawValue, selecting: nil), section: .commands
            )]
        }
    }

    func testDotDotAcceptDeletesTriggerDots() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = "foo"
        window.contentView = textView
        textView.selectedRange = NSRange(location: 3, length: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [CommandStub()], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        textView.insertText(".")
        textView.insertText(".")
        let deadline = Date().addingTimeInterval(1.5)
        while !controller.isShowingCompletion, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isShowingCompletion, "items: \(controller.visibleCompletionItems.map(\.label))")
        XCTAssertTrue(controller.visibleCompletionItems.contains { $0.label == "Rename…" })

        controller.acceptSelectedCompletion()
        XCTAssertEqual(textView.text, "foo")
    }
}
