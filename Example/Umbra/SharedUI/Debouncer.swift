import Foundation

/// Runs the latest request once its delay has passed without a newer one. Scheduling again, or
/// `cancel()`, cancels the pending request, and cancels it while it runs: `work` executes inside the
/// task, so `Task.isCancelled` and cooperative cancellation (a `withTaskCancellationHandler`, an
/// `await` that throws) see it.
///
/// This owns timing and cancellation only. Whether a result is still wanted (the text changed
/// meanwhile, the view is gone) is the caller's check, made after its own awaits, as before.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?

    var isPending: Bool { task != nil }

    func schedule(after delay: Duration = .zero, _ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let identity = UUID()
        pendingIdentity = identity
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await work()
            // Only the newest request clears the slot.
            if self?.pendingIdentity == identity { self?.task = nil }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingIdentity = nil
    }

    private var pendingIdentity: UUID?
}

/// One `Debouncer` per key, for work that debounces separately per editor or document.
@MainActor
final class KeyedDebouncer<Key: Hashable> {
    private var debouncers: [Key: Debouncer] = [:]

    func isPending(_ key: Key) -> Bool { debouncers[key]?.isPending ?? false }

    func schedule(_ key: Key, after delay: Duration = .zero, _ work: @escaping @MainActor () async -> Void) {
        let debouncer = debouncers[key] ?? Debouncer()
        debouncers[key] = debouncer
        debouncer.schedule(after: delay, work)
    }

    func cancel(_ key: Key) {
        debouncers.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        for debouncer in debouncers.values { debouncer.cancel() }
        debouncers.removeAll()
    }
}
