import Foundation

/// One line of a project system's process output, as it arrived.
struct IDEProjectOutputLine: Equatable, Sendable {
    enum Stream: Equatable, Sendable {
        case stdout
        case stderr
    }

    let stream: Stream
    let text: String
}

/// The accumulated output of a project system's most recent sync or task run, rendered live by
/// `IDEProjectConsoleView` as it arrives. Owned by the project system (`IDEProjectSystem.console`);
/// reset at the start of each sync so switching projects or reloading never mixes two runs' output
/// together.
struct IDEProjectConsoleLog {
    /// One rendered line: either real process output (`process`) or a status line this app itself
    /// wrote (`note`, e.g. "Sync finished") -- `IDEProjectConsoleView` colors them differently.
    enum Line {
        case process(IDEProjectOutputLine)
        case note(String)

        var text: String {
            switch self {
            case .process(let line): line.text
            case .note(let text): text
            }
        }
    }

    /// Oldest lines are dropped past this many, so an unbounded dependency-download spew (or a
    /// long-lived Umbra session that reloads many times) can't grow this without bound. Far more
    /// than any interactive sync needs to be legible; only a pathological build would ever hit it.
    static let maxLines = 10_000

    private(set) var lines: [Line] = []
    /// How many lines were dropped from the front because `maxLines` was exceeded, shown as a
    /// one-line notice at the top of the console instead of silently losing context.
    private(set) var droppedCount = 0
    /// Changes every time `reset()` runs. `IDEProjectConsoleView` replaces its whole text buffer
    /// when this changes and otherwise only appends, so a stale view never mixes two runs.
    private(set) var runID = UUID()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    /// Every line this run has produced, dropped ones included. Line `i` of ``lines`` is number
    /// `droppedCount + i`, which is what a view follows: a position in ``lines`` shifts whenever
    /// old lines are dropped, a number never does.
    var totalLineCount: Int { droppedCount + lines.count }

    var latestLine: String? {
        lines.last?.text
    }

    mutating func reset() {
        lines = []
        droppedCount = 0
        runID = UUID()
        startedAt = Date()
        finishedAt = nil
    }

    mutating func appendNote(_ text: String) {
        append(.note(text))
    }

    mutating func appendProcessLine(_ line: IDEProjectOutputLine) {
        append(.process(line))
    }

    mutating func markFinished() {
        finishedAt = Date()
    }

    private mutating func append(_ line: Line) {
        lines.append(line)
        guard lines.count > Self.maxLines else { return }
        let overflow = lines.count - Self.maxLines
        lines.removeFirst(overflow)
        droppedCount += overflow
    }
}
