import Foundation
import SwiftIntelligence
import TypeScriptIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEIndexActivityTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("index-activity-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func project(file: String, text: String) throws -> URL {
        let root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return root
    }

    private func waitUntil(_ message: String, timeout: Double = 10, _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let done = await condition()
        XCTAssertTrue(done, message)
    }

    // MARK: The tracker

    func testAKindStaysActiveUntilEveryBuildOfItHasEnded() {
        let activity = IDEIndexActivity()
        XCTAssertTrue(activity.active.isEmpty)
        let first = activity.begin(.swift)
        let second = activity.begin(.swift)
        let other = activity.begin(.javaUsages)
        XCTAssertEqual(activity.active, [.swift, .javaUsages])
        activity.end(first)
        XCTAssertTrue(activity.isActive(.swift), "the replacement build is still running")
        activity.end(second)
        XCTAssertFalse(activity.isActive(.swift))
        XCTAssertTrue(activity.isActive(.javaUsages), "kinds are independent")
        activity.end(other)
        XCTAssertTrue(activity.active.isEmpty)
    }

    func testEndingATokenTwiceDoesNotEndAnotherBuild() {
        let activity = IDEIndexActivity()
        let stale = activity.begin(.typeScript)
        activity.end(stale)
        let current = activity.begin(.typeScript)
        activity.end(stale)
        XCTAssertTrue(activity.isActive(.typeScript), "a late, repeated end of an old build must not end the new one")
        activity.end(current)
        XCTAssertFalse(activity.isActive(.typeScript))
    }

    // MARK: The language supports

    func testSwiftIsBuildingFromTheMomentTheProjectChanges() async throws {
        let activity = IDEIndexActivity()
        let support = IDESwiftSupport(activity: activity)
        let root = try project(file: "A.swift", text: "struct A {}\n")
        support.projectDidChange(root: root)
        XCTAssertTrue(activity.isActive(.swift), "before the task has run a line, the index looks empty, not unbuilt")
        await waitUntil("the build ends") { !activity.isActive(.swift) }
        let count = await support.index.fileCount
        XCTAssertEqual(count, 1)
    }

    func testASupersededSwiftBuildDoesNotReportReadyEarly() async throws {
        let activity = IDEIndexActivity()
        let support = IDESwiftSupport(activity: activity)
        let root = try project(file: "A.swift", text: "struct A {}\n")
        support.projectDidChange(root: root)
        support.projectDidChange(root: root)
        XCTAssertTrue(activity.isActive(.swift))
        await waitUntil("both builds end") { !activity.isActive(.swift) }
        let building = await support.index.isBuilding
        XCTAssertFalse(building)
    }

    func testTypeScriptIsBuildingFromTheMomentTheProjectChanges() async throws {
        let activity = IDEIndexActivity()
        let support = IDETypeScriptSupport(activity: activity)
        let root = try project(file: "a.ts", text: "export const a = 1\n")
        support.projectDidChange(root: root)
        XCTAssertTrue(activity.isActive(.typeScript))
        await waitUntil("the build ends") { !activity.isActive(.typeScript) }
        let count = await support.index.fileCount
        XCTAssertEqual(count, 1)
    }

    func testACancelledBuildStillEndsItsActivity() async throws {
        let activity = IDEIndexActivity()
        let support = IDESwiftSupport(activity: activity)
        let root = try project(file: "A.swift", text: "struct A {}\n")
        support.projectDidChange(root: root)
        support.cancelIndexing()
        await waitUntil("a cancelled build must not leave the banner on for good") { !activity.isActive(.swift) }
    }

    func testTheIndexesAreNotBuildingWhenIdle() async throws {
        let swift = SwiftIndex()
        let typeScript = TypeScriptIndex()
        let idleSwift = await swift.isBuilding
        let idleTypeScript = await typeScript.isBuilding
        XCTAssertFalse(idleSwift)
        XCTAssertFalse(idleTypeScript)
        let root = try project(file: "A.swift", text: "struct A {}\n")
        await swift.setRoot(root)
        await typeScript.setRoot(root)
        let doneSwift = await swift.isBuilding
        let doneTypeScript = await typeScript.isBuilding
        XCTAssertFalse(doneSwift, "a finished walk is not building")
        XCTAssertFalse(doneTypeScript)
    }

    // MARK: Java

    func testJavaSourcesAndUsagesAreBuildingUntilBothIndexesFinish() async throws {
        let harness = GradleHarness(base: base)
        defer { harness.teardown() }
        let root = try project(file: "A.java", text: "class A {}\n")
        harness.setRoot(root)
        let activity = harness.indexActivity
        XCTAssertTrue(activity.isActive(.javaSources))
        XCTAssertTrue(activity.isActive(.javaUsages))
        await waitUntil("both Java indexes finish and leave nothing marked") { activity.active.isEmpty }
    }

    func testClosingTheFolderLeavesNothingMarkedBuilding() async throws {
        let harness = GradleHarness(base: base)
        defer { harness.teardown() }
        harness.setRoot(try project(file: "A.java", text: "class A {}\n"))
        harness.setRoot(nil)
        await waitUntil("the superseded build ends too") { harness.indexActivity.active.isEmpty }
    }
}
