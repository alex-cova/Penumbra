import Foundation
import Observation

/// What a debug session printed: the program's stdout and stderr, and notes this app wrote
/// ("Launching…", "Process finished with exit code 0"). Shown by `IDEDebugConsoleView`.
///
/// The log is a list of chunks, each some text and whether it ends its line. A program that prints
/// a prompt without a newline arrives as an open chunk that the next chunk of the same stream
/// continues, so a view only ever appends. When another stream writes while a line is open, that
/// line is closed first, so output from the two streams never shares a line.
///
/// Bounded: once it holds more than ``maxChunks`` (plus a little slack, so trimming is not done on
/// every append) the oldest are dropped and counted in ``droppedCount``.
@MainActor
@Observable
final class IDEDebugConsoleLog {
    enum Stream: Sendable {
        case out
        case err
        case note
        /// A breakpoint's log message or log expression.
        case log
    }

    struct Chunk: Sendable, Equatable {
        /// Counts up from zero for the whole run, so `chunks[i].sequence == droppedCount + i`.
        let sequence: Int
        let stream: Stream
        let text: String
        let endsLine: Bool
    }

    static let maxChunks = 10_000
    static let trimSlack = 500

    private(set) var chunks: [Chunk] = []
    /// How many of the oldest chunks were dropped because of ``maxChunks``.
    private(set) var droppedCount = 0
    /// Changes on ``reset()``, so a view replaces its whole text instead of appending to another run's.
    private(set) var runID = UUID()
    /// Bumped by every change; the Console picker compares it with ``readRevision`` for its unread dot.
    private(set) var revision = 0
    private(set) var readRevision = 0

    @ObservationIgnored private var nextSequence = 0
    @ObservationIgnored private var openStream: Stream?

    var isEmpty: Bool { chunks.isEmpty }
    var hasUnread: Bool { revision != readRevision }

    func markRead() {
        if readRevision != revision { readRevision = revision }
    }

    /// Starts a new run: the previous output is gone.
    func reset() {
        chunks = []
        droppedCount = 0
        nextSequence = 0
        openStream = nil
        runID = UUID()
        revision = 0
        readRevision = 0
    }

    /// Adds program output. `partial` means the line has no terminator yet; the next call for the
    /// same stream continues it.
    func append(stream: Stream, text: String, partial: Bool) {
        if let open = openStream, open != stream {
            add(open, "", endsLine: true)
            openStream = nil
        }
        add(stream, text, endsLine: !partial)
        openStream = partial ? stream : nil
        trimIfNeeded()
        revision += 1
    }

    func appendNote(_ text: String) {
        if let open = openStream {
            add(open, "", endsLine: true)
            openStream = nil
        }
        add(.note, text, endsLine: true)
        trimIfNeeded()
        revision += 1
    }

    private func add(_ stream: Stream, _ text: String, endsLine: Bool) {
        chunks.append(Chunk(sequence: nextSequence, stream: stream, text: text, endsLine: endsLine))
        nextSequence += 1
    }

    private func trimIfNeeded() {
        guard chunks.count > Self.maxChunks + Self.trimSlack else { return }
        let overflow = chunks.count - Self.maxChunks
        chunks.removeFirst(overflow)
        droppedCount += overflow
    }
}
