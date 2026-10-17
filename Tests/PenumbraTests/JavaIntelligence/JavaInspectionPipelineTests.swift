import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// The service, suppression and quick-fix path for the syntactic rules, end to end.
final class JavaInspectionPipelineTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func document(_ source: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    /// Every rule except the ones that need a populated index (an empty one cannot resolve `String`).
    private let indexFreeRules = Set(JavaInspectionRule.allCases).subtracting([.unresolvedType, .unresolvedImport])

    private func analyze(
        _ source: String,
        enabled: Set<JavaInspectionRule>? = nil,
        severities: [JavaInspectionRule: JavaInspection.Severity] = [:]
    ) async -> [Diagnostic] {
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: enabled ?? indexFreeRules, idleDelay: .milliseconds(10))
        await service.setSeverityOverrides(severities)
        let box = DiagnosticBox()
        await service.setResultHandler { _, diagnostics in box.set(diagnostics) }
        await service.analyzeNow(document(source), force: true)
        return box.value
    }

    private let comparing = """
    class T {
        boolean f(String a, String b) {
            return a == b;
        }
    }
    """

    func testNewRulesReachTheDiagnosticsWithTheirDefaultSeverity() async {
        let diagnostics = await analyze(comparing)
        XCTAssertEqual(diagnostics.map(\.code), ["string-comparison-identity"])
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.source, "java-inspection")
    }

    func testADisabledRuleProducesNothing() async {
        let enabled = indexFreeRules.subtracting([.stringComparisonIdentity])
        let diagnostics = await analyze(comparing, enabled: enabled)
        XCTAssertEqual(diagnostics.map(\.code), [])
    }

    func testSeverityOverridesApplyToAnyRule() async {
        let weak = await analyze(comparing, severities: [.stringComparisonIdentity: .weakWarning])
        XCTAssertEqual(weak.first?.severity, .hint)
        let error = await analyze(comparing, severities: [.stringComparisonIdentity: .error])
        XCTAssertEqual(error.first?.severity, .error)
        let info = await analyze(comparing, severities: [.stringComparisonIdentity: .info])
        XCTAssertEqual(info.first?.severity, .information)
    }

    func testSuppressWarningsAndNoinspectionSilenceNewRules() async {
        let annotated = """
        class T {
            @SuppressWarnings("string-comparison-identity")
            boolean f(String a, String b) {
                return a == b;
            }
        }
        """
        let annotatedDiagnostics = await analyze(annotated)
        XCTAssertEqual(annotatedDiagnostics.map(\.code), [])
        let commented = """
        class T {
            boolean f(String a, String b) {
                //noinspection string-comparison-identity
                return a == b;
            }
        }
        """
        let commentedDiagnostics = await analyze(commented)
        XCTAssertEqual(commentedDiagnostics.map(\.code), [])
    }

    func testCodeActionsOfferTheRuleFixOnTheCaretLine() async throws {
        let diagnostics = await analyze(comparing)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        let provider = JavaCodeActionProvider(index: JavaIndex())
        let actions = await provider.codeActions(for: document(comparing), at: diagnostic.range.start, diagnostics: diagnostics)
        let fix = try XCTUnwrap(actions.first { $0.title == "Replace with 'equals()'" })
        XCTAssertTrue(fix.isPreferred)
        var text = comparing as NSString
        for edit in fix.edits {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        XCTAssertTrue((text as String).contains("return a.equals(b);"))
        // The generic Suppress fixes are offered next to it.
        XCTAssertTrue(actions.contains { $0.title.hasPrefix("Suppress 'string-comparison-identity'") })
    }

    func testNoHighlightingKeepsTheFixButPublishesNothing() async throws {
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: indexFreeRules, idleDelay: .milliseconds(10))
        await service.setSeverityOverrides([.stringComparisonIdentity: .noHighlighting])
        let box = DiagnosticBox()
        await service.setResultHandler { _, diagnostics in box.set(diagnostics) }
        await service.analyzeNow(document(comparing), force: true)
        XCTAssertEqual(box.value.map(\.code), [])
        let quiet = await service.quietFindings(for: url)
        XCTAssertEqual(quiet.map(\.code), ["string-comparison-identity"])
        let provider = JavaCodeActionProvider(index: JavaIndex())
        await provider.setQuietFindingsSource { [service] url in await service.quietFindings(for: url) }
        let actions = await provider.codeActions(for: document(comparing), at: quiet[0].range.start, diagnostics: [])
        XCTAssertTrue(actions.contains { $0.title == "Replace with 'equals()'" })
        XCTAssertTrue(actions.contains { $0.command?.id == JavaInspectionCommand.disable })
    }

    func testProfileScopeSilencesARuleOnlyInTests() async throws {
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: indexFreeRules, idleDelay: .milliseconds(10))
        var profile = JavaInspectionProfile.standard()
        profile.setEnabled(false, for: .unresolvedType)
        profile.setEnabled(false, for: .unresolvedImport)
        profile.scopedOverrides = [.init(code: "string-comparison-identity", scope: .tests, isEnabled: false)]
        await service.setProfile(profile, projectRoot: URL(fileURLWithPath: "/proj"), testRoots: [URL(fileURLWithPath: "/proj/t")])
        let box = DiagnosticBox()
        await service.setResultHandler { _, diagnostics in box.set(diagnostics) }
        await service.analyzeNow(document(comparing), force: true)
        XCTAssertEqual(box.value.map(\.code), ["string-comparison-identity"])
        await service.setProfile(profile, projectRoot: URL(fileURLWithPath: "/"), testRoots: [URL(fileURLWithPath: "/proj")])
        await service.analyzeNow(document(comparing), force: true)
        XCTAssertEqual(box.value.map(\.code), [])
    }

    func testFixAllInFileIsOfferedWhenARuleHasSeveralFindings() async throws {
        let twice = """
        class T {
            boolean f(String a, String b) { return a == b; }
            boolean g(String a, String b) { return a == b; }
        }
        """
        let diagnostics = await analyze(twice)
        XCTAssertEqual(diagnostics.count, 2)
        let provider = JavaCodeActionProvider(index: JavaIndex())
        let actions = await provider.codeActions(for: document(twice), at: diagnostics[0].range.start, diagnostics: diagnostics)
        let all = try XCTUnwrap(actions.first { $0.kind == "quickfix.fixAll" })
        XCTAssertEqual(all.edits.count, 2)
    }

    func testMigrationRulesFollowTheLanguageLevelTheHostSupplies() async throws {
        let source = "class T {\n    boolean f(java.util.Optional<String> o) { return !o.isPresent(); }\n}\n"
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: indexFreeRules, idleDelay: .milliseconds(10))
        let box = DiagnosticBox()
        await service.setResultHandler { _, diagnostics in box.set(diagnostics) }

        // No resolver: the level is unknown and the rule stays silent.
        await service.analyzeNow(document(source), force: true)
        XCTAssertFalse(box.value.contains { $0.code == "optional-is-empty" })

        await service.setLanguageLevelResolver { _ in 8 }
        await service.analyzeNow(document(source), force: true)
        XCTAssertFalse(box.value.contains { $0.code == "optional-is-empty" })

        await service.setLanguageLevelResolver { _ in 17 }
        await service.analyzeNow(document(source), force: true)
        XCTAssertTrue(box.value.contains { $0.code == "optional-is-empty" })
    }

    func testRepeatedIdleRefreshStartsExactlyOnePass() async throws {
        // With a zero idle delay every refresh would otherwise cancel and restart the running
        // pass; same-text refreshes must join it instead, while a new text still supersedes it.
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: [.unusedImport], idleDelay: .zero)
        let calls = PassCounter()
        await service.setResultHandler { _, _ in calls.increment() }
        let source = """
        import java.util.List;
        class T {
            void f() {}
        }
        """
        _ = await service.diagnostics(for: document(source))
        _ = await service.diagnostics(for: document(source))
        _ = await service.diagnostics(for: document(source))
        let deadline = Date().addingTimeInterval(5)
        while calls.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Let a restarted duplicate land if the skip failed.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.count, 1, "same-text refreshes join the running pass instead of restarting it")

        _ = await service.diagnostics(for: document(source + "\n// typed\n"))
        let secondDeadline = Date().addingTimeInterval(5)
        while calls.count < 2, Date() < secondDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calls.count, 2, "a changed text still supersedes the pass")
    }

    func testSupersededPassNeverPublishes() async throws {
        // A is still waiting out its idle delay when B supersedes it: only B's result
        // may reach the cache and the result handler, never A's.
        let service = JavaInspectionService(index: JavaIndex(), enabledRules: [.unusedImport], idleDelay: .milliseconds(200))
        let calls = PassCounter()
        let box = DiagnosticBox()
        await service.setResultHandler { _, diagnostics in
            calls.increment()
            box.set(diagnostics)
        }
        _ = await service.diagnostics(for: document("import java.util.List;\nclass T {}\n"))
        _ = await service.diagnostics(for: document("class T {}\n"))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(box.value.map(\.code), [])
    }

    func testImportWarningsSurviveASyntaxErrorElsewhereInTheFile() async {
        // Half-typed statement while typing: the tree has an ERROR node, but the import
        // list is unaffected, so the unused imports must still be reported.
        let source = """
        import java.util.List;
        import java.util.ArrayList;
        class T {
            void f() {
                foo(
            }
        }
        """
        let diagnostics = await analyze(source)
        XCTAssertEqual(diagnostics.map(\.code), ["unused-import", "unused-import"])
    }

    func testDuplicateImportSurvivesASyntaxErrorElsewhereInTheFile() async {
        let source = """
        import java.util.List;
        import java.util.List;
        class T {
            void f() {
                foo(
            }
        }
        """
        let diagnostics = await analyze(source)
        XCTAssertTrue(diagnostics.contains { $0.code == "duplicate-import" })
    }

    func testNoFixIsOfferedAwayFromTheDiagnostic() async throws {
        let diagnostics = await analyze(comparing)
        let provider = JavaCodeActionProvider(index: JavaIndex())
        let actions = await provider.codeActions(
            for: document(comparing), at: TextPosition(line: 0, column: 0, utf16Offset: 0), diagnostics: diagnostics
        )
        XCTAssertFalse(actions.contains { $0.title == "Replace with 'equals()'" })
    }
}

private final class DiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Diagnostic] = []
    func set(_ diagnostics: [Diagnostic]) { lock.lock(); stored = diagnostics; lock.unlock() }
    var value: [Diagnostic] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Counts result-handler deliveries, so a test can tell one pass from a restarted duplicate.
private final class PassCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
}
