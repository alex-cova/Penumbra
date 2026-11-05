import Foundation
import Penumbra

/// One pause for everything a window does because typing stopped.
///
/// Semantic colours, gutter markers, the Structure tree, auto-import, the name index and run
/// availability each used to keep a timer and read the buffer on their own. A keystroke now
/// registers them here. They share one trailing delay (an immediate request, such as opening a
/// file, does not wait unless a pause is already pending), one copy of the text, and then run
/// visible work before the rest. A newer
/// keystroke cancels the pause and anything it already started.
///
/// The text is the buffer's shared ``TextView/materializedText(priority:)``. Callers that parse
/// Java of that exact string share ``JavaParseMemo``; this type does not know about languages.
@MainActor
final class DocumentSettleCoordinator {
    /// The buffer as it was when the pause ended.
    struct Snapshot: Sendable {
        let text: String
        let generation: UInt64
        /// UTF-16 offset of the caret when the text was captured.
        let caretUTF16: Int
    }

    /// Visible work (colours, markers, the Structure tree) runs before everything else.
    enum Phase: Int, Comparable {
        case visible = 0
        case language = 1

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Consumer {
        var phase: Phase
        var run: @MainActor (TextView, Snapshot) async -> Void
    }

    private struct Batch {
        var delay: Duration
        /// Registration order. Replacing an id keeps its place.
        var consumers: [(id: String, consumer: Consumer)] = []
    }

    private var batches: [ObjectIdentifier: Batch] = [:]
    private let timers = KeyedDebouncer<ObjectIdentifier>()
    /// Settles that captured the buffer text. A burst of keystrokes is one, after the pause.
    private(set) var snapshotCount = 0

    /// Register `work` for `textView`'s next settle. The same `id` replaces its previous work
    /// instead of running twice. `delay` is how long typing must stay quiet. `.zero` runs
    /// immediately when nothing is waiting; if a pause is already pending, this work joins it.
    func schedule(
        textView: TextView,
        id: String,
        phase: Phase,
        after delay: Duration,
        _ work: @escaping @MainActor (TextView, Snapshot) async -> Void
    ) {
        let key = ObjectIdentifier(textView)
        var batch = batches[key] ?? Batch(delay: delay)
        let consumer = Consumer(phase: phase, run: work)
        if let index = batch.consumers.firstIndex(where: { $0.id == id }) {
            batch.consumers[index] = (id, consumer)
        } else {
            batch.consumers.append((id, consumer))
        }
        // A pause-delay request restarts the wait. An immediate request starts a settle only
        // when nothing is waiting; if a pause is already pending it joins that pause and leaves
        // the timer alone, so a preference refresh cannot flush a caret move's rebuild early.
        let restart = delay > .zero || batches[key] == nil
        if restart {
            batch.delay = delay
        }
        batches[key] = batch
        guard restart else { return }
        timers.schedule(key, after: batch.delay) { [weak self, weak textView] in
            await self?.fire(key, textView: textView)
        }
    }

    /// Drop one consumer. The pause is cancelled when it was the last one.
    func cancel(_ id: String, for textView: TextView) {
        let key = ObjectIdentifier(textView)
        guard var batch = batches[key] else { return }
        batch.consumers.removeAll { $0.id == id }
        if batch.consumers.isEmpty {
            batches[key] = nil
            timers.cancel(key)
        } else {
            batches[key] = batch
        }
    }

    func cancelAll() {
        batches.removeAll()
        timers.cancelAll()
    }

    private func fire(_ key: ObjectIdentifier, textView: TextView?) async {
        guard let batch = batches.removeValue(forKey: key), let textView else { return }
        guard let materialized = await textView.snapshotText() else { return }
        guard !Task.isCancelled, textView.contentGeneration == materialized.generation else { return }
        snapshotCount += 1
        let snapshot = Snapshot(
            text: materialized.text,
            generation: materialized.generation,
            caretUTF16: textView.selectedRange.location
        )
        let ordered = batch.consumers.map(\.consumer).sorted { $0.phase < $1.phase }
        for consumer in ordered {
            guard !Task.isCancelled, textView.contentGeneration == snapshot.generation else { return }
            await consumer.run(textView, snapshot)
        }
    }
}
