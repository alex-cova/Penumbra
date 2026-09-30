import Foundation
import XCTest
@testable import JavaIntelligence
@testable import Umbra

/// Several windows mean several readers and writers of the same JSON files. Each store must pick up
/// what the others wrote before it reads or writes, or the last writer wins and the rest is lost.
/// Two instances on one file stand in for two windows (or two processes).
final class SharedStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func project(_ name: String) -> URL { URL(fileURLWithPath: "/work/\(name)", isDirectory: true) }

    // MARK: - Gradle trust

    func testATrustDecisionInOneStoreIsSeenByTheOtherWithoutARestart() {
        let windowA = GradleTrustStore(storeURL: file("trust.json"))
        let windowB = GradleTrustStore(storeURL: file("trust.json"))

        windowA.setTrusted(true, for: project("alpha"))

        XCTAssertTrue(windowB.isTrusted(project("alpha")))
        XCTAssertEqual(windowB.decision(for: project("alpha")), true)
    }

    func testADeclineInOneStoreIsSeenByTheOther() {
        let windowA = GradleTrustStore(storeURL: file("trust.json"))
        let windowB = GradleTrustStore(storeURL: file("trust.json"))
        windowA.setTrusted(true, for: project("alpha"))
        XCTAssertTrue(windowB.isTrusted(project("alpha")))

        windowA.setTrusted(false, for: project("alpha"))

        XCTAssertFalse(windowB.isTrusted(project("alpha")))
        XCTAssertEqual(windowB.decision(for: project("alpha")), false)
    }

    func testTrustDecisionsFromTwoStoresAreBothKept() {
        let windowA = GradleTrustStore(storeURL: file("trust.json"))
        let windowB = GradleTrustStore(storeURL: file("trust.json"))

        windowA.setTrusted(true, for: project("alpha"))
        windowB.setTrusted(false, for: project("beta"))
        windowA.setTrusted(true, for: project("gamma"))

        let fresh = GradleTrustStore(storeURL: file("trust.json"))
        XCTAssertEqual(fresh.decision(for: project("alpha")), true)
        XCTAssertEqual(fresh.decision(for: project("beta")), false)
        XCTAssertEqual(fresh.decision(for: project("gamma")), true)
    }

    func testAnUnreadableTrustFileKeepsWhatIsInMemory() throws {
        let store = GradleTrustStore(storeURL: file("trust.json"))
        store.setTrusted(true, for: project("alpha"))

        try Data("not json".utf8).write(to: file("trust.json"))

        XCTAssertTrue(store.isTrusted(project("alpha")))
    }

    // MARK: - JDK selection

    func testJDKChoicesFromTwoStoresAreBothKept() {
        let windowA = JDKSelectionStore(storeURL: file("jdk.json"))
        let windowB = JDKSelectionStore(storeURL: file("jdk.json"))
        let jdk17 = URL(fileURLWithPath: "/jdks/17")
        let jdk21 = URL(fileURLWithPath: "/jdks/21")

        windowA.setProject(jdk17, forProject: project("alpha"))
        windowB.setProject(jdk21, forProject: project("beta"))
        windowA.setGlobal(jdk21)

        let fresh = JDKSelectionStore(storeURL: file("jdk.json"))
        XCTAssertEqual(fresh.selection(forProject: project("alpha")).project?.path, "/jdks/17")
        XCTAssertEqual(fresh.selection(forProject: project("beta")).project?.path, "/jdks/21")
        XCTAssertEqual(fresh.selection(forProject: project("alpha")).global?.path, "/jdks/21")
    }

    func testAJDKAddedInOneStoreAppearsInTheOther() {
        let windowA = JDKSelectionStore(storeURL: file("jdk.json"))
        let windowB = JDKSelectionStore(storeURL: file("jdk.json"))
        XCTAssertTrue(windowB.customJDKs.isEmpty)

        windowA.addCustomJDK(URL(fileURLWithPath: "/jdks/custom"))

        XCTAssertEqual(windowB.customJDKs.map(\.path), ["/jdks/custom"])
    }

    // MARK: - Run configurations

    func testRunConfigurationsOfTwoProjectsInTwoStoresAreBothKept() {
        let windowA = JavaRunConfigurationStore(storeURL: file("run.json"))
        let windowB = JavaRunConfigurationStore(storeURL: file("run.json"))
        let a = JavaRunConfiguration(name: "A", target: .gradleRun(projectPath: ":a"))
        let b = JavaRunConfiguration(name: "B", target: .gradleRun(projectPath: ":b"))

        windowA.setLast(a, forProject: project("alpha"))
        windowB.setLast(b, forProject: project("beta"))
        windowA.save(JavaRunConfiguration(name: "A2", target: .gradleRun(projectPath: ":a2")), forProject: project("alpha"))

        let fresh = JavaRunConfigurationStore(storeURL: file("run.json"))
        XCTAssertEqual(fresh.configurations(forProject: project("alpha")).map(\.name), ["A", "A2"])
        XCTAssertEqual(fresh.configurations(forProject: project("beta")).map(\.name), ["B"])
        XCTAssertEqual(fresh.last(forProject: project("beta"))?.id, b.id)
    }

    func testARunConfigurationSavedInOneStoreIsSeenByTheOther() {
        let windowA = JavaRunConfigurationStore(storeURL: file("run.json"))
        let windowB = JavaRunConfigurationStore(storeURL: file("run.json"))

        let a = JavaRunConfiguration(name: "A", target: .gradleRun(projectPath: ":a"))
        windowA.setLast(a, forProject: project("alpha"))

        XCTAssertEqual(windowB.last(forProject: project("alpha"))?.id, a.id)
    }

    // MARK: - Breakpoints

    func testBreakpointsOfTwoProjectsInTwoStoresAreBothKept() {
        let windowA = JavaBreakpointStore(storeURL: file("breakpoints.json"))
        let windowB = JavaBreakpointStore(storeURL: file("breakpoints.json"))
        let fileA = URL(fileURLWithPath: "/work/alpha/A.java")
        let fileB = URL(fileURLWithPath: "/work/beta/B.java")

        windowA.toggle(atLine: 10, file: fileA, project: project("alpha"))
        windowB.toggle(atLine: 20, file: fileB, project: project("beta"))
        windowA.toggle(atLine: 11, file: fileA, project: project("alpha"))

        let fresh = JavaBreakpointStore(storeURL: file("breakpoints.json"))
        XCTAssertEqual(fresh.breakpoints(forProject: project("alpha")).map(\.line), [10, 11])
        XCTAssertEqual(fresh.breakpoints(forProject: project("beta")).map(\.line), [20])
    }

    func testABreakpointToggledInOneStoreIsSeenByTheOther() {
        let windowA = JavaBreakpointStore(storeURL: file("breakpoints.json"))
        let windowB = JavaBreakpointStore(storeURL: file("breakpoints.json"))

        windowA.toggle(atLine: 5, file: URL(fileURLWithPath: "/work/alpha/A.java"), project: project("alpha"))

        XCTAssertEqual(windowB.breakpoints(forProject: project("alpha")).map(\.line), [5])
    }

    // MARK: - File change stamp

    func testStampNoticesAWriteACreationAndADeletion() throws {
        let url = file("stamped.json")
        var stamp = FileChangeStamp(url: url)
        XCTAssertFalse(stamp.hasChanged(at: url))

        try Data("1".utf8).write(to: url)
        XCTAssertTrue(stamp.hasChanged(at: url))
        stamp.update(at: url)
        XCTAssertFalse(stamp.hasChanged(at: url))

        Thread.sleep(forTimeInterval: 0.02)
        try Data("2".utf8).write(to: url)
        XCTAssertTrue(stamp.hasChanged(at: url))
        stamp.update(at: url)

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(stamp.hasChanged(at: url))
    }
}
