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
