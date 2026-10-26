import EditorIntelligence
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// The Problems tab for an Inspect Code run: the grouped tree, the marks on results, the tabs.
@MainActor
final class IDEInspectionRunTests: XCTestCase {
    private func finding(
        _ rule: JavaInspectionRule, _ message: String, line: Int, severity: JavaInspection.Severity? = nil
    ) -> JavaInspection {
        let start = TextPosition(line: line, column: 4, utf16Offset: line * 20 + 4)
        let end = TextPosition(line: line, column: 9, utf16Offset: line * 20 + 9)
        return JavaInspection(
            id: rule.code, message: message, severity: severity ?? rule.defaultSeverity,
            range: EditorIntelligence.TextRange(start: start, end: end)
        )
    }

    private let root = URL(fileURLWithPath: "/proj")
    private var a: URL { root.appendingPathComponent("src/a/A.java") }
    private var b: URL { root.appendingPathComponent("src/b/B.java") }

    private func makeRun() -> IDEInspectionRun {
        let run = IDEInspectionRun(
            scope: JavaInspectionScope(kind: .project), onlyRules: nil, includeProjectRules: false, profileName: "Default"
        )
        run.begin(total: 2)
        run.record([
            finding(.stringComparisonIdentity, "Strings compared with ==", line: 3),
            finding(.stringComparisonIdentity, "Strings compared with ==", line: 8),
            finding(.systemOutErr, "Use of System.out", line: 5),
        ], for: a)
        run.record([finding(.stringComparisonIdentity, "Strings compared with ==", line: 1)], for: b)
        run.progress(done: 2, total: 2)
        run.finish(cancelled: false)
        return run
    }

    private func tree(
        _ run: IDEInspectionRun, grouping: IDEInspectionResultsTree.Grouping = .inspection,
        configure: (inout IDEInspectionResultsTree.Options) -> Void = { _ in }
    ) -> [IDEInspectionResultsTree.Node] {
        var options = IDEInspectionResultsTree.Options(grouping: grouping, projectRoot: root)
        configure(&options)
        return IDEInspectionResultsTree.build(
            entries: run.entries, resolved: run.resolved, excluded: run.excludedKeys, options: options
        )
    }

    func testGroupsByInspectionThenFileThenProblem() {
        let nodes = tree(makeRun())
        XCTAssertEqual(nodes.count, 2)
        let comparison = nodes.first { $0.ruleCode == "string-comparison-identity" }
        XCTAssertEqual(comparison?.count, 3)
        XCTAssertEqual(comparison?.children.map(\.title), ["A.java", "B.java"])
        XCTAssertEqual(comparison?.children.first?.children.map(\.subtitle), ["4:5", "9:5"])
    }

    func testGroupsBySeverityAndDirectory() {
        let run = makeRun()
        let bySeverity = tree(run, grouping: .severity)
        XCTAssertEqual(bySeverity.map(\.severity), [.warning, .weakWarning].filter { severity in
            run.entries.contains { $0.inspection.severity == severity }
        })
        let byDirectory = tree(run, grouping: .directory)
        XCTAssertEqual(byDirectory.map(\.title), ["src/a", "src/b"])
        XCTAssertEqual(byDirectory[0].count, 3)
    }

    func testExcludedAndResolvedFollowTheOptions() {
        let run = makeRun()
        let first = run.entries.first { $0.inspection.id == "system-out-err" }!
        run.exclude([first.key])
        XCTAssertEqual(tree(run).count, 1)
        XCTAssertEqual(tree(run) { $0.showsExcluded = true }.count, 2)
        let shown = tree(run) { $0.showsExcluded = true }.first { $0.ruleCode == "system-out-err" }
        XCTAssertEqual(shown?.children.first?.children.first?.isExcluded, true)
        run.include([first.key])

        let fixed = run.entries.first { $0.url == b }!
        run.markResolved([fixed], newFindings: [], for: b)
        XCTAssertNil(run.results[b])
        let comparison = tree(run).first { $0.ruleCode == "string-comparison-identity" }
        XCTAssertEqual(comparison?.children.count, 2)
        XCTAssertEqual(comparison?.children.last?.children.first?.isResolved, true)
        let hidden = tree(run) { $0.hidesResolved = true }.first { $0.ruleCode == "string-comparison-identity" }
        XCTAssertEqual(hidden?.children.count, 1)
    }

    func testFilterMatchesMessageRuleAndFile() {
        let run = makeRun()
        XCTAssertEqual(tree(run) { $0.filter = "System.out" }.count, 1)
        XCTAssertEqual(tree(run) { $0.filter = "B.java" }.first?.count, 1)
        XCTAssertTrue(tree(run) { $0.filter = "nothing like this" }.isEmpty)
    }

