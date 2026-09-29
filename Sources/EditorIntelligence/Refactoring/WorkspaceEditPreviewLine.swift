import Foundation

/// A changed line split around the edit, for a before/after preview. `before + removed + after`
/// is the old line and `before + added + after` the new one, each cut to a window around the edit.
public struct WorkspaceEditPreviewLine: Sendable, Equatable {
    public let before: String
    public let removed: String
    public let added: String
    public let after: String

    public init(before: String, removed: String, added: String, after: String) {
        self.before = before
        self.removed = removed
        self.added = added
        self.after = after
    }

    public var oldLine: String { before + removed + after }
    public var newLine: String { before + added + after }
}

public extension WorkspaceEditPlanEntry {
    /// What the line becomes, computed from ``lineText``, the entry's columns (UTF-16 units) and
    /// ``newText``, so nothing extra is stored per entry.
    ///
    /// Returns `nil` when the edit spans line breaks, or when the columns do not select
    /// ``oldText`` in ``lineText`` (a provider that counts columns differently): callers then show
    /// the single line as before.
    ///
    /// Tabs come back as four spaces. A line break in the new text shows as `⏎`. Text further than
    /// `window` characters from the edit is cut and replaced by an ellipsis.
    func previewLine(window: Int = 60) -> WorkspaceEditPreviewLine? {
        guard range.start.line == range.end.line else { return nil }
        let line = lineText as NSString
        let start = range.start.column
        let end = range.end.column
        guard start >= 0, end >= start, end <= line.length else { return nil }
        guard line.substring(with: NSRange(location: start, length: end - start)) == oldText else { return nil }

        func display(_ text: String) -> String {
            text.replacingOccurrences(of: "\t", with: "    ")
                .replacingOccurrences(of: "\r\n", with: "⏎")
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\r", with: "")
        }
        var before = display(line.substring(to: start))
        var after = display(line.substring(from: end))
        if before.count > window { before = "…" + before.suffix(window) }
        if after.count > window { after = after.prefix(window) + "…" }
        return WorkspaceEditPreviewLine(before: before, removed: display(oldText), added: display(newText), after: after)
    }
}
