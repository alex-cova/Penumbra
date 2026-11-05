import EditorIntelligence
import HexKit
import XCTest
@testable import Penumbra

/// `runDetached` passes the awaiting task's cancellation to the detached child, which
/// `await Task.detached { … }.value` does not (F-05). Without it the `Task.isCancelled` checks in
/// `FindSearchEngine`'s scan loops can never fire: nothing ever cancels the child.
final class DetachedWorkTests: XCTestCase {
    func testTheResultOfTheWorkIsReturned() async {
        let value = await runDetached { 21 * 2 }
        XCTAssertEqual(value, 42)
    }

    func testAnErrorFromThrowingWorkReachesTheCaller() async {
        struct Failure: Error {}
        do {
            _ = try await runDetached { () throws -> Int in throw Failure() }
            XCTFail("the error was swallowed")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    func testCancellingTheCallerCancelsTheChild() async throws {
        let started = expectation(description: "child started")
        let stopped = expectation(description: "child saw the cancellation")
        let caller = Task {
            await runDetached(priority: .utility) {
                started.fulfill()
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
                stopped.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let before = DetachedWorkStatistics.counts

        caller.cancel()

        await fulfillment(of: [stopped], timeout: 5)
        _ = await caller.value
        XCTAssertGreaterThan(DetachedWorkStatistics.counts.cancelled, before.cancelled)
    }

    func testPlainTaskDetachedDoesNotPassCancellationOn() async throws {
        // The behaviour this helper exists to fix, pinned so nobody "simplifies" the helper away.
        let started = expectation(description: "child started")
        let flag = Flag()
        let caller = Task {
            await Task.detached {
                started.fulfill()
                try? await Task.sleep(nanoseconds: 300_000_000)
                flag.set(Task.isCancelled)
            }.value
        }
        await fulfillment(of: [started], timeout: 5)
        caller.cancel()
        _ = await caller.value
        XCTAssertFalse(flag.value, "Task.detached now propagates cancellation; runDetached may be redundant")
    }

    func testTheInFlightCountReturnsToZero() async {
        let before = DetachedWorkStatistics.counts.inFlight
        _ = await runDetached { 1 }
        XCTAssertEqual(DetachedWorkStatistics.counts.inFlight, before)
    }

    // MARK: - The scan that motivated it

    /// A scan of a very large file for a query that never matches would run until the end of the
    /// file; once the search that wanted it is superseded it must stop at the next check.
    func testASupersededFindScanStopsReading() async throws {
        let source = EndlessSource()
        let options = FindSearchOptions(query: "needle", matchCase: true)
        let scan = Task {
            await runDetached(priority: .userInitiated) {
                FindSearchEngine.search(options: options, in: source, anchorLocation: 0)
            }
        }
        try await waitUntil { source.reads >= 5 }
        let readsAtCancel = source.reads

        scan.cancel()

        let finished = expectation(description: "the scan returned")
        Task {
            _ = await scan.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertLessThan(source.reads - readsAtCancel, 100, "the scan kept reading after it was cancelled")
    }

    /// The hex editor's search has the same check (`Task.checkCancellation()` per chunk) and the
    /// same caller shape; a search of a multi-gigabyte file that the user has replaced must stop.
    func testASupersededHexSearchStopsReading() async throws {
        let source = EndlessByteSource()
        let pattern = try XCTUnwrap(HexPattern.hex("DEADBEEF"))
        let scan = Task {
            try await runDetached(priority: .userInitiated) {
                try HexSearch.scan(in: source, pattern: pattern, from: 0, limit: HexSearch.defaultLimit)
            }
        }
        try await waitUntil { source.reads >= 5 }
        let readsAtCancel = source.reads

        scan.cancel()

        let finished = expectation(description: "the search returned")
        Task {
            _ = try? await scan.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertLessThan(source.reads - readsAtCancel, 100, "the search kept reading after it was cancelled")
        do {
            _ = try await scan.value
            XCTFail("a cancelled search returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition never held"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

/// Four hundred million UTF-16 units of the letter a, read at about 500 windows a second: far more
/// than a test will wait for, so a scan that returns did so because it was cancelled.
private final class EndlessSource: FindTextSource, @unchecked Sendable {
    let utf16Length = 400_000_000
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func substring(utf16Offset: Int, length: Int) -> String {
        lock.withLock { count += 1 }
        Thread.sleep(forTimeInterval: 0.002)
        return String(repeating: "a", count: max(0, min(length, utf16Length - utf16Offset)))
    }
}

/// Four billion bytes of zeros, read at about 500 chunks a second.
private final class EndlessByteSource: HexByteSource, @unchecked Sendable {
    let count: Int64 = 4_000_000_000
    private let lock = NSLock()
    private var counted = 0

    var reads: Int { lock.withLock { counted } }

    func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.withLock { counted += 1 }
        Thread.sleep(forTimeInterval: 0.002)
        let length = min(buffer.count, Int(range.count))
        memset(buffer.baseAddress, 0, length)
        return length
    }
}
