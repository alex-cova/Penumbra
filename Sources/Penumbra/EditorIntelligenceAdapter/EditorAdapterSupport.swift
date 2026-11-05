import EditorIntelligence
import Foundation

/// Shared plumbing for the `EditorAdapter` implementations bridged to a `TextView`.
///
/// `PenumbraEditorAdapter` (single document) and `PenumbraWorkbenchEditorAdapter`
/// (workbench scope) previously duplicated two pieces of logic: coalescing bursts of
/// keystrokes into one debounced refresh, and draining incrementally reported `TextEdit`s
/// into either `.documentEdited` or `.documentChanged`. Centralizing that here keeps the
/// "each observed edit is reported exactly once per refresh" invariant in one place.
/// Neither helper adds an async hop or allocation to the typing hot path beyond what the
/// duplicated code already did.
enum EditorAdapterSupport {
    /// Drain `pending` into the event describing `document`'s new snapshot.
    ///
    /// Returns `.documentEdited` when incremental edits were observed since the last
    /// refresh, `.documentChanged` otherwise, and always empties `pending`.
    static func editsEvent(draining pending: inout [TextEdit], for document: Document) -> EditorEvent {
        let edits = pending
        pending = []
        if edits.isEmpty {
            return .documentChanged(document.id, document.contentSnapshot)
        }
        return .documentEdited(document.id, edits, newSnapshot: document.contentSnapshot)
    }
}

/// Coalesces bursts of `TextView` change callbacks into one delayed refresh.
///
/// Replaces the hand-rolled `Task.sleep` + cancel boilerplate previously duplicated in each
/// adapter. Any pending refresh is cancelled on deinit.
///
/// The delay restarts on every call, so a burst refreshes once it ends. A burst that never pauses
/// (a held key repeats every ~33 ms, a macro or a script types without gaps) would starve every
/// consumer of the refresh and let the queue of edits waiting for it grow, so a refresh never
/// waits longer than ``maximumWait(forDelay:)`` after the first call it is owed for.
///
/// Must be used from a single thread (in practice the main thread, where `TextViewDelegate`
/// callbacks arrive), matching the pre-existing unsynchronized task handling.
final class AdapterDebouncer: @unchecked Sendable {
    private var task: Task<Void, Never>?
    /// When the oldest call not yet refreshed was made.
    private var firstPendingAt: ContinuousClock.Instant?

    /// Longest a call waits for a pause: a second, or five delays when the delay is longer.
    static func maximumWait(forDelay delay: TimeInterval) -> TimeInterval {
        max(1, delay * 5)
    }

    /// Cancel any pending refresh and schedule `work` after `delay` seconds, or sooner when the
    /// oldest unrefreshed call has already waited close to ``maximumWait(forDelay:)``.
    ///
    /// `delay` is read by the caller at schedule time, matching the documented
    /// "read when each refresh is scheduled" autoreparse-delay semantics.
    func schedule(delay: TimeInterval, work: @escaping @MainActor () -> Void) {
        task?.cancel()
        let now = ContinuousClock.now
        let first = firstPendingAt ?? now
        firstPendingAt = first
        let elapsed = Self.seconds(first.duration(to: now))
        let remaining = max(0, Self.maximumWait(forDelay: delay) - elapsed)
        let wait = min(max(delay, 0), remaining)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.firstPendingAt = nil
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        firstPendingAt = nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    deinit {
        task?.cancel()
    }
}
