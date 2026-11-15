import JavaIntelligence
import XCTest
@testable import Umbra

/// The Problems panel never shows a pending check as "No problems", never turns pending into a
/// permanent state, and names what failed when a check cannot run.
final class IDEResolutionStatusTests: XCTestCase {
    private func make(_ readiness: JavaResolutionReadiness?, _ activity: IDEResolutionStatus.Activity = .init(), names: [String: String] = [:]) -> IDEResolutionStatus {
        IDEResolutionStatus.make(readiness: readiness, activity: activity) { names[$0] }
    }

    func testAuthoritativeIsComplete() {
        XCTAssertEqual(make(nil), .complete)
    }

    func testNoJDKIsPendingWhileIndexingThenUnavailable() {
        let readiness = JavaResolutionReadiness(platformMissing: true, classpathIncomplete: false, missingShards: [])
        var indexing = IDEResolutionStatus.Activity()
        indexing.isIndexingJDK = true
        guard case .pending = make(readiness, indexing) else { return XCTFail("indexing the JDK is pending") }
        XCTAssertEqual(make(readiness), .unavailable("No JDK is indexed, so missing classes are not reported.", action: .chooseJDK))
    }

    func testAnUnsyncedProjectIsUnavailableWithASyncAction() {
        let readiness = JavaResolutionReadiness(platformMissing: false, classpathIncomplete: true, missingShards: [])
        var waiting = IDEResolutionStatus.Activity()
        waiting.awaitsProjectModel = true
        guard case .unavailable(_, action: .syncProject) = make(readiness, waiting) else { return XCTFail("declined or failed sync") }
        waiting.isSyncing = true
        guard case .pending = make(readiness, waiting) else { return XCTFail("a running sync is pending") }
    }

    func testAFailedJarIsNamed() {
        let readiness = JavaResolutionReadiness(platformMissing: false, classpathIncomplete: false, missingShards: ["/cache/jar-a.idx"])
        XCTAssertEqual(
            make(readiness, names: ["/cache/jar-a.idx": "guava-33.0.jar"]),
            .unavailable("guava-33.0.jar could not be indexed, so missing classes are not reported for this module.", action: .syncProject)
        )
        var indexing = IDEResolutionStatus.Activity()
        indexing.isIndexingDependencies = true
        guard case .pending = make(readiness, indexing) else { return XCTFail("still indexing jars is pending") }
    }

    func testSummaryPrefersUnavailableThenPending() {
        let pending = IDEResolutionStatus.pending("p")
        let unavailable = IDEResolutionStatus.unavailable("u", action: nil)
        XCTAssertEqual(IDEResolutionStatus.summary([.complete, pending, .complete]), pending)
        XCTAssertEqual(IDEResolutionStatus.summary([pending, unavailable]), unavailable)
        XCTAssertEqual(IDEResolutionStatus.summary([IDEResolutionStatus]()), .complete)
    }
}
