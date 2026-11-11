import Foundation

/// One mutation at a time for each git directory.
///
/// Read-only commands (`status`, `log`, `diff`, `blame`) do not enter. A second mutation waits.
/// It does not cancel the one that is running. Cancelling a waiter before its body starts skips
/// that waiter and lets the next one run. Cancelling the running call cancels that call only.
///
/// Do not call `perform` from inside a `perform` for the same directory: the inner call waits for
/// the outer one. `preservingLocalChanges` and `commit` stay one lane entry at the call site.
public actor GitMutationLane {
    public static let shared = GitMutationLane()

    private var tails: [String: Task<Void, Never>] = [:]

    public init() {}

    public func perform<T: Sendable>(
        gitDirectory: URL,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let key = GitRepositoryID(workTree: gitDirectory, gitDirectory: gitDirectory).laneKey
        let previous = tails[key]
        let gate = MutationOutcome<T>()
        // The body waits until this call has installed its cancellation handler. Otherwise a
        // waiter that is already cancelled, and whose predecessor has finished, can enter the body
        // before `task.cancel()` runs.
        let ready = ReadyFlag()
        let task = Task.detached { [previous] in
            await previous?.value
            await ready.wait()
            if Task.isCancelled {
                gate.finish(.failure(CancellationError()))
                return
            }
            do {
                gate.finish(.success(try await body()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        tails[key] = Task.detached {
            await task.value
        }
        return try await withTaskCancellationHandler {
            ready.open()
            return try await gate.wait()
        } onCancel: {
            task.cancel()
        }
    }
}

/// One result, delivered to a single waiter. Safe to finish from a detached task.
private final class MutationOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let result = self.result {
                self.lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        if self.result == nil { self.result = result }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Opens once. Waiting after `open` returns immediately.
private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.opened {
                self.lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
