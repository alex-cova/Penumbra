import Foundation

/// What a run printed, kept as the chunks it arrived in so a half-written line (a prompt waiting for
/// input) can be shown. `IDERunConsoleView` draws it incrementally by chunk number, the same way
/// the Gradle console follows its lines.
struct IDERunConsoleLog {
    enum Stream: Equatable, Sendable {
        case stdout
        case stderr
        /// A line the user typed into the console.
        case input
        /// A status line the IDE wrote (`Process finished with exit code 0`).
        case note
    }

    struct Segment: Equatable, Sendable {
        let text: String
        let stream: Stream
    }

    /// Oldest chunks go past this many characters, so a program that prints without end cannot grow
    /// the console without bound.
    static let maxCharacters = 4_000_000

    private(set) var segments: [Segment] = []
    /// How many chunks were dropped from the front. Chunk `i` of ``segments`` is number
    /// `droppedCount + i`, which is what a view follows: a position shifts when old chunks go, a number never does.
    private(set) var droppedCount = 0
    private(set) var characterCount = 0
    /// Changes when the log is cleared, so a view replaces its text instead of appending.
    private(set) var generation = UUID()

    var totalCount: Int { droppedCount + segments.count }
    var isEmpty: Bool { segments.isEmpty }

    var plainText: String { segments.map(\.text).joined() }

    mutating func append(_ text: String, stream: Stream) {
        guard !text.isEmpty else { return }
        segments.append(Segment(text: text, stream: stream))
        characterCount += text.utf16.count
        guard characterCount > Self.maxCharacters else { return }
        var overflow = 0
        var removed = 0
        // Keep at least the newest chunk, however large.
        while characterCount - removed > Self.maxCharacters, overflow < segments.count - 1 {
            removed += segments[overflow].text.utf16.count
            overflow += 1
        }
        segments.removeFirst(overflow)
        droppedCount += overflow
        characterCount -= removed
    }

    mutating func clear() {
        segments = []
        droppedCount = 0
        characterCount = 0
        generation = UUID()
    }
}
