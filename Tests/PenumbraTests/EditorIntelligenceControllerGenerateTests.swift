import XCTest
import AppKit
import Penumbra
import EditorIntelligence

private final class MockCodeGenerationProvider: CodeGenerationProviding, @unchecked Sendable {
    var menu: CodeGenerationMenu?
    let url: URL
    private(set) var generated: [(CodeGenerationKind, [String])] = []

    init(menu: CodeGenerationMenu?, url: URL) {
        self.menu = menu
        self.url = url
    }

    func generationMenu(_ context: RefactoringContext) async -> CodeGenerationMenu? { menu }

    func generate(
        _ kind: CodeGenerationKind, fieldNames: [String], context: RefactoringContext
    ) async -> WorkspaceEditPlan {
        generated.append((kind, fieldNames))
        let end = context.document.contentSnapshot.utf16Length
        let position = TextPosition(line: 0, column: end, utf16Offset: end)
        let entry = WorkspaceEditPlanEntry(
            url: url, range: EditorIntelligence.TextRange(start: position, end: position),
            oldText: "", newText: "\n// \(kind.rawValue): \(fieldNames.joined(separator: ","))", lineText: ""
        )
        return WorkspaceEditPlan(entries: [entry], title: "Generate")
    }
}

@MainActor
final class EditorIntelligenceControllerGenerateTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Foo.java")
    private let menu = CodeGenerationMenu(typeName: "Foo", options: [
        CodeGenerationOption(kind: .constructor, title: "Constructor", fields: [
            CodeGenerationField(name: "a", typeText: "int"), CodeGenerationField(name: "b", typeText: "String")
        ], allowsEmptySelection: true)
    ])

    private func makeController(
        provider: (any CodeGenerationProviding)?
    ) async throws -> (EditorIntelligenceController, TextView) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.documentURL = url
        textView.text = "class Foo {}"
        textView.selectedRange = NSRange(location: 7, length: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(codeGenerationProvider: provider)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        return (controller, textView)
    }

    func testGenerateActionPromptsWithTheMenuAndAppliesThePickedEdit() async throws {
        let provider = MockCodeGenerationProvider(menu: menu, url: url)
        let (controller, textView) = try await makeController(provider: provider)
        var offered: CodeGenerationMenu?
        controller.onRequestGeneration = { menu, completion in
            offered = menu
            completion(CodeGenerationChoice(kind: .constructor, fieldNames: ["a", "b"]))
        }
        XCTAssertTrue(textView.perform(.generate))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(offered?.typeName, "Foo")
        XCTAssertEqual(provider.generated.count, 1)
        XCTAssertEqual(provider.generated.first?.1, ["a", "b"])
        XCTAssertEqual(textView.text, "class Foo {}\n// constructor: a,b")
        withExtendedLifetime(controller) {}
    }

    func testCancellingThePromptGeneratesNothing() async throws {
        let provider = MockCodeGenerationProvider(menu: menu, url: url)
        let (controller, textView) = try await makeController(provider: provider)
        controller.onRequestGeneration = { _, completion in completion(nil) }
        XCTAssertTrue(controller.generate())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(provider.generated.isEmpty)
        XCTAssertEqual(textView.text, "class Foo {}")
    }

    func testNoMenuNeverPrompts() async throws {
        let provider = MockCodeGenerationProvider(menu: nil, url: url)
        let (controller, _) = try await makeController(provider: provider)
        var prompted = false
        controller.onRequestGeneration = { _, _ in prompted = true }
        XCTAssertTrue(controller.generate())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(prompted)
    }

    func testGenerateIsHandledWithoutAProvider() async throws {
        let (controller, textView) = try await makeController(provider: nil)
        var prompted = false
        controller.onRequestGeneration = { _, _ in prompted = true }
        XCTAssertTrue(textView.perform(.generate))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(prompted)
        withExtendedLifetime(controller) {}
    }
}
