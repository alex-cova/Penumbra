import Foundation

/// A set of text edits across several files, plus file renames, produced by a refactoring
/// (rename, move, organize imports project-wide). Editor-agnostic: the host decides how each file
/// is edited (a live text view, or the file on disk).
///
/// Edits inside one file address the *original* text of that file and must not overlap; hosts
/// apply them from the end of the file to the start (see ``orderedEdits(for:)``).
public struct WorkspaceEdit: Sendable {
    public var changes: [URL: [TextEdit]]
    /// File renames to perform after the text edits, in order. Edits address the old URLs.
    public var fileRenames: [(from: URL, to: URL)]
    /// Non-fatal notes for the user (name conflicts, skipped read-only files).
    public var warnings: [String]

    public init(
        changes: [URL: [TextEdit]] = [:],
        fileRenames: [(from: URL, to: URL)] = [],
        warnings: [String] = []
    ) {
        self.changes = changes
        self.fileRenames = fileRenames
        self.warnings = warnings
    }

    public var isEmpty: Bool {
        fileRenames.isEmpty && changes.values.allSatisfy(\.isEmpty)
    }

    public var editCount: Int {
        changes.values.reduce(0) { $0 + $1.count }
    }

    /// Files with at least one edit, sorted by path.
    public var affectedURLs: [URL] {
        changes.filter { !$0.value.isEmpty }.keys.sorted { $0.path < $1.path }
    }

    /// The edits for `url` sorted from the end of the file to the start, the order in which they
    /// can be applied one by one without shifting the ones still to come. Edits at the same start
    /// keep their reverse relative order.
    public func orderedEdits(for url: URL) -> [TextEdit] {
        let indexed = (changes[url] ?? []).enumerated()
        return indexed.sorted { lhs, rhs in
            let l = Self.sortKey(lhs.element.range.start)
            let r = Self.sortKey(rhs.element.range.start)
            if l != r { return l.lexicographicallyPrecedes(r) == false }
            return lhs.offset > rhs.offset
        }.map(\.element)
    }

    /// A problem that makes a workspace edit unsafe to apply.
    public enum Issue: Equatable, Sendable {
        case overlappingEdits(url: URL, first: TextRange, second: TextRange)
        case invalidRange(url: URL, range: TextRange)
        case duplicateFileRenameSource(URL)
        case duplicateFileRenameTarget(URL)
    }

    /// Checks that no two edits in a file overlap, no range is inverted, and file renames don't
    /// collide. An empty result means the edit is safe to apply.
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        for url in affectedURLs {
            let edits = (changes[url] ?? []).sorted {
                Self.sortKey($0.range.start).lexicographicallyPrecedes(Self.sortKey($1.range.start))
            }
            var previous: TextEdit?
            for edit in edits {
                if Self.sortKey(edit.range.end).lexicographicallyPrecedes(Self.sortKey(edit.range.start)) {
                    issues.append(.invalidRange(url: url, range: edit.range))
                    continue
                }
                if let previous,
                   Self.sortKey(edit.range.start).lexicographicallyPrecedes(Self.sortKey(previous.range.end)) {
                    issues.append(.overlappingEdits(url: url, first: previous.range, second: edit.range))
                }
                previous = edit
            }
        }
        var sources = Set<URL>()
        var targets = Set<URL>()
        for rename in fileRenames {
            if !sources.insert(rename.from.standardizedFileURL).inserted {
                issues.append(.duplicateFileRenameSource(rename.from))
            }
            if !targets.insert(rename.to.standardizedFileURL).inserted {
                issues.append(.duplicateFileRenameTarget(rename.to))
            }
        }
        return issues
    }

    private static func sortKey(_ position: TextPosition) -> [Int] {
        [position.line, position.column]
    }

    // MARK: - Applying to a string

    public enum ApplyError: Error, Equatable, LocalizedError, Sendable {
        case rangeOutOfBounds
        case overlappingEdits

        public var errorDescription: String? {
            switch self {
            case .rangeOutOfBounds: return "An edit points outside the file; it changed since the rename was planned."
            case .overlappingEdits: return "Two edits overlap."
            }
        }
    }

    /// Applies `edits` (addressing `text` by line and column, UTF-16 columns) and returns the new
    /// text. For hosts that edit a file that isn't open in an editor.
    public static func apply(_ edits: [TextEdit], to text: String) throws -> String {
        let ns = text as NSString
        let lineStarts = lineStartOffsets(in: ns)
        func offset(_ position: TextPosition) throws -> Int {
            guard position.line >= 0, position.line < lineStarts.count, position.column >= 0 else {
                throw ApplyError.rangeOutOfBounds
            }
            let lineEnd = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] : ns.length
            let value = lineStarts[position.line] + position.column
            guard value <= lineEnd else { throw ApplyError.rangeOutOfBounds }
            return value
        }
        var resolved: [(range: NSRange, replacement: String, index: Int)] = []
        for (index, edit) in edits.enumerated() {
            let start = try offset(edit.range.start)
            let end = try offset(edit.range.end)
            guard end >= start else { throw ApplyError.rangeOutOfBounds }
            resolved.append((NSRange(location: start, length: end - start), edit.replacement, index))
        }
        resolved.sort {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.index < $1.index
        }
        for pair in zip(resolved, resolved.dropFirst()) where pair.1.range.location < NSMaxRange(pair.0.range) {
            throw ApplyError.overlappingEdits
        }
        let result = NSMutableString(string: text)
        for edit in resolved.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    /// UTF-16 offset of the start of every line (`\n`, `\r\n` and lone `\r` end a line).
    static func lineStartOffsets(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        let length = text.length
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x0A {
                starts.append(index + 1)
            } else if unit == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }
}

/// What a host reports after applying a ``WorkspaceEdit``.
public struct WorkspaceEditApplyResult: Sendable {
    public var appliedFiles: [URL]
    public var renamedFiles: [(from: URL, to: URL)]
    public var failures: [URL: String]

    public init(
        appliedFiles: [URL] = [],
        renamedFiles: [(from: URL, to: URL)] = [],
        failures: [URL: String] = [:]
    ) {
        self.appliedFiles = appliedFiles
        self.renamedFiles = renamedFiles
        self.failures = failures
    }

    public var isSuccess: Bool { failures.isEmpty }
}
