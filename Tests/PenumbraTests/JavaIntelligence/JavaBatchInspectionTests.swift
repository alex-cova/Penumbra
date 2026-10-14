import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaBatchInspectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src/main/java/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src/test/java/a"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let comparing = """
    class T {
        boolean f(String a, String b) {
            return a == b;
        }
        boolean g(String a, String b) {
            return a == b;
        }
    }
    """

    /// The standard profile without the two rules that need a populated index (an empty one cannot resolve `String`).
    private func indexFreeProfile() -> JavaInspectionProfile {
        var profile = JavaInspectionProfile.standard()
        profile.setEnabled(false, for: .unresolvedType)
        profile.setEnabled(false, for: .unresolvedImport)
        return profile
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collect(_ stream: AsyncStream<JavaBatchInspector.Event>) async -> (files: [URL: [JavaInspection]], finished: Bool?) {
        var files: [URL: [JavaInspection]] = [:]
        var finished: Bool?
        for await event in stream {
            switch event {
            case .file(let url, let found): files[url] = found
            case .finished(let cancelled): finished = cancelled
            default: break
            }
        }
        return (files, finished)
    }

    func testClosedFilesAreInspectedFromDisk() async throws {
        let a = try write("src/main/java/a/A.java", comparing)
        let b = try write("src/main/java/a/B.java", "class B {}")
        let inspector = JavaBatchInspector(index: JavaIndex())
        let options = JavaBatchInspector.Options(profile: indexFreeProfile())
        let result = await collect(inspector.run(files: [a, b], options: options) { try? String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(result.finished, false)
        XCTAssertEqual(result.files[a]?.filter { $0.id == "string-comparison-identity" }.count, 2)
        XCTAssertNil(result.files[b])
    }

    func testOpenBufferWinsOverDisk() async throws {
        let a = try write("src/main/java/a/A.java", comparing)
        let inspector = JavaBatchInspector(index: JavaIndex())
        let options = JavaBatchInspector.Options(profile: indexFreeProfile())
        let result = await collect(inspector.run(files: [a], options: options) { _ in "class A {}" })
        XCTAssertTrue(result.files.isEmpty)
    }

    func testOnlyRulesRunsADisabledRule() async throws {
        let a = try write("src/main/java/a/A.java", comparing)
        var profile = indexFreeProfile()
        profile.setEnabled(false, for: .stringComparisonIdentity)
        let inspector = JavaBatchInspector(index: JavaIndex())
        let text: @Sendable (URL) async -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
        let off = await collect(inspector.run(files: [a], options: .init(profile: profile), text: text))
        XCTAssertTrue(off.files.isEmpty)
        let named = await collect(inspector.run(
            files: [a], options: .init(profile: profile, onlyRules: [.stringComparisonIdentity]), text: text
        ))
        XCTAssertEqual(named.files[a]?.count, 2)
    }

    func testQuietFindingsAreReportedWithTheirSeverity() async throws {
        let a = try write("src/main/java/a/A.java", comparing)
        var profile = indexFreeProfile()
        profile.setSeverity(.noHighlighting, for: .stringComparisonIdentity)
        let inspector = JavaBatchInspector(index: JavaIndex())
        let result = await collect(inspector.run(files: [a], options: .init(profile: profile)) {
            try? String(contentsOf: $0, encoding: .utf8)
        })
        XCTAssertEqual(result.files[a]?.map(\.severity), [.noHighlighting, .noHighlighting])
    }

    func testScopeAppliesTestFlagAndMasks() throws {
        let main = try write("src/main/java/a/A.java", "class A {}")
        let test = try write("src/test/java/a/ATest.java", "class ATest {}")
        try write("src/main/java/a/notes.txt", "x")
        let classifier = JavaInspectionFileClassifier(projectRoot: directory)
        let all = JavaInspectionScope(kind: .project).resolve(projectRoots: [directory], classifier: classifier)
        XCTAssertEqual(Set(all.map(\.lastPathComponent)), ["A.java", "ATest.java"])
        let noTests = JavaInspectionScope(kind: .project, includeTests: false)
            .resolve(projectRoots: [directory], classifier: classifier)
        XCTAssertEqual(noTests.map(\.lastPathComponent), ["A.java"])
        let masked = JavaInspectionScope(kind: .project, fileMasks: "*Test.java")
            .resolve(projectRoots: [directory], classifier: classifier)
        XCTAssertEqual(masked.map(\.lastPathComponent), ["ATest.java"])
        let files = JavaInspectionScope(kind: .files([main, test, directory.appendingPathComponent("a.txt")]))
            .resolve(projectRoots: [], classifier: classifier)
        XCTAssertEqual(files.count, 2)
    }

    func testCancellationStopsTheRun() async throws {
        var urls: [URL] = []
        for index in 0..<30 { urls.append(try write("src/main/java/a/F\(index).java", comparing.replacingOccurrences(of: "class T", with: "class F\(index)"))) }
        let inspector = JavaBatchInspector(index: JavaIndex())
        let stream = inspector.run(files: urls, options: .init(profile: indexFreeProfile(), maxConcurrentFiles: 1)) {
            try? String(contentsOf: $0, encoding: .utf8)
        }
        var seen = 0
        var cancelled: Bool?
        for await event in stream {
            if case .file = event {
                seen += 1
                if seen == 2 { break }
            }
            if case .finished(let value) = event { cancelled = value }
        }
        XCTAssertNil(cancelled)
        XCTAssertLessThan(seen, 30)
    }

    func testFixAllRewritesEveryFinding() async throws {
        let fixed = await JavaBatchFixer.fixAll(
            rules: [.stringComparisonIdentity], in: comparing, url: URL(fileURLWithPath: "/p/T.java"), index: JavaIndex()
        )
        XCTAssertEqual(fixed.fixedCount, 2)
        XCTAssertEqual(fixed.text.components(separatedBy: "a.equals(b)").count - 1, 2)
        XCTAssertFalse(fixed.text.contains("a == b"))
        XCTAssertFalse(fixed.edits.isEmpty)
        var text = comparing as NSString
        for edit in fixed.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        XCTAssertEqual(text as String, fixed.text)
    }

    func testFixAllSkipsRulesWithoutAFixAndSuppressedFindings() async {
        let suppressed = """
        class T {
            @SuppressWarnings("string-comparison-identity")
            boolean f(String a, String b) { return a == b; }
        }
        """
        let none = await JavaBatchFixer.fixAll(
            rules: [.stringComparisonIdentity], in: suppressed, url: URL(fileURLWithPath: "/p/T.java"), index: JavaIndex()
        )
        XCTAssertEqual(none.fixedCount, 0)
        XCTAssertEqual(none.text, suppressed)
        let noFix = await JavaBatchFixer.fixAll(
            rules: [.cyclomaticComplexity], in: comparing, url: URL(fileURLWithPath: "/p/T.java"), index: JavaIndex()
        )
        XCTAssertEqual(noFix.fixedCount, 0)
    }

    func testHasQuickFixFlagsMatchWhatTheRulesProvide() {
        XCTAssertTrue(JavaInspectionRule.stringComparisonIdentity.hasQuickFix)
        XCTAssertTrue(JavaInspectionRule.unusedImport.hasQuickFix)
        XCTAssertTrue(JavaInspectionRule.missingOverride.hasQuickFix)
        XCTAssertFalse(JavaInspectionRule.cyclomaticComplexity.hasQuickFix)
        XCTAssertFalse(JavaInspectionRule.nullDereference.hasQuickFix)
    }

    func testReportBuildsValidSarifAndHtml() throws {
        let a = directory.appendingPathComponent("src/A.java")
        let finding = JavaInspection(
            id: "string-comparison-identity", message: "Strings <compared> with ==", severity: .warning,
            range: TextRange(
                start: TextPosition(line: 2, column: 4, utf16Offset: 10), end: TextPosition(line: 2, column: 9, utf16Offset: 15)
            )
        )
        let report = JavaInspectionReport(title: "Inspection: Whole project", results: [a: [finding]], root: directory)
        XCTAssertEqual(report.entries.first?.path, "src/A.java")
        XCTAssertEqual(report.entries.first?.line, 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.sarif()) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "2.1.0")
        let runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        let results = try XCTUnwrap(runs.first?["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["ruleId"] as? String, "string-comparison-identity")
        XCTAssertEqual(results.first?["level"] as? String, "warning")
        XCTAssertTrue(report.html().contains("Strings &lt;compared&gt; with =="))
    }
}
