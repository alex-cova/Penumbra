import Foundation

/// A bounded wait for work the session does not control (a host callback, a process).
enum Deadline {
    /// Runs `body` on its own task, so the caller being cancelled does not cancel it, and returns
    /// `nil` once `seconds` have passed even if `body` ignores cancellation.
    static func run<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeOnce(continuation)
            gate.tasks = [
                Task.detached { gate.resume(await body()) },
                Task.detached {
                    try? await Task.sleep(for: .seconds(seconds))
                    gate.resume(nil)
                },
            ]
        }
    }
}

/// Resumes a continuation once, from whichever of two tasks gets there first, and cancels both.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var cancelled: [Task<Void, Never>] = []
    var tasks: [Task<Void, Never>] {
        get { lock.withLock { cancelled } }
        set {
            let finished = lock.withLock { () -> Bool in
                cancelled = newValue
                return continuation == nil
            }
            if finished { newValue.forEach { $0.cancel() } }
        }
    }

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        let (taken, toCancel) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            defer { continuation = nil }
            return (continuation, cancelled)
        }
        toCancel.forEach { $0.cancel() }
        taken?.resume(returning: value)
    }
}
