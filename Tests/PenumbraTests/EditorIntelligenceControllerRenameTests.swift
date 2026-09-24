import XCTest
import AppKit
import Penumbra
import EditorIntelligence

private final class MockRenameProvider: RenameProviding, @unchecked Sendable {
    var target: RenameTarget?
    var plan: RenamePlan
    private(set) var renameCalls: [String] = []

    init(target: RenameTarget?, plan: RenamePlan = RenamePlan()) {
        self.target = target
        self.plan = plan
    }

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? { target }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        renameCalls.append(newName)
        return plan
    }
}

@MainActor
final class EditorIntelligenceControllerRenameTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Foo.java")

    private func makeRange(_ start: Int, _ end: Int) -> EditorIntelligence.TextRange {
        EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: start, utf16Offset: start),
            end: TextPosition(line: 0, column: end, utf16Offset: end)
        )
    }

    private func makeController(provider: RenameProviding?) async throws -> (EditorIntelligenceController, TextView) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "class Foo {}"
        textView.selectedRange = NSRange(location: 7, length: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(renameProvider: provider)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        return (controller, textView)
    }

    private func entry(_ newText: String = "Bar", ambiguous: Bool = false, readOnly: Bool = false) -> RenamePlanEntry {
        RenamePlanEntry(
            url: url, range: makeRange(6, 9), oldText: "Foo", newText: newText,
            lineText: "class Foo {}", isAmbiguous: ambiguous, isReadOnly: readOnly
        )
    }

    func testRenameActionIsHandledWithoutProviderAndDoesNotPrompt() async throws {
        let (controller, textView) = try await makeController(provider: nil)
        var prompted = false
        controller.onRequestRename = { _, _ in prompted = true }
        XCTAssertTrue(textView.perform(.rename))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(prompted)
        withExtendedLifetime(controller) {}
    }

    func testPrepareReturningNilNeverPrompts() async throws {
        let provider = MockRenameProvider(target: nil)
        let (controller, _) = try await makeController(provider: provider)
        var prompted = false
        controller.onRequestRename = { _, _ in prompted = true }
        XCTAssertTrue(controller.rename())
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(prompted)
        XCTAssertTrue(provider.renameCalls.isEmpty)
    }

    func testCancelledPromptDoesNotPlan() async throws {
        let provider = MockRenameProvider(target: RenameTarget(range: makeRange(6, 9), currentName: "Foo"))
        let (controller, _) = try await makeController(provider: provider)
        controller.onRequestRename = { _, completion in completion(nil) }
        var presented = false
        controller.onPresentRenamePlan = { _, _ in presented = true }
        controller.rename()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(provider.renameCalls.isEmpty)
        XCTAssertFalse(presented)
    }

    func testBlockingErrorIsReportedAndPlanNotPresented() async throws {
        let provider = MockRenameProvider(
            target: RenameTarget(range: makeRange(6, 9), currentName: "Foo"),
            plan: RenamePlan(entries: [entry()], blockingError: "Overrides a library method")
        )
        let (controller, _) = try await makeController(provider: provider)
        controller.onRequestRename = { _, completion in completion("Bar") }
        var presented = false
        controller.onPresentRenamePlan = { _, _ in presented = true }
        var failure: String?
        controller.onRenameFailed = { failure = $0 }
        controller.rename()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(provider.renameCalls, ["Bar"])
        XCTAssertFalse(presented)
        XCTAssertEqual(failure, "Overrides a library method")
    }

    func testPlanIsPresentedAndApplyRunsThroughHost() async throws {
        let provider = MockRenameProvider(
            target: RenameTarget(range: makeRange(6, 9), currentName: "Foo", kindDescription: "class"),
            plan: RenamePlan(entries: [entry(), entry("Bar", ambiguous: true)])
        )
        let (controller, _) = try await makeController(provider: provider)
        var promptedTarget: RenameTarget?
        controller.onRequestRename = { target, completion in
            promptedTarget = target
            completion("Bar")
        }
        var presentedPlan: RenamePlan?
        var applyClosure: ((WorkspaceEdit) async -> WorkspaceEditApplyResult)?
        controller.onPresentRenamePlan = { plan, apply in
            presentedPlan = plan
            applyClosure = apply
        }
        var appliedEdit: WorkspaceEdit?
        let url = self.url
        controller.onApplyWorkspaceEdit = { edit in
            appliedEdit = edit
            return WorkspaceEditApplyResult(appliedFiles: [url])
        }
        controller.rename()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(promptedTarget?.currentName, "Foo")
        XCTAssertEqual(presentedPlan?.entries.count, 2)
        let plan = try XCTUnwrap(presentedPlan)
        let result = await applyClosure?(plan.workspaceEdit())
        XCTAssertEqual(result?.appliedFiles, [url])
        // The ambiguous entry is left out by default.
        XCTAssertEqual(appliedEdit?.editCount, 1)
        XCTAssertEqual(appliedEdit?.changes[url]?.first?.replacement, "Bar")
    }

    func testUnchangedNameIsIgnored() async throws {
        let provider = MockRenameProvider(target: RenameTarget(range: makeRange(6, 9), currentName: "Foo"))
        let (controller, _) = try await makeController(provider: provider)
        controller.onRequestRename = { _, completion in completion("Foo") }
        controller.rename()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(provider.renameCalls.isEmpty)
    }

    func testRenameTargetDefaultValidation() {
        let target = RenameTarget(range: makeRange(0, 1), currentName: "a")
        XCTAssertNotNil(target.validate(""))
        XCTAssertNotNil(target.validate("1abc"))
        XCTAssertNotNil(target.validate("a-b"))
        XCTAssertNil(target.validate("_ok$1"))
    }

    func testRenameIsBoundOnlyInIntelliJKeymap() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x61, .shift))), .rename)
        XCTAssertNil(Keymap.default_.stroke(for: .rename))
        XCTAssertEqual(EditorActionID.rename.title, "Rename…")
    }
}
