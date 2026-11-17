import Foundation

/// Where a debounce reads "now" and waits. The default is the machine's clock; a test hands the
/// same type a ``ManualDebounceTimer`` so the moment a debounced request may start is decided by
/// the test, not by how long the main actor happened to be busy (a 50 ms completion debounce fires
/// mid-burst whenever one keystroke is handled 50 ms late).
///
/// Production code never builds anything but ``system``.
public struct DebounceTimer: Sendable {
    /// Monotonic nanoseconds.
    public var nowNanoseconds: @Sendable () -> UInt64
    /// Waits `seconds`, throwing `CancellationError` when the calling task is cancelled.
    public var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void

    public init(
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void
    ) {
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }

    public static let system = DebounceTimer(
        nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    )
}

/// A clock that moves only when ``advance(by:)`` is called. Sleepers wait for their deadline and
/// are resumed in deadline order; a cancelled sleeper throws at once, like `Task.sleep`.
@_spi(Benchmarks)
public final class ManualDebounceTimer: @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: UInt64 = 1_000_000_000
    private var sleepers: [UInt64: Sleeper] = [:]
    private var cancelledBeforeRegistering: Set<UInt64> = []
    private var nextID: UInt64 = 0

    public init() {}

    public var timer: DebounceTimer {
        DebounceTimer(
            nowNanoseconds: { [self] in lock.withLock { now } },
            sleep: { [self] seconds in try await wait(seconds) }
        )
    }

    /// How many sleepers are waiting for the clock.
    public var pendingSleeperCount: Int { lock.withLock { sleepers.count } }

    /// Moves the clock and resumes every sleeper whose deadline has passed.
    public func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            now &+= UInt64(max(0, seconds) * 1_000_000_000)
            let ids = sleepers.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
            for (id, _) in ids { sleepers[id] = nil }
            return ids.map(\.value)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func wait(_ seconds: TimeInterval) async throws {
        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome: Result<Void, Error>? = lock.withLock {
                    if cancelledBeforeRegistering.remove(id) != nil { return .failure(CancellationError()) }
                    let deadline = now &+ UInt64(max(0, seconds) * 1_000_000_000)
                    if deadline <= now { return .success(()) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper }
                cancelledBeforeRegistering.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
