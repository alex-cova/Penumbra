import EditorIntelligence
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
    private let timer: DebounceTimer

    /// `timer` is the machine's clock; a test passes a manual one to decide when a pause is over.
    init(timer: DebounceTimer = .system) {
        self.timer = timer
    }

    var isPending: Bool { task != nil }

    func schedule(after delay: Duration = .zero, _ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let identity = UUID()
        pendingIdentity = identity
        let timer = self.timer
        task = Task { [weak self] in
            if delay > .zero {
                let parts = delay.components
                try? await timer.sleep(TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
            }
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
    private let timer: DebounceTimer

    init(timer: DebounceTimer = .system) {
        self.timer = timer
    }

    func isPending(_ key: Key) -> Bool { debouncers[key]?.isPending ?? false }

    func schedule(_ key: Key, after delay: Duration = .zero, _ work: @escaping @MainActor () async -> Void) {
        let debouncer = debouncers[key] ?? Debouncer(timer: timer)
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
