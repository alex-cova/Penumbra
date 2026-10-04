import Foundation

/// A value behind a lock, with `Mutex`'s call shape. `Synchronization.Mutex` needs macOS 15; this
/// package supports macOS 14 like the rest of the repository.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
