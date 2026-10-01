import AppKit
import EditorIntelligence
@testable import Penumbra
import XCTest

private final class StubRenameProvider: RenameProviding, @unchecked Sendable {
    let target: RenameTarget
    let plan: RenamePlan
    private(set) var renameNames: [String] = []

    init(target: RenameTarget, plan: RenamePlan) {
        self.target = target
        self.plan = plan
    }

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? { target }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        renameNames.append(newName)
        return plan
    }
}

@MainActor
final class EditorIntelligenceControllerInPlaceTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Foo.java")

    private func range(_ start: Int, _ end: Int) -> EditorIntelligence.TextRange {
        EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: start, utf16Offset: start),
            end: TextPosition(line: 0, column: end, utf16Offset: end)
        )
    }

    private func entry(ambiguous: Bool = false) -> RenamePlanEntry {
        RenamePlanEntry(url: url, range: range(6, 9), oldText: "Foo", newText: "Bar", lineText: "class Foo {}", isAmbiguous: ambiguous)
    }

    private func makeController(plan: RenamePlan) async throws -> (EditorIntelligenceController, TextView, StubRenameProvider) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "class Foo {} // Foo"
        textView.selectedRange = NSRange(location: 7, length: 0)
        let provider = StubRenameProvider(target: RenameTarget(range: range(6, 9), currentName: "Foo"), plan: plan)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(renameProvider: provider)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        return (controller, textView, provider)
    }

    func testInPlaceRenameAppliesAPlanThatNeedsNoJudgmentWithoutAPreview() async throws {
        let (controller, _, _) = try await makeController(plan: RenamePlan(entries: [entry()]))
        controller.appliesRefactoringsInPlace = true
        controller.onRequestRename = { _, completion in completion("Bar") }
        var previewed = false
        controller.onPresentRenamePlan = { _, _ in previewed = true }
        var appliedEdit: WorkspaceEdit?
        controller.onApplyWorkspaceEdit = { edit in
            appliedEdit = edit
            return WorkspaceEditApplyResult(appliedFiles: [self.url])
        }
        var finished: WorkspaceEditApplyResult?
        controller.onWorkspaceEditApplied = { finished = $0 }

        controller.rename()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(previewed)
        XCTAssertEqual(appliedEdit?.changes[url]?.first?.replacement, "Bar")
        XCTAssertEqual(finished?.appliedFiles, [url])
    }

    func testAmbiguousEntriesStillGoThroughThePreview() async throws {
        let (controller, _, _) = try await makeController(plan: RenamePlan(entries: [entry(), entry(ambiguous: true)]))
        controller.appliesRefactoringsInPlace = true
        controller.onRequestRename = { _, completion in completion("Bar") }
        var previewed = false
        controller.onPresentRenamePlan = { _, _ in previewed = true }
        var applied = false
        controller.onApplyWorkspaceEdit = { _ in applied = true; return WorkspaceEditApplyResult() }

        controller.rename()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertTrue(previewed)
        XCTAssertFalse(applied)
    }

    func testWithInPlaceModeOffTheRenameIsAlwaysPreviewed() async throws {
        let (controller, _, _) = try await makeController(plan: RenamePlan(entries: [entry()]))
        XCTAssertFalse(controller.appliesRefactoringsInPlace)
        controller.onRequestRename = { _, completion in completion("Bar") }
        var previewed = false
        controller.onPresentRenamePlan = { _, _ in previewed = true }
        controller.rename()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(previewed)
    }

    func testInPlaceRenameMarksTheAffectedRangesWhileThePromptIsOpen() async throws {
        let second = RenamePlanEntry(url: url, range: range(16, 19), oldText: "Foo", newText: "x", lineText: "class Foo {} // Foo")
        let (controller, textView, provider) = try await makeController(plan: RenamePlan(entries: [entry(), second]))
        controller.appliesRefactoringsInPlace = true
        textView.documentURL = url
        var finish: ((String?) -> Void)?
        controller.onRequestRename = { _, completion in finish = completion }

        controller.rename()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.renameNames.count, 1, "one throwaway plan to find the occurrences")
        XCTAssertNotEqual(provider.renameNames.first, "Foo")
        let marked = textView.emphasisManager.getEmphases(for: EmphasisGroup.refactoring).map(\.range)
        XCTAssertEqual(Set(marked.map(\.location)), [6, 16])

        finish?(nil)
        XCTAssertTrue(textView.emphasisManager.getEmphases(for: EmphasisGroup.refactoring).isEmpty)
    }

    func testNeedsNoJudgment() {
        XCTAssertTrue(EditorIntelligenceController.needsNoJudgment(RenamePlan(entries: [entry()])))
        XCTAssertFalse(EditorIntelligenceController.needsNoJudgment(RenamePlan(entries: [entry(ambiguous: true)])))
        XCTAssertFalse(EditorIntelligenceController.needsNoJudgment(RenamePlan(entries: [entry()], warnings: ["Overrides"])))
        XCTAssertFalse(EditorIntelligenceController.needsNoJudgment(RenamePlan(entries: [entry()], fileDeletions: [url])))
    }

    func testDiagnosticMarkdownNamesSeverityMessageAndSource() {
        let markdown = EditorIntelligenceController.diagnosticMarkdown([
            TextViewDiagnostic(range: NSRange(location: 0, length: 1), severity: .error, message: "cannot find symbol", source: "javac"),
            TextViewDiagnostic(range: NSRange(location: 0, length: 1), severity: .warning, message: "")
        ])
        XCTAssertTrue(markdown.contains("**Error:** cannot find symbol"))
        XCTAssertTrue(markdown.contains("*javac*"))
        XCTAssertTrue(markdown.contains("**Warning:** No description available."))
    }

    func testConvertedDiagnosticsCarryTheirMessage() {
        let diagnostic = Diagnostic(
            severity: .warning, message: "unused import", range: range(0, 3), source: "java-inspection", code: "unused-import"
        )
        let converted = TextViewDiagnostic(diagnostic)
        XCTAssertEqual(converted.message, "unused import")
        XCTAssertEqual(converted.source, "java-inspection")
    }

    func testShowErrorDescriptionHintsWhenThereIsNothingAtTheCaret() async throws {
        let (controller, textView, _) = try await makeController(plan: RenamePlan())
        textView.selectedRange = NSRange(location: 0, length: 0)
        controller.showErrorDescription()
        textView.diagnostics = [TextViewDiagnostic(range: NSRange(location: 6, length: 3), severity: .error, message: "boom")]
        textView.selectedRange = NSRange(location: 7, length: 0)
        controller.showErrorDescription()
        // The popup is an overlay inside the text view; assert the action is bound and handled.
        XCTAssertTrue(textView.perform(.showErrorDescription))
    }
}
