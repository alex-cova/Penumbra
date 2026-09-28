import Foundation

/// Picks the problem "Go to Next / Previous Problem" (F2 / ⇧F2) should land on.
///
/// Problems are walked in one order across files: by file path, then line, then column, wrapping
/// from the last problem to the first (and back). Several problems starting at the same place
/// count as one stop, so repeated presses always advance.
public enum ProblemNavigator {
    /// Where the caret is: the file (nil for an unsaved buffer) and a 0-based line and column.
    public struct Position: Sendable, Equatable {
        public var url: URL?
        public var line: Int
        public var column: Int

        public init(url: URL?, line: Int, column: Int) {
            self.url = url
            self.line = line
            self.column = column
        }
    }

    /// The problem after (or before) `position`, among those whose severity is in `severities`
    /// (errors and warnings by default; hints and information are not worth a keystroke).
    /// `position` nil starts before the first problem going forward, after the last going back.
    /// Returns nil when there is nothing to go to, or the only stop is where the caret already is.
    public static func step(
        from position: Position?,
        forward: Bool,
        in files: [ProblemFile],
        severities: Set<DiagnosticSeverity> = [.error, .warning]
    ) -> ProblemRow? {
        let stops = files
            .flatMap(\.rows)
            .filter { severities.contains($0.diagnostic.severity) }
            .map { Stop(row: $0) }
            .sorted { $0.key < $1.key }
        guard !stops.isEmpty else {
            return nil
        }
        let here = position.map { Key(path: $0.url?.standardizedFileURL.path ?? "", line: $0.line, column: $0.column) }
        let target: Stop?
        if let here {
            target = forward
                ? (stops.first { $0.key > here } ?? stops.first)
                : (stops.last { $0.key < here } ?? stops.last)
        } else {
            target = forward ? stops.first : stops.last
        }
        guard let target, target.key != here else {
            return nil
        }
        return target.row
    }

    private struct Key: Comparable, Equatable {
        let path: String
        let line: Int
        let column: Int

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.column < rhs.column
        }
    }

    private struct Stop {
        let row: ProblemRow
        let key: Key

        init(row: ProblemRow) {
            self.row = row
            key = Key(path: row.url.standardizedFileURL.path,
                      line: row.diagnostic.range.start.line,
                      column: row.diagnostic.range.start.column)
        }
    }
}
