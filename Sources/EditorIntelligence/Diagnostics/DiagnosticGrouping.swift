import Foundation

/// One diagnostic in a problems list, with an identity that survives refreshes (unlike
/// ``Diagnostic/id``, which is a new `UUID` on every provider run).
public struct ProblemRow: Sendable, Hashable, Identifiable {
    public let url: URL
    public let diagnostic: Diagnostic

    public init(url: URL, diagnostic: Diagnostic) {
        self.url = url
        self.diagnostic = diagnostic
    }

    public var id: String {
        let range = diagnostic.range
        return "\(url.path)|\(range.start.line):\(range.start.column)-\(range.end.line):\(range.end.column)|\(diagnostic.severity)|\(diagnostic.message)"
    }
}

/// Diagnostics for one file, ready for a Problems panel.
public struct ProblemFile: Sendable, Hashable, Identifiable {
    public let url: URL
    public let rows: [ProblemRow]

    public var id: URL { url }

    public var errorCount: Int { rows.filter { $0.diagnostic.severity == .error }.count }
    public var warningCount: Int { rows.filter { $0.diagnostic.severity == .warning }.count }
}

/// Pure grouping/sorting for a Problems list, kept out of the UI layer so it is testable.
public enum DiagnosticGrouping {
    /// Merges per-file diagnostic sets (for example editor-provided and compiler-provided),
    /// drops duplicates (same severity, message and position), applies `severities`, and sorts
    /// files by path and rows by severity then position. Files left with no rows are omitted.
    public static func files(
        from sets: [[URL: [Diagnostic]]],
        severities: Set<DiagnosticSeverity> = [.error, .warning, .information, .hint]
    ) -> [ProblemFile] {
        var merged: [URL: [Diagnostic]] = [:]
        for set in sets {
            for (url, diagnostics) in set {
                merged[url, default: []].append(contentsOf: diagnostics)
            }
        }
        var files: [ProblemFile] = []
        for (url, diagnostics) in merged {
            var seen = Set<String>()
            var rows: [ProblemRow] = []
            for diagnostic in diagnostics where severities.contains(diagnostic.severity) {
                let row = ProblemRow(url: url, diagnostic: diagnostic)
                guard seen.insert(row.id).inserted else { continue }
                rows.append(row)
            }
            guard !rows.isEmpty else { continue }
            rows.sort { lhs, rhs in
                let l = lhs.diagnostic, r = rhs.diagnostic
                if l.severity != r.severity { return l.severity < r.severity }
                if l.range.start.line != r.range.start.line { return l.range.start.line < r.range.start.line }
                return l.range.start.column < r.range.start.column
            }
            files.append(ProblemFile(url: url, rows: rows))
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    public static func counts(in files: [ProblemFile]) -> (errors: Int, warnings: Int) {
        (files.reduce(0) { $0 + $1.errorCount }, files.reduce(0) { $0 + $1.warningCount })
    }
}

/// Resolves a diagnostic's line/column range to a UTF-16 `NSRange` against actual text. A
/// provider's `utf16Offset` is not always absolute (LSP conversion stores the column there), so
/// anything that navigates to a diagnostic should go through the line and column instead.
public enum ProblemLocator {
    /// Lines are 0-based and terminated by `\n`, `\r\n` or `\r`; columns are UTF-16 code units from
    /// the line start. Out-of-range positions clamp to the end of their line, or of the text.
    public static func nsRange(for range: TextRange, in text: String) -> NSRange {
        let start = offset(of: range.start, in: text)
        let end = max(start, offset(of: range.end, in: text))
        return NSRange(location: start, length: end - start)
    }

    private static func offset(of position: TextPosition, in text: String) -> Int {
        let utf16 = Array(text.utf16)
        var lineStart = 0
        var line = 0
        var index = 0
        while line < position.line, index < utf16.count {
            let unit = utf16[index]
            index += 1
            if unit == 0x0A || (unit == 0x0D && !(index < utf16.count && utf16[index] == 0x0A)) {
                line += 1
                lineStart = index
            }
        }
        guard line == position.line else { return utf16.count }
        var lineEnd = lineStart
        while lineEnd < utf16.count, utf16[lineEnd] != 0x0A, utf16[lineEnd] != 0x0D {
            lineEnd += 1
        }
        return min(lineStart + max(0, position.column), lineEnd)
    }
}