    func testExclusionSurvivesReinspectionWhileTheFindingStays() {
        let run = makeRun()
        let keep = run.entries.first { $0.url == a && $0.inspection.id == "system-out-err" }!
        run.exclude([keep.key])
        // The same file inspected again, with one comparison fixed and the rest unchanged.
        run.record([
            finding(.stringComparisonIdentity, "Strings compared with ==", line: 3),
            finding(.systemOutErr, "Use of System.out", line: 5),
        ], for: a)
        let again = run.entries.first { $0.url == a && $0.inspection.id == "system-out-err" }!
        XCTAssertEqual(again.key, keep.key)
        XCTAssertTrue(run.excludedKeys.contains(again.key))
    }

    func testFlattenSkipsCollapsedGroupsAndListsProblemsInOrder() {
        let nodes = tree(makeRun())
        let all = IDEInspectionResultsTree.flatten(nodes, collapsed: [])
        XCTAssertEqual(all.first?.depth, 0)
        XCTAssertEqual(all.map(\.depth).max(), 2)
        let collapsedID = nodes.first { $0.ruleCode == "string-comparison-identity" }!.id
        let collapsed = IDEInspectionResultsTree.flatten(nodes, collapsed: [collapsedID])
        XCTAssertLessThan(collapsed.count, all.count)
        XCTAssertEqual(IDEInspectionResultsTree.problems(in: nodes).count, 4)
    }

    func testStoreKeepsRecentRunsAndSelection() {
        let store = IDEInspectionRunsStore()
        var ids: [UUID] = []
        for _ in 0..<(IDEInspectionRunsStore.maxRuns + 2) {
            let run = makeRun()
            ids.append(run.id)
            store.add(run)
        }
        XCTAssertEqual(store.runs.count, IDEInspectionRunsStore.maxRuns)
        XCTAssertEqual(store.selection, .run(ids.last!))
        store.close(ids.last!)
        XCTAssertEqual(store.selection, .project)
        XCTAssertNil(store.run(with: ids.last!))
    }

    func testCommitCheckReportsProblemsAsAWarning() {
        var facts = IDEGitCommitFacts()
        facts.codeAnalysis = .init(errors: 0, warnings: 0, paths: [])
        XCTAssertTrue(IDEGitCommitChecks.evaluate(facts).isEmpty)
        facts.codeAnalysis = .init(errors: 1, warnings: 2, paths: ["src/A.java"])
        let findings = IDEGitCommitChecks.evaluate(facts)
        XCTAssertEqual(findings.map(\.kind), [.codeAnalysis])
        XCTAssertEqual(findings.first?.severity, .warning)
        XCTAssertTrue(findings.first?.detail.contains("1 error and 2 warnings") == true)
        XCTAssertFalse(IDEGitCommitChecks.hasBlocking(findings))
    }
}

/// An Inspect Code run through a real window: closed files from disk, the open buffer's text, a fix.
@MainActor
final class IDEInspectCodeWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var window: IDEWorkspace?

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let window { IDEWindowRegistry.shared.unregister(window) }
        try? FileManager.default.removeItem(at: directory)
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func waitForRun(_ run: IDEInspectionRun) async throws {
        for _ in 0..<200 where run.state == .running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(run.state, .running)
    }

    func testRunFindsProblemsInClosedFilesAndFixAllRewritesThem() async throws {
        let file = directory.appendingPathComponent("src/T.java")
        let source = "class T { boolean f(String a, String b) { return a == b; } }\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        let workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = workspace
        workspace.openProjectFolder(directory)
        try await Task.sleep(for: .milliseconds(300))

        var profile = JavaInspectionProfile.standard()
        profile.setEnabled(false, for: .unresolvedType)
        profile.setEnabled(false, for: .unresolvedImport)
        let run = workspace.startInspection(IDEInspectionLaunch(
            scope: JavaInspectionScope(kind: .project), profile: profile, profileName: "Test",
            onlyRules: nil, includeProjectRules: false
        ))
        try await waitForRun(run)
        let found = run.entries.filter { $0.inspection.id == "string-comparison-identity" }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(workspace.inspectionRuns.selection, .run(run.id))

        await workspace.applyInspectionFixAll(rule: .stringComparisonIdentity, in: run)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("a.equals(b)"))
        XCTAssertTrue(run.entries.filter { $0.inspection.id == "string-comparison-identity" }.isEmpty)
        XCTAssertEqual(run.resolved.count, 1)
    }
}
