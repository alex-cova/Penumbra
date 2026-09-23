import Foundation
import JavaIntelligence

/// The accumulated output of the most recent Gradle sync, rendered live by `IDEGradleConsoleView`
/// as it arrives. Owned by `IDEJavaSupport`; reset at the start of each sync so switching projects
/// or reloading never mixes two runs' output together.
struct IDEGradleConsoleLog {
    /// One rendered line: either real process output (`process`) or a status line this app itself
    /// wrote (`note`, e.g. "Sync finished") -- `IDEGradleConsoleView` colors them differently.
    enum Line {
        case process(GradleOutputLine)
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
    /// Changes every time `reset()` runs. `IDEGradleConsoleView` replaces its whole text buffer
    /// when this changes and otherwise only appends, so a stale view never mixes two runs.
    private(set) var runID = UUID()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

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

    mutating func appendProcessLine(_ line: GradleOutputLine) {
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
