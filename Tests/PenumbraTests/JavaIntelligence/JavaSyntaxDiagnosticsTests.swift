import EditorIntelligence
import LanguageSyntax
import XCTest
@testable import JavaIntelligence

/// The `java-syntax` provider, the overlap filter and the composite from
/// `Sources/JavaIntelligence/Diagnostics/JavaSyntaxDiagnostics.swift`.
final class JavaSyntaxDiagnosticsTests: XCTestCase {
    private func makeDocument(
        text: String,
        url: URL? = URL(fileURLWithPath: "/proj/Foo.java"),
        language: String? = "java"
    ) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: url, displayName: url?.lastPathComponent ?? "Untitled.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func makeDiagnostic(line: Int, message: String, source: String = "javac") -> Diagnostic {
        Diagnostic(
            severity: .error,
            message: message,
            range: TextRange(
                start: TextPosition(line: line, column: 0, utf16Offset: 0),
                end: TextPosition(line: line, column: 1, utf16Offset: 1)
            ),
            source: source
        )
    }

    func testProviderReportsMissingSemicolon() async {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let document = makeDocument(text: "class Foo {\n    void m() {\n        int x = 1\n    }\n}\n")
        let diagnostics = await provider.diagnostics(for: document)
        XCTAssertFalse(diagnostics.isEmpty)
        for diagnostic in diagnostics {
            XCTAssertEqual(diagnostic.severity, .error)
            XCTAssertEqual(diagnostic.source, "java-syntax")
            XCTAssertEqual(diagnostic.code, "syntax")
            XCTAssertTrue(diagnostic.message.hasSuffix("expected"), "got: \(diagnostic.message)")
            XCTAssertGreaterThan(diagnostic.range.end.utf16Offset, diagnostic.range.start.utf16Offset)
        }
        XCTAssertTrue(diagnostics.contains { $0.message == "';' expected" })
    }

    func testProviderServesUntitledBuffers() async {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let document = makeDocument(text: "class Foo {\n    void m() {\n        int x = 1\n    }\n}\n", url: nil)
        let untitled = await provider.diagnostics(for: document)
        XCTAssertFalse(untitled.isEmpty)
    }

    func testProviderIgnoresOtherLanguages() async {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let document = makeDocument(
            text: "class Foo {\n    void m() {\n        int x = 1\n    }\n}\n",
            url: URL(fileURLWithPath: "/proj/foo.py"), language: "python"
        )
        let diagnostics = await provider.diagnostics(for: document)
        XCTAssertEqual(diagnostics, [])
    }

    func testProviderIsQuietForCleanFiles() async {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let document = makeDocument(text: "class Foo {\n    void m() {\n        int x = 1;\n    }\n}\n")
        let diagnostics = await provider.diagnostics(for: document)
        XCTAssertEqual(diagnostics, [])
    }

    // MARK: - Missing `;` spilling onto the next line

    func testSpilledMissingSemicolonLandsOnItsOwnLine() async throws {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    void m() {\n        system.out.println(\"kekw\")\n        System.out.println(\"---\");\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertEqual(diagnostics.map(\.message), ["';' expected"])
        let row = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(row.range.start.line, 2, "the `system...` line, not the `System...` line")
        XCTAssertEqual(row.severity, .error)
    }

    func testSameLineRecoveryKeepsGenericRow() async {
        // `int x = 5` followed by another line: the recovery errors at `5` itself, on the
        // statement's own line. No spillover, so the generic row stands as is.
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    void m() {\n        int x = 5\n        foo();\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertFalse(diagnostics.isEmpty)
        for diagnostic in diagnostics {
            XCTAssertEqual(diagnostic.range.start.line, 2)
            XCTAssertNotEqual(diagnostic.message, "';' expected")
        }
    }

    func testSameLineRecoveryAfterReturnKeepsGenericRow() async {
        // Same boundary after `return`: the error is already on the statement's line.
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    int m() {\n        return foo()\n        bar();\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertFalse(diagnostics.isEmpty)
        for diagnostic in diagnostics {
            XCTAssertEqual(diagnostic.range.start.line, 2)
            XCTAssertNotEqual(diagnostic.message, "';' expected")
        }
    }

    func testSameLineJuxtapositionKeepsGenericRow() async {
        // No spillover: the generic row stands, on the statement's own line.
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    void m() {\n        foo() bar();\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertFalse(diagnostics.isEmpty)
        for diagnostic in diagnostics {
            XCTAssertEqual(diagnostic.range.start.line, 2)
            XCTAssertNotEqual(diagnostic.message, "';' expected")
        }
    }

    func testUnclosedParenIsNotASemicolon() async {
        // A missing `)` is a different breakage: never rewritten to `';' expected`.
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    void m() {\n        foo(\"x\"\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertFalse(diagnostics.contains { $0.message == "';' expected" }, "\(diagnostics.map(\.message))")
    }

    func testMultilineCallStaysSilent() async {
        let cache = JavaDocumentParseCache()
        let provider = JavaSyntaxDiagnostics.provider(cache: cache)
        let text = "class Foo {\n    void m() {\n        foo(\n            1,\n            2);\n    }\n}\n"
        let diagnostics = await provider.diagnostics(for: makeDocument(text: text))
        XCTAssertEqual(diagnostics, [])
    }

    func testOverlapDropsRestatedParserErrors() {
        let syntax = [makeDiagnostic(line: 1, message: "';' expected", source: "java-syntax")]
        let javac = [
            makeDiagnostic(line: 1, message: "';' expected"),
            makeDiagnostic(line: 1, message: "cannot find symbol"),
            makeDiagnostic(line: 4, message: "';' expected"),
        ]
        let filtered = JavaParserErrorOverlap.filter(javac: javac, syntax: syntax)
        XCTAssertEqual(filtered.map(\.message), ["cannot find symbol", "';' expected"])
    }

    func testOverlapRecognizesParserErrorShapes() {
        for message in [
            "';' expected",
            "illegal start of expression",
            "reached end of file while parsing",
            "not a statement",
            "unclosed string literal",
            "'else' without 'if'",
            "orphaned default clause",
        ] {
            XCTAssertTrue(JavaParserErrorOverlap.isParserError(message), "not recognized: \(message)")
        }
        XCTAssertFalse(JavaParserErrorOverlap.isParserError("cannot find symbol"))
        XCTAssertFalse(JavaParserErrorOverlap.isParserError("incompatible types: int cannot be converted to String"))
    }

    func testCompositeMergesSyntaxAndCompilerResults() async {
        let cache = JavaDocumentParseCache()
        let syntax = JavaSyntaxDiagnostics.provider(cache: cache)
        // Unconfigured: no project, so the compiler contributes nothing.
        let compiler = JavaCompilerDiagnosticsService()
        let composite = JavaSyntaxAwareDiagnostics(syntax: syntax, compiler: compiler)
        let document = makeDocument(text: "class Foo {\n    void m() {\n        int x = 1\n    }\n}\n")
        let diagnostics = await composite.diagnostics(for: document)
        XCTAssertTrue(diagnostics.contains { $0.source == "java-syntax" && $0.message == "';' expected" })
    }

    // MARK: - JavaDiagnosticsMerger

    private func makeCodedDiagnostic(line: Int, code: String?, message: String = "m") -> Diagnostic {
        Diagnostic(
            severity: .error,
            message: message,
            range: TextRange(
                start: TextPosition(line: line, column: 0, utf16Offset: 0),
                end: TextPosition(line: line, column: 1, utf16Offset: 1)
            ),
            source: "test",
            code: code
        )
    }

    func testMergerDropsFindingCoveredByFreshKeyedError() {
        let javac = [makeCodedDiagnostic(line: 2, code: "javac:compiler.err.cant.resolve.location.args")]
        let inspections = [
            makeCodedDiagnostic(line: 2, code: "unresolved-member", message: "covered"),
            makeCodedDiagnostic(line: 5, code: "unresolved-member", message: "other line"),
            makeCodedDiagnostic(line: 2, code: "duplicate-import", message: "other rule"),
        ]
        let filtered = JavaDiagnosticsMerger.filter(inspections: inspections, javac: javac, fresh: true)
        XCTAssertEqual(filtered.map(\.message), ["other line", "other rule"])
    }

    func testMergerCoversUnreachableAndImportTwins() {
        let javac = [
            makeCodedDiagnostic(line: 1, code: "javac:compiler.err.unreachable.stmt"),
            makeCodedDiagnostic(line: 3, code: "javac:compiler.err.cant.resolve"),
        ]
        let inspections = [
            makeCodedDiagnostic(line: 1, code: "unreachable-code"),
            makeCodedDiagnostic(line: 3, code: "unresolved-import"),
            makeCodedDiagnostic(line: 3, code: "unresolved-type"),
        ]
        XCTAssertTrue(JavaDiagnosticsMerger.filter(inspections: inspections, javac: javac, fresh: true).isEmpty)
    }

    func testMergerKeepsEverythingWhenStaleOrUnkeyed() {
        let inspections = [makeCodedDiagnostic(line: 2, code: "unresolved-member")]
        let keyed = [makeCodedDiagnostic(line: 2, code: "javac:compiler.err.cant.resolve.location")]
        XCTAssertEqual(JavaDiagnosticsMerger.filter(inspections: inspections, javac: keyed, fresh: false).count, 1)
        let unkeyed = [makeCodedDiagnostic(line: 2, code: nil), makeCodedDiagnostic(line: 2, code: "deprecation")]
        XCTAssertEqual(JavaDiagnosticsMerger.filter(inspections: inspections, javac: unkeyed, fresh: true).count, 1)
        XCTAssertEqual(JavaDiagnosticsMerger.filter(inspections: inspections, javac: [], fresh: true).count, 1)
    }

    func testCompositePassesInspectionsThroughWhenCompilerIsQuiet() async {
        let cache = JavaDocumentParseCache()
        let syntax = JavaSyntaxDiagnostics.provider(cache: cache)
        let compiler = JavaCompilerDiagnosticsService()
        // Duplicate imports need no index, so the inspection service fires without a JDK.
        let inspections = JavaInspectionService(
            index: JavaIndex(), enabledRules: [.duplicateImport], idleDelay: .milliseconds(10))
        let composite = JavaSyntaxAwareDiagnostics(syntax: syntax, compiler: compiler, inspections: inspections)
        let document = makeDocument(text: "import java.util.List;\nimport java.util.List;\nclass Foo {\n}\n")
        await inspections.analyzeNow(document, force: true)
        let diagnostics = await composite.diagnostics(for: document)
        XCTAssertTrue(diagnostics.contains { $0.code == "duplicate-import" }, "\(diagnostics)")
    }

    func testCompositeSurfacesStalenessTheEditorSees() async {
        // The tiered provider unions per-provider stale sets, and the composite is Java's
        // only diagnostics provider: without its own override the services' overrides never
        // fire and no editor report is ever stale.
        let cache = JavaDocumentParseCache()
        let syntax = JavaSyntaxDiagnostics.provider(cache: cache)
        let compiler = JavaCompilerDiagnosticsService()
        let inspections = JavaInspectionService(
            index: JavaIndex(), enabledRules: [.duplicateImport], idleDelay: .milliseconds(10))
        let composite = JavaSyntaxAwareDiagnostics(syntax: syntax, compiler: compiler, inspections: inspections)
        let document = makeDocument(text: "import java.util.List;\nimport java.util.List;\nclass Foo {\n}\n")

        // Nothing analysed yet: inspections are stale. The unconfigured compiler covers
        // nothing, so it must not mark `javac` stale forever.
        let before = await composite.diagnosticsWithFreshness(for: document)
        XCTAssertEqual(before.staleSources, ["java-inspection"])

        await inspections.analyzeNow(document, force: true)
        let after = await composite.diagnosticsWithFreshness(for: document)
        XCTAssertEqual(after.staleSources, [])
        XCTAssertTrue(after.diagnostics.contains { $0.code == "duplicate-import" }, "\(after.diagnostics)")
    }
}
