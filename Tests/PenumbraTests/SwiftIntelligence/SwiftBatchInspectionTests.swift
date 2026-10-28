import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// Inspect Code over many Swift files: which files a scope covers, what a run reports, and the fixes that
/// come back for a result and for a whole rule.
final class SwiftBatchInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftBatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String = "let x = 1\n") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    private func names(_ urls: [URL]) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        return urls.map { String($0.path.dropFirst($0.path.hasPrefix(prefix) ? prefix.count : 0)) }
    }

    // MARK: - Scope

    func testProjectScopeSkipsBuildProductsAndNonSwiftFiles() throws {
        try write("Sources/App/A.swift")
        try write("Sources/App/Sub/B.swift")
        try write(".build/debug/Gen.swift")
        try write("DerivedData/X.swift")
        try write("Pods/P/P.swift")
        try write("Sources/App/readme.md", "x")
        let files = SwiftInspectionScope(kind: .project).resolve(projectRoots: [root])
        XCTAssertEqual(names(files), ["Sources/App/A.swift", "Sources/App/Sub/B.swift"])
    }

    func testTestsAndMasksFilter() throws {
        try write("Sources/App/A.swift")
        try write("Sources/App/AGenerated.swift")
        try write("Tests/AppTests/ATests.swift")
        try write("Sources/App/Widget+Tests.swift")
        XCTAssertEqual(names(SwiftInspectionScope(kind: .project, includeTests: false).resolve(projectRoots: [root])),
                       ["Sources/App/A.swift", "Sources/App/AGenerated.swift"])
        XCTAssertEqual(names(SwiftInspectionScope(kind: .project, includeTests: false, fileMasks: "!*Generated.swift").resolve(projectRoots: [root])),
                       ["Sources/App/A.swift"])
        XCTAssertEqual(names(SwiftInspectionScope(kind: .project, fileMasks: "Tests/**").resolve(projectRoots: [root])),
                       ["Tests/AppTests/ATests.swift"])
    }

    func testDirectoryAndExplicitFileScopes() throws {
        let a = try write("Sources/App/A.swift")
        let b = try write("Sources/Other/B.swift")
        let text = try write("Sources/Other/notes.txt", "x")
        XCTAssertEqual(names(SwiftInspectionScope(kind: .directory(root.appendingPathComponent("Sources/Other"))).resolve(projectRoots: [root])),
                       ["Sources/Other/B.swift"])
        XCTAssertEqual(SwiftInspectionScope(kind: .files([a, text, a, b])).resolve(projectRoots: [root]), [a, b])
        XCTAssertEqual(SwiftInspectionScope(kind: .files([a])).title, "A.swift")
        XCTAssertEqual(SwiftInspectionScope(kind: .openFiles([a, b])).title, "Open files")
    }

    // MARK: - Run

    private let source = "func f(x: Int?) {\n    let y = x!\n    _ = y\n}\nfunc g(a: [Int]) -> Bool { a.count == 0 }\n"

    private func options(_ configure: (inout SwiftInspectionOptions) -> Void = { _ in }) -> SwiftBatchInspector.Options {
        var inspection = SwiftInspectionOptions()
        configure(&inspection)
        return SwiftBatchInspector.Options(inspection: inspection)
    }

    func testARunReportsEachFileWithItsFindingsAndProgress() async throws {
        let bad = try write("Bad.swift", source)
        let clean = try write("Clean.swift", "let x = 1\n")
        var events: [SwiftBatchInspector.Event] = []
        let stream = SwiftBatchInspector().run(
            files: [bad, clean], options: options { $0.enabled = ["force-unwrap", "count-is-zero"] },
            text: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        for await event in stream { events.append(event) }

        guard case .started(let total)? = events.first else { return XCTFail("no start: \(events)") }
        XCTAssertEqual(total, 2)
        guard case .finished(let cancelled)? = events.last else { return XCTFail("no finish") }
        XCTAssertFalse(cancelled)
        var reported: [URL: [SwiftLocatedInspection]] = [:]
        var progress = 0
        for event in events {
            if case .file(let url, let found) = event { reported[url] = found }
            if case .progress(let done, _) = event { progress = max(progress, done) }
        }
        XCTAssertEqual(progress, 2)
        XCTAssertNil(reported[clean], "a file without findings is not reported")
        let found = try XCTUnwrap(reported[bad])
        XCTAssertEqual(found.map(\.inspection.id), ["force-unwrap", "count-is-zero"])
        XCTAssertEqual(found[0].range.start.line, 1)
        XCTAssertEqual(found[1].range.start.line, 4)
    }

    func testOnlyRulesRunsJustThose() throws {
        let findings = SwiftBatchInspector.located(
            in: source, options: SwiftBatchInspector.Options(inspection: SwiftInspectionOptions(), onlyRules: [.forceUnwrap])
        )
        XCTAssertEqual(findings.map(\.inspection.id), ["force-unwrap"], "an off-by-default rule runs when asked for by name")
        let none = SwiftBatchInspector.located(in: source, options: options())
        XCTAssertTrue(none.isEmpty, "the defaults report neither rule")
    }

    func testSettingsSeveritiesAndTheSuppressionCommentApply() {
        let text = "func f(x: Int?) {\n    // umbra:disable force-unwrap\n    let y = x!\n    _ = y\n}\n"
        let on = options { $0.enabled = ["force-unwrap"]; $0.severities = ["force-unwrap": .error] }
        XCTAssertTrue(SwiftBatchInspector.located(in: text, options: on).isEmpty)
        let found = SwiftBatchInspector.located(in: "func f(x: Int?) {\n    let y = x!\n    _ = y\n}\n", options: on)
        XCTAssertEqual(found.first?.inspection.severity, .error)
    }

    // MARK: - Fixes

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        let map = SourceTextMap(text)
        var bytes = Array(text.utf8)
        let ranges = edits.map { edit -> (Range<Int>, String) in
            let lower = map.byteOffset(utf16: edit.range.start.utf16Offset)
            let upper = map.byteOffset(utf16: edit.range.end.utf16Offset)
            return (lower ..< upper, edit.replacement)
        }
        for (range, replacement) in ranges.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: Array(replacement.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func testFixAllAppliesEveryFixOfTheRulesAsEditsAgainstTheOriginal() {
        let text = "func a() -> Void { }\nfunc b() -> () { }\nfunc c() -> Int { return 1 }\n"
        let result = SwiftBatchFixer.fixAll(rules: [.redundantVoidReturn], in: text)
        XCTAssertEqual(result.fixedCount, 2)
        XCTAssertEqual(apply(result.edits, to: text), "func a() { }\nfunc b() { }\nfunc c() -> Int { return 1 }\n")
    }

    func testFixAllIgnoresRulesWithoutAFixAndFilesThatDoNotParse() {
        XCTAssertTrue(SwiftBatchFixer.fixAll(rules: [.forceUnwrap, .emptyCatch], in: source).isEmpty)
        XCTAssertTrue(SwiftBatchFixer.fixAll(rules: [], in: source).isEmpty)
    }

    func testFixAllSkipsSafeDeleteFixes() {
        // The finding is there, but deleting a declaration is a decision: Fix all leaves it alone.
        let text = "struct S {\n    private func helper() {}\n    func run() {}\n}\n"
        let findings = SwiftInspectionPipeline.analyze(
            text: text, options: SwiftInspectionOptions().only([.unusedPrivateMember]),
            cache: SwiftSyntaxParseCache(capacity: 1)
        ).findings
        XCTAssertEqual(findings.count, 1)
        let result = SwiftBatchFixer.fixAll(rules: [.unusedPrivateMember], in: text)
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertEqual(result.fixedCount, 0)
    }

    func testFixAllLeavesCollidingFixesForTheNextRun() {
        // `return (a ? 1 : 2)`: the nested findings touch; whichever is taken first, none may overlap.
        let text = "func f(x: Bool) -> Int { return x ? 1 : 2 }\nfunc g(y: Bool) { if (y) { } }\n"
        let result = SwiftBatchFixer.fixAll(rules: [.redundantReturn, .redundantParentheses], in: text)
        XCTAssertEqual(result.fixedCount, 2)
        XCTAssertFalse(SwiftSyntaxDocument.parse(apply(result.edits, to: text)).hasSyntaxErrors)
    }

    func testQuickFixesOfAResultComeFromTheCurrentText() throws {
        let text = "func f() -> Void { }\n"
        let finding = try XCTUnwrap(SwiftBatchInspector.located(in: text, options: SwiftBatchInspector.Options(inspection: .standard)).first)
        let actions = SwiftInspectionQuickFixes.actions(for: finding, in: text)
        XCTAssertEqual(actions.map(\.title), ["Remove return type", "Suppress 'redundant-void-return' for statement"])
        XCTAssertEqual(apply(actions[0].edits, to: text), "func f() { }\n")

        // The file moved on: the result's position no longer holds the finding.
        XCTAssertTrue(SwiftInspectionQuickFixes.actions(for: finding, in: "func f() { }\n").isEmpty)
    }
}
