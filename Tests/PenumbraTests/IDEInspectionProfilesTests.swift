import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// Named inspection profiles: the legacy keys are "Default", the others are files, and a project's
/// `.umbra/inspections.json` wins for its window.
@MainActor
final class IDEInspectionProfilesTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private var suiteName: String!
    private var originalDisabled: Set<String> = []
    private var originalSeverities: [String: String] = [:]
    private let preferences = IDEPreferences.shared

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        suiteName = "umbra.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        originalDisabled = preferences.javaDisabledInspections
        originalSeverities = preferences.javaInspectionSeverities
        preferences.resetJavaInspections()
    }

    override func tearDown() {
        preferences.javaDisabledInspections = originalDisabled
        preferences.javaInspectionSeverities = originalSeverities
        UserDefaults.standard.removeObject(forKey: "com.umbra.editor.javaInspectionScopedOverrides")
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> IDEInspectionProfiles {
        IDEInspectionProfiles(directory: directory, defaults: suite, preferences: preferences)
    }

    func testDefaultProfileIsTheLegacyPreferenceKeys() {
        let store = makeStore()
        preferences.setEnabled(false, for: .selfAssignment)
        preferences.setSeverity(.error, for: .manualMinMax)
        let profile = store.defaultProfile
        XCTAssertTrue(profile.disabled.contains("self-assignment"))
        XCTAssertEqual(profile.severities["manual-min-max"], "error")
        XCTAssertEqual(store.names, ["Default"])
    }

    func testSavingDefaultWritesBackToThePreferences() {
        let store = makeStore()
        var profile = store.defaultProfile
        profile.setEnabled(false, for: .unusedLabel)
        profile.scopedOverrides = [.init(code: "unused-label", scope: .tests, isEnabled: true)]
        store.save(profile)
        XCTAssertFalse(preferences.isEnabled(.unusedLabel))
        XCTAssertEqual(store.defaultProfile.scopedOverrides.count, 1)
        profile.scopedOverrides = []
        store.save(profile)
        XCTAssertTrue(store.defaultProfile.scopedOverrides.isEmpty)
    }

    func testCustomProfilesAreFilesThatSurviveAReload() throws {
        let store = makeStore()
        var created = store.create(named: "Strict", from: store.defaultProfile)
        created.setSeverity(.error, for: .stringComparisonIdentity)
        store.save(created)
        XCTAssertEqual(store.names, ["Default", "Strict"])
        let again = makeStore()
        XCTAssertEqual(again.profile(named: "Strict")?.severities["string-comparison-identity"], "error")
        XCTAssertEqual(store.uniqueName("Strict"), "Strict 2")
        // A rename moves the file and keeps the selection.
        store.selectedName = "Strict"
        store.rename("Strict", to: "Stricter")
        XCTAssertEqual(store.names, ["Default", "Stricter"])
        XCTAssertEqual(store.selectedName, "Stricter")
        XCTAssertEqual(makeStore().names, ["Default", "Stricter"])
        store.delete("Stricter")
        XCTAssertEqual(store.selectedName, "Default")
        XCTAssertEqual(makeStore().names, ["Default"])
    }

    func testProjectFileWinsForItsWindowAndFollowsEdits() throws {
        let store = makeStore()
        let root = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inspections = IDEWorkspaceInspections(store: store, defaults: suite)
        var changes = 0
        inspections.onChange = { changes += 1 }

        inspections.setRoot(root)
        XCTAssertEqual(inspections.activeSource, .global("Default"))

        inspections.copyToProject()
        XCTAssertEqual(inspections.activeSource, .project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: IDEInspectionProfiles.projectFileURL(root: root).path))

        inspections.edit { $0.setEnabled(false, for: .systemOutErr) }
        XCTAssertFalse(inspections.activeProfile.isEnabled(.systemOutErr))
        // The global Default is untouched.
        XCTAssertTrue(store.defaultProfile.isEnabled(.systemOutErr))
        XCTAssertGreaterThanOrEqual(changes, 2)

        // A teammate edits the file: the window picks it up, once.
        var edited = try XCTUnwrap(IDEInspectionProfiles.loadProjectProfile(root: root))
        edited.setEnabled(true, for: .systemOutErr)
        try IDEInspectionProfiles.writeProjectProfile(edited, root: root)
        XCTAssertTrue(inspections.reloadProjectFile())
        XCTAssertFalse(inspections.reloadProjectFile())
        XCTAssertTrue(inspections.activeProfile.isEnabled(.systemOutErr))

        // Choosing a global profile is remembered for this project.
        inspections.select(.global("Default"))
        XCTAssertEqual(inspections.activeSource, .global("Default"))
        let reopened = IDEWorkspaceInspections(store: store, defaults: suite)
        reopened.setRoot(root)
        XCTAssertEqual(reopened.activeSource, .global("Default"))

        inspections.removeProjectProfile()
        XCTAssertFalse(inspections.hasProjectProfile)
        XCTAssertEqual(inspections.activeSource, .global("Default"))
    }

    func testProjectFileIsReadableAndStableOnDisk() throws {
        let root = directory.appendingPathComponent("p2")
        var profile = JavaInspectionProfile.standard(name: "Project")
        profile.disabled.insert("zzz")
        profile.disabled.insert("aaa")
        profile.scopedOverrides = [.init(code: "self-assignment", scope: .glob("**/gen/**"), severity: "noHighlighting")]
        try IDEInspectionProfiles.writeProjectProfile(profile, root: root)
        let text = try String(contentsOf: IDEInspectionProfiles.projectFileURL(root: root), encoding: .utf8)
        XCTAssertTrue(text.contains("\"profile\""))
        XCTAssertTrue(text.contains("glob:**/gen/**"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"aaa\"")).lowerBound, try XCTUnwrap(text.range(of: "\"zzz\"")).lowerBound)
        XCTAssertEqual(IDEInspectionProfiles.loadProjectProfile(root: root), profile)
        XCTAssertNil(IDEInspectionProfiles.loadProjectProfile(root: directory.appendingPathComponent("nothing")))
    }
}
