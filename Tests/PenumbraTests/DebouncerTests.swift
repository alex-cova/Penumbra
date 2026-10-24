import XCTest
@testable import Umbra

@MainActor
final class DebouncerTests: XCTestCase {
    private final class Log {
        var values: [Int] = []
    }

    private func waitFor(_ message: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }

    func testOnlyTheLatestRequestRuns() async {
        let debouncer = Debouncer()
        let log = Log()
        for value in 1...5 { debouncer.schedule(after: .milliseconds(60)) { log.values.append(value) } }
        await waitFor("the last one ran") { !log.values.isEmpty }
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(log.values, [5])
        XCTAssertFalse(debouncer.isPending)
    }

    func testCancelStopsAPendingRequest() async {
        let debouncer = Debouncer()
        let log = Log()
        debouncer.schedule(after: .milliseconds(50)) { log.values.append(1) }
        XCTAssertTrue(debouncer.isPending)
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.values, [])
    }

    func testAZeroDelayStillRunsOnATaskNotInline() async {
        let debouncer = Debouncer()
        let log = Log()
        debouncer.schedule { log.values.append(1) }
        XCTAssertEqual(log.values, [], "never inline: a keystroke must not wait for it")
        await waitFor("it ran") { log.values == [1] }
    }

    func testRescheduleCancelsARunningRequest() async {
        let debouncer = Debouncer()
        let log = Log()
        debouncer.schedule {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { log.values.append(1) }
        }
        try? await Task.sleep(for: .milliseconds(30))
        debouncer.schedule { log.values.append(2) }
        await waitFor("the new one ran") { log.values.contains(2) }
        XCTAssertEqual(log.values, [2], "the running one saw its cancellation")
    }

    func testKeysDebounceIndependently() async {
        let debouncer = KeyedDebouncer<String>()
        let log = Log()
        debouncer.schedule("a", after: .milliseconds(40)) { log.values.append(1) }
        debouncer.schedule("b", after: .milliseconds(40)) { log.values.append(2) }
        debouncer.schedule("a", after: .milliseconds(40)) { log.values.append(3) }
        await waitFor("both ran") { log.values.count == 2 }
        XCTAssertEqual(Set(log.values), [2, 3])
    }

    func testCancelAllCancelsEveryKey() async {
        let debouncer = KeyedDebouncer<Int>()
        let log = Log()
        for key in 0..<3 { debouncer.schedule(key, after: .milliseconds(40)) { log.values.append(key) } }
        debouncer.cancelAll()
        XCTAssertFalse(debouncer.isPending(0))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(log.values, [])
    }
}
