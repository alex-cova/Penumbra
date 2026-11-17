import XCTest
@_spi(Benchmarks) import EditorIntelligence
@testable import Penumbra

@MainActor
final class AdapterDebouncerTests: XCTestCase {
    func testMaximumWaitIsASecondOrFiveDelays() {
        XCTAssertEqual(AdapterDebouncer.maximumWait(forDelay: 0.2), 1)
        XCTAssertEqual(AdapterDebouncer.maximumWait(forDelay: 0.5), 2.5)
        XCTAssertEqual(AdapterDebouncer.maximumWait(forDelay: 0), 1)
    }

    func testAPauseRefreshesOnceAfterTheDelay() async throws {
        let debouncer = AdapterDebouncer()
        var runs = 0
        for _ in 0..<5 {
            debouncer.schedule(delay: 0.1) { runs += 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runs, 0, "calls inside the delay keep postponing the refresh")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(runs, 1)
    }

    /// A key held down calls every ~33 ms and never leaves a 200 ms gap; the refresh still has to
    /// land, or the edit queue behind it grows for as long as the key is down.
    func testACallStreamWithoutAPauseStillRefreshesWithinTheMaximumWait() async throws {
        let debouncer = AdapterDebouncer()
        var runs = 0
        let start = ContinuousClock.now
        var firstRunAt: Duration?
        while ContinuousClock.now - start < .milliseconds(1_600) {
            debouncer.schedule(delay: 0.2) {
                runs += 1
                if firstRunAt == nil { firstRunAt = ContinuousClock.now - start }
            }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        XCTAssertGreaterThanOrEqual(runs, 1, "no refresh in 1.6 s of continuous calls")
        let first = try XCTUnwrap(firstRunAt)
        XCTAssertLessThan(first, .milliseconds(1_300), "first refresh came after \(first)")
        XCTAssertGreaterThan(first, .milliseconds(800), "refreshed before the maximum wait: \(first)")
    }

    func testCancelForgetsTheWaitingCall() async throws {
        let debouncer = AdapterDebouncer()
        var runs = 0
        debouncer.schedule(delay: 0.05) { runs += 1 }
        debouncer.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(runs, 0)
    }

    // MARK: - Manual clock: no wall time, no sleeps

    /// 120 calls in one burst, the clock never moving: the refresh does not run, one sleeper waits for the latest
    /// call (the earlier ones were cancelled), and moving the clock past the delay runs it exactly once.
    func testABurstUnderAFrozenClockRefreshesOnceWhenTheClockPassesTheDelay() async {
        let clock = ManualDebounceTimer()
        let debouncer = AdapterDebouncer(timer: clock.timer)
        var runs = 0
        for _ in 0..<120 { debouncer.schedule(delay: 0.2) { runs += 1 } }
        await settleSleepers(clock, expecting: 1)
        XCTAssertEqual(runs, 0)

        clock.advance(by: 0.2)
        await waitUntil { runs == 1 }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }

    /// Calls that never leave a gap still refresh once the oldest unrefreshed call has waited the maximum
    /// (a second for a 0.2 s delay), and not before: the flush is a function of the clock alone.
    func testTheMaximumWaitFlushesExactlyWhenTheClockPassesIt() async {
        let clock = ManualDebounceTimer()
        let debouncer = AdapterDebouncer(timer: clock.timer)
        var runs = 0
        // 6 steps of 0.15 s: 0.9 s since the first call, under the 1 s maximum.
        // Each call's sleeper registers when its task first runs, so the clock moves only after it has.
        for _ in 0..<6 {
            debouncer.schedule(delay: 0.2) { runs += 1 }
            await settleSleepers(clock, expecting: 1)
            clock.advance(by: 0.15)
        }
        XCTAssertEqual(runs, 0, "0.9 s of calls is still inside the maximum wait")

        // The seventh call is made 0.9 s after the first; it may wait 0.1 s more, and no longer.
        debouncer.schedule(delay: 0.2) { runs += 1 }
        await settleSleepers(clock, expecting: 1)
        clock.advance(by: 0.1)
        await waitUntil { runs == 1 }
        XCTAssertEqual(runs, 1, "the refresh must land when the maximum wait is reached")
    }

    /// A cancelled debouncer leaves no sleeper behind and never runs.
    func testCancelLeavesNoSleeperAndRunsNothing() async {
        let clock = ManualDebounceTimer()
        let debouncer = AdapterDebouncer(timer: clock.timer)
        var runs = 0
        debouncer.schedule(delay: 0.2) { runs += 1 }
        await settleSleepers(clock, expecting: 1)
        debouncer.cancel()
        await settleSleepers(clock, expecting: 0)
        clock.advance(by: 5)
        await Task.yield()
        XCTAssertEqual(runs, 0)
    }

    /// Waits for the scheduled tasks to reach the clock (or be cancelled by it). Passing is an event, not a delay:
    /// the loop only gives up after a generous number of yields, which a failure would reach.
    private func settleSleepers(_ clock: ManualDebounceTimer, expecting count: Int) async {
        for _ in 0..<10_000 {
            if clock.pendingSleeperCount == count { return }
            await Task.yield()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }
}
