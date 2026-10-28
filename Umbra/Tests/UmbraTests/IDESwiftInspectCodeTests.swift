import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest
@testable import Umbra

/// Inspect Code over Swift: the same results tree, run tab and fixes as Java's, fed by the Swift engine.
@MainActor
final class IDESwiftInspectCodeTests: XCTestCase {
    private var directory: URL!
    private var window: IDEWorkspace?
    private var savedSettings: [String: Any?] = [:]

    private static let settingsKeys = [
        IDESwiftInspectionSettings.disabledKey, IDESwiftInspectionSettings.enabledKey,
        IDESwiftInspectionSettings.severitiesKey, IDESwiftInspectionSettings.limitsKey,
        IDEInspectionProfiles.swiftSectionKey, "com.umbra.editor.inspectionProfile",
    ]

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        // The Swift settings live in `UserDefaults.standard`; put back what the developer had.
        for key in Self.settingsKeys { savedSettings[key] = UserDefaults.standard.object(forKey: key) }
        for key in Self.settingsKeys { UserDefaults.standard.removeObject(forKey: key) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift-inspect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let window { IDEWindowRegistry.shared.unregister(window) }
        try? FileManager.default.removeItem(at: directory)
        for key in Self.settingsKeys { UserDefaults.standard.set(savedSettings[key] ?? nil, forKey: key) }
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func finding(_ rule: SwiftInspectionRule, _ message: String, line: Int) -> SwiftLocatedInspection {
        let start = TextPosition(line: line, column: 4, utf16Offset: line * 20 + 4)
        let end = TextPosition(line: line, column: 9, utf16Offset: line * 20 + 9)
        return SwiftLocatedInspection(
            inspection: SwiftInspection(id: rule.code, message: message, severity: rule.defaultSeverity, bytes: 0 ..< 1, fixes: []),
            range: EditorIntelligence.TextRange(start: start, end: end)
        )
    }

    private func makeWorkspace() async throws -> IDEWorkspace {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = workspace
        workspace.openProjectFolder(directory)
        try await Task.sleep(for: .milliseconds(300))
        return workspace
    }

    private func waitForRun(_ run: IDEInspectionRun) async throws {
        for _ in 0..<200 where run.state == .running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(run.state, .running)
    }

    // MARK: - Tree

    func testTreeGroupsASwiftRunByRuleWithSwiftTitlesAndSeverities() {
        let root = URL(fileURLWithPath: "/proj")
        let a = root.appendingPathComponent("Sources/A.swift")
        let run = IDEInspectionRun(language: .swift, scopeTitle: "Whole project", onlyRuleCodes: nil, includeProjectRules: false, profileName: "Swift settings")
        run.begin(total: 1)
        run.record([
            IDEInspectionFinding(finding(.redundantVoidReturn, "`-> Void` is redundant", line: 1)),
            IDEInspectionFinding(finding(.emptyCatch, "Empty catch", line: 7)),
            IDEInspectionFinding(finding(.redundantVoidReturn, "`-> ()` is redundant", line: 9)),
        ], for: a)
        run.finish(cancelled: false)

        var options = IDEInspectionResultsTree.Options(grouping: .inspection, projectRoot: root)
        options.language = .swift
        let nodes = IDEInspectionResultsTree.build(entries: run.entries, resolved: [], excluded: [], options: options)
        XCTAssertEqual(nodes.map(\.title), [SwiftInspectionRule.emptyCatch.title, SwiftInspectionRule.redundantVoidReturn.title].sorted())
        let redundant = nodes.first { $0.ruleCode == "redundant-void-return" }
        XCTAssertEqual(redundant?.count, 2)
        XCTAssertEqual(redundant?.subtitle, "Redundant code")
        XCTAssertEqual(run.entries.first?.inspection.language, .swift)

        options.grouping = .severity
        let bySeverity = IDEInspectionResultsTree.build(entries: run.entries, resolved: [], excluded: [], options: options)
        XCTAssertEqual(bySeverity.map(\.title), ["Warnings", "Weak warnings"])
        XCTAssertEqual(run.title, "Inspection: Whole project")
    }

    func testARunByNameTitlesItWithTheSwiftRule() {
        let run = IDEInspectionRun(
            language: .swift, scopeTitle: "A.swift", onlyRuleCodes: ["force-unwrap"], includeProjectRules: false, profileName: "Swift settings"
        )
        XCTAssertEqual(run.title, "\(SwiftInspectionRule.forceUnwrap.title): A.swift")
    }

    func testCatalogsAreKeptPerLanguage() {
        XCTAssertNotNil(IDEInspectionLanguage.swift.rule(code: "force-unwrap"))
        XCTAssertNil(IDEInspectionLanguage.java.rule(code: "force-unwrap"))
        XCTAssertEqual(IDEInspectionLanguage.swift.rules.count, SwiftInspectionRule.allCases.count)
        XCTAssertEqual(IDEInspectionRuleInfo(SwiftInspectionRule.redundantVoidReturn).hasQuickFix, true)
        XCTAssertEqual(IDEInspectionRuleInfo(SwiftInspectionRule.emptyCatch).hasQuickFix, false)
    }

    // MARK: - Entry points

    func testExplorerAndContextMenuRouteByExtension() async throws {
        let workspace = try await makeWorkspace()
        let swift = directory.appendingPathComponent("Sources/A.swift")
        try "let a = 1\n".write(to: swift, atomically: true, encoding: .utf8)

        workspace.inspectCode(forExplorerItem: swift)
        XCTAssertEqual(workspace.inspectionRuns.pendingScopeRequest?.language, .swift)
        XCTAssertEqual(workspace.inspectionRuns.pendingScopeRequest?.selectedFiles, [swift])

        workspace.inspectionRuns.pendingScopeRequest = nil
        XCTAssertEqual(workspace.inspectionContextMenuItems(url: swift).map(\.title), ["Inspect Code…"])
        XCTAssertEqual(workspace.inspectionContextMenuItems(url: directory.appendingPathComponent("A.java")).map(\.title), ["Inspect Code…"])
        XCTAssertTrue(workspace.inspectionContextMenuItems(url: directory.appendingPathComponent("notes.txt")).isEmpty)

        workspace.presentRunInspectionByName(rule: IDEInspectionRuleInfo(SwiftInspectionRule.forceTry))
        XCTAssertEqual(workspace.inspectionRuns.pendingScopeRequest?.language, .swift)
        XCTAssertEqual(workspace.inspectionRuns.pendingScopeRequest?.rule?.code, "force-try")
    }

    // MARK: - A real run

    func testRunFindsProblemsInClosedFilesFixAllRewritesThemAndTheReportListsThem() async throws {
        let file = directory.appendingPathComponent("Sources/T.swift")
        let source = "func a() -> Void { }\nfunc b() -> () { }\nfunc c(x: Int?) {\n    let y = x!\n    _ = y\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        try "let ok = 1\n".write(to: directory.appendingPathComponent("Sources/Clean.swift"), atomically: true, encoding: .utf8)
        try "// not Swift\n".write(to: directory.appendingPathComponent("Sources/Other.java"), atomically: true, encoding: .utf8)
        let workspace = try await makeWorkspace()

        var options = SwiftInspectionOptions()
        options.enabled = ["force-unwrap"]
        let run = workspace.startInspection(IDEInspectionLaunch(
            swiftScope: SwiftInspectionScope(kind: .project), options: options, onlyRules: nil
        ))
        try await waitForRun(run)
        XCTAssertEqual(run.language, .swift)
        XCTAssertEqual(run.results.keys.map(\.lastPathComponent), ["T.swift"])
        XCTAssertEqual(run.entries.map(\.inspection.id).sorted(), ["force-unwrap", "redundant-void-return", "redundant-void-return"])
        XCTAssertEqual(workspace.inspectionRuns.selection, .run(run.id))

        // The result's own fixes, from the file's current text.
        let entry = try XCTUnwrap(run.entries.first { $0.inspection.id == "redundant-void-return" })
        let fixes = await workspace.quickFixes(for: entry)
        XCTAssertEqual(fixes.first?.title, "Remove return type")
        XCTAssertTrue(fixes.contains { $0.title.hasPrefix("Suppress") })

        let report = IDEWorkspace.inspectionReport(for: run, root: directory)
        XCTAssertEqual(report.entries.map(\.path), Array(repeating: "Sources/T.swift", count: 3))
        XCTAssertEqual(report.entries.map(\.line), [1, 2, 4])
        // The export says it is Swift's, with Swift's rule titles, not "Umbra Java Inspections" and bare codes.
        let sarif = String(decoding: report.sarif(), as: UTF8.self)
        XCTAssertTrue(sarif.contains("Umbra Swift Inspections"), sarif)
        XCTAssertFalse(sarif.contains("Umbra Java Inspections"))
        XCTAssertTrue(sarif.contains(SwiftInspectionRule.redundantVoidReturn.title), sarif)
        XCTAssertTrue(sarif.contains(SwiftInspectionRule.redundantVoidReturn.group.title), sarif)
        XCTAssertTrue(report.html().contains(SwiftInspectionRule.forceUnwrap.title))

        await workspace.applyInspectionFixAll(ruleCode: "redundant-void-return", in: run)
        let fixed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(fixed, "func a() { }\nfunc b() { }\nfunc c(x: Int?) {\n    let y = x!\n    _ = y\n}\n")
        XCTAssertEqual(run.entries.map(\.inspection.id), ["force-unwrap"])
        XCTAssertEqual(run.resolved.count, 2)
    }

    func testDisablingASwiftInspectionFromAResultTurnsItOffInSettings() async throws {
        let workspace = try await makeWorkspace()
        workspace.disableInspection(code: "redundant-void-return", language: .swift)
        XCTAssertFalse(workspace.inspections.activeSwiftProfile.isEnabled(.redundantVoidReturn))
        XCTAssertFalse(workspace.swiftInspectionOptions(for: nil).isEnabled(.redundantVoidReturn), "the editor's analysis follows the profile")
        workspace.showInspectionSettings(code: "redundant-void-return", language: .swift)
        XCTAssertEqual(workspace.requestedSettingsDomain, .swift)
        XCTAssertEqual(workspace.inspections.focusedRuleCode, "redundant-void-return")
    }

    func testTheMenusCommandsTurnTheRuleOffAndOpenItsSettings() async throws {
        let workspace = try await makeWorkspace()
        workspace.performCodeActionCommand(CodeActionCommand(id: SwiftInspectionCommand.disable, arguments: ["redundant-void-return"]))
        XCTAssertFalse(workspace.inspections.activeSwiftProfile.isEnabled(.redundantVoidReturn))
        workspace.performCodeActionCommand(CodeActionCommand(id: SwiftInspectionCommand.configure, arguments: ["redundant-void-return"]))
        XCTAssertEqual(workspace.requestedSettingsDomain, .swift)

        workspace.performCodeActionCommand(CodeActionCommand(id: SwiftInspectionCommand.quiet, arguments: ["empty-catch"]))
        XCTAssertEqual(workspace.inspections.activeSwiftProfile.resolution(of: .emptyCatch).severity, .noHighlighting)
    }

    func testProjectWideInspectionsAskTheIndexAndOnlyRunWhenAsked() async throws {
        try "func used() {}\nfunc orphan() {}\n".write(to: directory.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "func caller() { used() }\nprivate func hidden() {}\n".write(to: directory.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
        let workspace = try await makeWorkspace()
        let wide = workspace.startInspection(IDEInspectionLaunch(
            swiftScope: SwiftInspectionScope(kind: .project), profile: .standard, profileName: "Default",
            root: directory, onlyRules: nil, includeProjectRules: true
        ))
        try await waitForRun(wide)
        let messages = wide.entries.map(\.inspection.message).sorted()
        XCTAssertEqual(messages, [
            "'caller' is never used in the project.", "'hidden' is private and nothing else in this file mentions it.",
            "'orphan' is never used in the project.",
        ])

        let plain = workspace.startInspection(IDEInspectionLaunch(
            swiftScope: SwiftInspectionScope(kind: .project), profile: .standard, profileName: "Default",
            root: directory, onlyRules: nil, includeProjectRules: false
        ))
        try await waitForRun(plain)
        XCTAssertEqual(plain.entries.map(\.inspection.message), ["'hidden' is private and nothing else in this file mentions it."],
                       "the private one needs only its file; the project-wide one waits to be asked")
    }

    func testTheCommitCheckCountsStagedSwiftFilesAndReviewOpensTheirRun() async throws {
        let bad = directory.appendingPathComponent("Sources/Bad.swift")
        let good = directory.appendingPathComponent("Sources/Good.swift")
        try "func f() {\n    do { try g() } catch { }\n}\nfunc g() throws {}\n".write(to: bad, atomically: true, encoding: .utf8)
        try "func ok() {}\n".write(to: good, atomically: true, encoding: .utf8)
        let workspace = try await makeWorkspace()

        let analysis = await workspace.analyzeForCommit([bad, good])
        XCTAssertEqual(analysis.warnings, 1, "the empty catch is a warning")
        XCTAssertEqual(analysis.errors, 0)
        XCTAssertEqual(analysis.paths, ["Sources/Bad.swift"])

        // A profile that switches the rule off for that file leaves nothing to count.
        workspace.inspections.edit { $0.swift.setEnabled(false, for: .emptyCatch) }
        let quiet = await workspace.analyzeForCommit([bad])
        XCTAssertFalse(quiet.hasProblems)

        workspace.reviewCommitAnalysis(relativePaths: ["Sources/Bad.swift"])
        let run = try XCTUnwrap(workspace.inspectionRuns.selectedRun)
        XCTAssertEqual(run.language, .swift)
        try await waitForRun(run)
    }
}

