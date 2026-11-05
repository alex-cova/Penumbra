import XCTest
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
}
