import XCTest
@testable import Penumbra

@MainActor
final class FindSearchSchedulerTests: XCTestCase {
    func testImmediateSearchAppliesPartialThenCompleteOutcome() async {
        let session = FindSession()
        session.query = "a"
        let scheduler = FindSearchScheduler()
        let text = String(repeating: "a ", count: 8_000)
        var applyCount = 0
        var sawIncomplete = false
        scheduler.scheduleRefresh(
            session: session,
            text: text,
            anchorLocation: 0,
            immediate: true,
            apply: {
                applyCount += 1
                if !session.isComplete {
                    sawIncomplete = true
                }
            }
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(session.isComplete && session.matchCount == 8_000) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.matchCount, 8_000)
        XCTAssertTrue(sawIncomplete, "long scans should publish at least one incomplete snapshot")
        XCTAssertGreaterThanOrEqual(applyCount, 2)
    }

    func testCancelDropsInFlightPartials() async {
        let session = FindSession()
        session.query = "needle"
        let scheduler = FindSearchScheduler()
        let text = String(repeating: "needle ", count: 80_000)
        scheduler.scheduleRefresh(session: session, text: text, anchorLocation: 0, immediate: true, apply: {})
        scheduler.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.matchCount, 0)
        XCTAssertTrue(session.isComplete)
    }
}
