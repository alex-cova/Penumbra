import Foundation
import JavaIntelligence
import SwiftIntelligence
import XCTest
@testable import Umbra

/// Swift inspection choices live in the profiles Java's do: the Default profile's `swift` section, a global profile's
/// file and the project's `.umbra/inspections.json`.
@MainActor
final class IDESwiftInspectionSettingsTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private var suiteName: String!
    private let preferences = IDEPreferences.shared

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("swift-profiles-\(UUID().uuidString)")
        suiteName = "umbra.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> IDEInspectionProfiles {
        IDEInspectionProfiles(directory: directory, defaults: suite, preferences: preferences)
    }

    func testNothingStoredMeansTheStandardSwiftProfile() {
        let store = makeStore()
        XCTAssertEqual(store.defaultProfile.swift, .standard)
        XCTAssertNil(store.defaultProfile.sections["swift"], "a profile that never touched Swift stays a Java-only file")
    }

    func testTheFlatKeysFromBeforeProfilesSeedTheDefaultProfileAndAreForgottenOnceItIsSaved() {
        suite.set(["empty-catch"], forKey: IDESwiftInspectionSettings.disabledKey)
        suite.set(["force-try"], forKey: IDESwiftInspectionSettings.enabledKey)
        suite.set(["force-try": "error"], forKey: IDESwiftInspectionSettings.severitiesKey)
        suite.set([SwiftInspectionRule.longFunction.code: 120], forKey: IDESwiftInspectionSettings.limitsKey)
        let store = makeStore()
        var swift = store.defaultProfile.swift
        XCTAssertEqual(swift.disabled, ["empty-catch"])
        XCTAssertEqual(swift.enabled, ["force-try"])
        XCTAssertEqual(swift.severities, ["force-try": "error"])
        XCTAssertEqual(swift.limits, ["long-function": 120])

        // The first change writes the section and drops the old keys.
        swift.setEnabled(false, for: .explicitInit)
        var profile = store.defaultProfile
        profile.swift = swift
        store.save(profile)
        XCTAssertNotNil(suite.data(forKey: IDEInspectionProfiles.swiftSectionKey))
        XCTAssertNil(suite.stringArray(forKey: IDESwiftInspectionSettings.disabledKey))
        let again = makeStore().defaultProfile.swift
        XCTAssertEqual(again.disabled, ["empty-catch", "explicit-init"])
        XCTAssertEqual(again.limits, ["long-function": 120])
    }

    func testSavingDefaultLeavesJavaAloneAndTheOtherWayRound() {
        let store = makeStore()
        var profile = store.defaultProfile
        profile.swift.setEnabled(true, for: .forceUnwrap)
        let javaBefore = (profile.disabled, profile.severities)
        store.save(profile)
        let saved = store.defaultProfile
        XCTAssertEqual(saved.swift.enabled, ["force-unwrap"])
        XCTAssertEqual(saved.disabled, javaBefore.0)
        XCTAssertEqual(saved.severities, javaBefore.1)

        // Restoring the standard Swift profile removes the section again.
        var restored = saved
        restored.swift = .standard
        store.save(restored)
        XCTAssertEqual(store.defaultProfile.swift, .standard)
    }

    func testAGlobalProfilesFileCarriesItsSwiftSectionThroughAReload() throws {
        let store = makeStore()
        var created = store.create(named: "Strict", from: store.defaultProfile)
        created.swift.setEnabled(true, for: .forceUnwrap)
        created.swift.scopedOverrides = [.init(code: "force-unwrap", scope: .tests, isEnabled: false)]
        store.save(created)

        let file = try String(contentsOf: directory.appendingPathComponent("Strict.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("\"swift\""), file)
        XCTAssertTrue(file.contains("\"name\""), "Java's keys are still there: \(file)")
        let loaded = try XCTUnwrap(makeStore().profile(named: "Strict"))
        XCTAssertEqual(loaded.swift.enabled, ["force-unwrap"])
        XCTAssertEqual(loaded.swift.scopedOverrides.count, 1)

        // Editing Java's side of the profile keeps Swift's.
        var edited = loaded
        edited.setEnabled(false, for: .selfAssignment)
        XCTAssertEqual(edited.swift, loaded.swift)
    }

    func testTheProjectFileKeepsBothLanguagesAndAnOldOneStillLoads() throws {
        let root = directory.appendingPathComponent("project", isDirectory: true)
        var profile = JavaInspectionProfile.standard(name: "Project")
        profile.swift.setEnabled(false, for: .emptyCatch)
        try IDEInspectionProfiles.writeProjectProfile(profile, root: root)
        let loaded = try XCTUnwrap(IDEInspectionProfiles.loadProjectProfile(root: root))
        XCTAssertEqual(loaded.swift.disabled, ["empty-catch"])

        // A file written before Swift had a section.
        let old = #"{"profile":{"name":"Project","disabled":["unused-import"],"severities":{},"limits":{},"treatsPublicApiAsUsed":true,"scopedOverrides":[]}}"#
        try old.write(to: IDEInspectionProfiles.projectFileURL(root: root), atomically: true, encoding: .utf8)
        let legacy = try XCTUnwrap(IDEInspectionProfiles.loadProjectProfile(root: root))
        XCTAssertEqual(legacy.swift, .standard)
        XCTAssertEqual(legacy.disabled, ["unused-import"])
    }

    func testTheWorkspacesChoiceFollowsTheProjectProfileAndTellsEveryoneWhenItChanges() throws {
        let store = makeStore()
        let defaults = UserDefaults(suiteName: suiteName)!
        let inspections = IDEWorkspaceInspections(store: store, defaults: defaults)
        let root = directory.appendingPathComponent("project", isDirectory: true)
        var profile = JavaInspectionProfile.standard(name: "Project")
        profile.swift.setEnabled(true, for: .forceUnwrap)
        try IDEInspectionProfiles.writeProjectProfile(profile, root: root)
        inspections.setRoot(root)
        XCTAssertEqual(inspections.activeSource, .project)
        XCTAssertEqual(inspections.activeSwiftProfile.enabled, ["force-unwrap"])

        var changes = 0
        inspections.onChange = { changes += 1 }
        inspections.edit { $0.swift.setSeverity(.error, for: .forceUnwrap) }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(IDEInspectionProfiles.loadProjectProfile(root: root)?.swift.severities, ["force-unwrap": "error"])
        inspections.edit { $0.swift.setSeverity(.error, for: .forceUnwrap) }
        XCTAssertEqual(changes, 1, "no change, no notification")
    }

    func testTheEditorsResolverGivesEachFileItsScopesOptionsAndSaysWhetherItChanged() {
        let resolver = IDESwiftInspectionResolver()
        var profile = SwiftInspectionProfile.standard
        profile.scopedOverrides = [.init(code: "redundant-void-return", scope: .tests, isEnabled: false)]
        let root = URL(fileURLWithPath: "/proj")
        XCTAssertTrue(resolver.update(profile: profile, root: root))
        XCTAssertFalse(resolver.update(profile: profile, root: root), "the same profile is no change")

        XCTAssertTrue(resolver.options(for: root.appendingPathComponent("Sources/A.swift")).isEnabled(.redundantVoidReturn))
        XCTAssertFalse(resolver.options(for: root.appendingPathComponent("Tests/ATests/ATests.swift")).isEnabled(.redundantVoidReturn))
        XCTAssertTrue(resolver.options(for: nil).isEnabled(.redundantVoidReturn))
        XCTAssertTrue(resolver.update(profile: profile, root: URL(fileURLWithPath: "/other")), "another project root reclassifies the files")
    }

    func testSupportAnswersWithTheInspectionsOfTheResolver() async {
        let support = IDESwiftSupport()
        var profile = SwiftInspectionProfile.standard
        profile.setEnabled(true, for: .forceUnwrap)
        support.inspectionResolver.update(profile: profile, root: nil)
        let found = support.inspections.analysis(of: "func f(x: Int?) {\n    let y = x!\n    _ = y\n}\n", url: nil)
        XCTAssertEqual(found.findings.map(\.id), ["force-unwrap"])
        support.inspectionResolver.update(profile: .standard, root: nil)
        XCTAssertTrue(support.inspections.analysis(of: "func f(x: Int?) {\n    let y = x!\n    _ = y\n}\n", url: nil).findings.isEmpty)
    }
}
