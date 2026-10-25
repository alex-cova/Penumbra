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
/// Must be used from a single thread (in practice the main thread, where `TextViewDelegate`
/// callbacks arrive), matching the pre-existing unsynchronized task handling.
final class AdapterDebouncer: @unchecked Sendable {
    private var task: Task<Void, Never>?

    /// Cancel any pending refresh and schedule `work` after `delay` seconds.
    ///
    /// `delay` is read by the caller at schedule time, matching the documented
    /// "read when each refresh is scheduled" autoreparse-delay semantics.
    func schedule(delay: TimeInterval, work: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
