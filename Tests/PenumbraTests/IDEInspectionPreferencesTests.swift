import Foundation
import EditorIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// Settings › Inspections stores rule codes, and only the severities that differ from a default.
@MainActor
final class IDEInspectionPreferencesTests: XCTestCase {
    private var originalDisabled: Set<String> = []
    private var originalSeverities: [String: String] = [:]
    private let preferences = IDEPreferences.shared

    override func setUp() {
        super.setUp()
        // `IDEPreferences.shared` writes to `UserDefaults.standard`; put back what the developer had.
        originalDisabled = preferences.javaDisabledInspections
        originalSeverities = preferences.javaInspectionSeverities
        preferences.resetJavaInspections()
    }

    override func tearDown() {
        preferences.javaDisabledInspections = originalDisabled
        preferences.javaInspectionSeverities = originalSeverities
        super.tearDown()
    }

    func testEveryRuleIsEnabledAtItsDefaultSeverityByDefault() {
        XCTAssertEqual(preferences.enabledJavaInspections, Set(JavaInspectionRule.allCases))
        XCTAssertTrue(preferences.javaInspectionSeverityOverrides.isEmpty)
        for rule in JavaInspectionRule.allCases {
            XCTAssertEqual(preferences.severity(of: rule), rule.defaultSeverity)
        }
    }

    func testDisablingARuleStoresItsCode() {
        preferences.setEnabled(false, for: .selfAssignment)
        XCTAssertEqual(preferences.javaDisabledInspections, ["self-assignment"])
        XCTAssertFalse(preferences.isEnabled(.selfAssignment))
        XCTAssertFalse(preferences.enabledJavaInspections.contains(.selfAssignment))
        preferences.setEnabled(true, for: .selfAssignment)
        XCTAssertTrue(preferences.javaDisabledInspections.isEmpty)
    }

    func testOnlyDeviationsFromTheDefaultSeverityAreStored() {
        preferences.setSeverity(.error, for: .manualMinMax)
        XCTAssertEqual(preferences.javaInspectionSeverities, ["manual-min-max": "error"])
        XCTAssertEqual(preferences.severity(of: .manualMinMax), .error)
        XCTAssertEqual(preferences.javaInspectionSeverityOverrides, [.manualMinMax: .error])
        // Choosing the default again drops the entry.
        preferences.setSeverity(JavaInspectionRule.manualMinMax.defaultSeverity, for: .manualMinMax)
        XCTAssertTrue(preferences.javaInspectionSeverities.isEmpty)
    }

    func testAnUnknownCodeOrSeverityIsIgnoredAndRestoreDefaultsClearsEverything() {
        preferences.javaDisabledInspections = ["retired-rule"]
        preferences.javaInspectionSeverities = ["retired-rule": "error", "self-assignment": "bogus"]
        XCTAssertEqual(preferences.enabledJavaInspections, Set(JavaInspectionRule.allCases))
        XCTAssertTrue(preferences.javaInspectionSeverityOverrides.isEmpty)
        preferences.setEnabled(false, for: .unusedLabel)
        preferences.setSeverity(.info, for: .unusedLabel)
        preferences.resetJavaInspections()
        XCTAssertTrue(preferences.javaDisabledInspections.isEmpty)
        XCTAssertTrue(preferences.javaInspectionSeverities.isEmpty)
    }
}

/// A window's Java services follow the inspection settings, and re-analyse only on a real change.
@MainActor
final class IDEInspectionConfigurationFlowTests: XCTestCase {
    private var originalDisabled: Set<String> = []
    private var originalSeverities: [String: String] = [:]
    private var window: IDEWorkspace?

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        originalDisabled = IDEPreferences.shared.javaDisabledInspections
        originalSeverities = IDEPreferences.shared.javaInspectionSeverities
        IDEPreferences.shared.resetJavaInspections()
    }

    override func tearDown() {
        IDEPreferences.shared.javaDisabledInspections = originalDisabled
        IDEPreferences.shared.javaInspectionSeverities = originalSeverities
        if let window { IDEWindowRegistry.shared.unregister(window) }
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func document(_ source: String) -> EditorIntelligence.Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return EditorIntelligence.Document(
            url: URL(fileURLWithPath: "/proj/T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    func testChangingASettingReconfiguresTheServiceAndNotifiesOnce() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = workspace
        let support = workspace.javaSupport
        let source = "class T { int x; void f() { x = x; } }"

        var notifications = 0
        let changed = expectation(description: "configuration change reported")
        support.onInspectionConfigurationChanged = {
            notifications += 1
            changed.fulfill()
        }

        await support.inspectionService.analyzeNow(document(source), force: true)
        let before = await support.inspectionService.diagnostics(for: document(source)).compactMap(\.code)
        XCTAssertTrue(before.contains("self-assignment"))

        IDEPreferences.shared.setEnabled(false, for: .selfAssignment)
        workspace.javaInspectionPreferencesChanged()
        await fulfillment(of: [changed], timeout: 5)
        await support.inspectionService.analyzeNow(document(source), force: true)
        let after = await support.inspectionService.diagnostics(for: document(source)).compactMap(\.code)
        XCTAssertFalse(after.contains("self-assignment"))

        // The same settings again are not a change.
        workspace.javaInspectionPreferencesChanged()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(notifications, 1)
    }
}
