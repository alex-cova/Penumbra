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
        XCTAssertFalse(IDESwiftInspectionSettings.current().isEnabled(.redundantVoidReturn))
        workspace.showInspectionSettings(code: "redundant-void-return", language: .swift)
        XCTAssertEqual(workspace.requestedSettingsDomain, .swift)
    }
}
