import Foundation

/// One hunk of a zero-context patch, as the diff viewer writes it: `@@ -a,b +c,d @@` and the
/// `-`/`+` lines, with git's "\ No newline at end of file" marker after a line that has none.
struct GitZeroContextHunk: Equatable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// Lines with their line break, exactly as the patch carries them (a `\r` stays).
    var removed: [Data]
    var added: [Data]
    /// The patch deletes the file (`deleted file mode` or `+++ /dev/null`).
    var deletesFile: Bool

    /// Nil unless `patch` holds exactly one well-formed hunk.
    static func parse(_ patch: String) -> GitZeroContextHunk? {
        var header: (Int, Int, Int, Int)?
        var deletes = false
        var removed: [Data] = []
        var added: [Data] = []
        var lastWasRemoved: Bool?
        for line in GitRepository.splitLines(Data(patch.utf8)) {
            guard header != nil else {
                let value = String(decoding: line, as: UTF8.self)
                if value.hasPrefix("deleted file mode") || value.hasPrefix("+++ /dev/null") { deletes = true }
                if value.hasPrefix("@@ ") {
                    guard let parsed = parseHeader(value) else { return nil }
                    header = parsed
                }
                continue
            }
            switch line.first {
            case UInt8(ascii: "-"):
                removed.append(Data(line.dropFirst()))
                lastWasRemoved = true
            case UInt8(ascii: "+"):
                added.append(Data(line.dropFirst()))
                lastWasRemoved = false
            case UInt8(ascii: "\\"):
                // "\ No newline at end of file" belongs to the line just before it.
                switch lastWasRemoved {
                case true: if let tail = removed.popLast() { removed.append(tail.last == 0x0A ? Data(tail.dropLast()) : tail) }
                case false: if let tail = added.popLast() { added.append(tail.last == 0x0A ? Data(tail.dropLast()) : tail) }
                case nil: return nil
                }
            default:
                return nil
            }
        }
        guard let header, removed.count == header.1, added.count == header.3 else { return nil }
        return GitZeroContextHunk(
            oldStart: header.0, oldCount: header.1, newStart: header.2, newCount: header.3,
            removed: removed, added: added, deletesFile: deletes
        )
    }

    private static func parseHeader(_ line: String) -> (Int, Int, Int, Int)? {
        // @@ -2,1 +2,1 @@ (the count is optional in git's own output, and 1 then)
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let pieces = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(pieces[0]) else { return nil }
            if pieces.count == 1 { return (start, 1) }
            guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}

extension GitRepository {
    /// Applies `request` to the index when `:path` is still `baseBlobID`, by writing a new blob:
    /// the blob `baseBlobID` names, with the hunk's lines swapped, hashed as `hash-object --path`
    /// would hash the file (so `eol`, `autocrlf` and clean filters apply, and a CRLF working-tree
    /// line reaches an LF index as LF) and put back with `update-index`, whatever the file's name.
    /// Does not read the work tree and does not write it. A changed index is refused first, and
    /// again under the same blob id before the entry is replaced.
    public func applyHunk(_ request: GitHunkApply) async throws {
        let path = request.relativePath
        guard !path.isEmpty, let hunk = GitZeroContextHunk.parse(request.patch) else {
            throw GitError.invalidRequest("This change cannot be staged as a hunk. Stage the whole file instead.")
        }
        let entry = try await indexEntry(path)
        guard entry?.blobID == request.baseBlobID else {
            throw GitError.invalidRequest("The index changed after this hunk was read. Refresh the diff and try again.")
        }
        var base = Data()
        if let entry { base = try await readOnly(["cat-file", "blob", entry.blobID]).stdout }

        if hunk.deletesFile, !request.reverse {
            guard entry != nil else { throw GitError.invalidRequest("The index no longer has this file.") }
            _ = try await mutate(["update-index", "--force-remove", "-z", "--stdin"], stdin: Data(path.utf8) + Data([0]))
            return
        }
        let replacedCount = request.reverse ? hunk.newCount : hunk.oldCount
        let replacedStart = request.reverse ? hunk.newStart : hunk.oldStart
        let expected = request.reverse ? hunk.added : hunk.removed
        let replacement = request.reverse ? hunk.removed : hunk.added

        var lines = Self.splitLines(base)
        let first = replacedCount == 0 ? replacedStart : replacedStart - 1
        guard first >= 0, first + replacedCount <= lines.count else {
            throw GitError.invalidRequest("This hunk does not fit the index. Refresh the diff and try again.")
        }
        // The lines the hunk says it replaces must be what the index holds there.
        for (offset, line) in expected.enumerated() where lines[first + offset] != line {
            throw GitError.invalidRequest("This hunk does not match the index. Refresh the diff and try again.")
        }
        if replacedCount == 0, first > 0, !(replacement.isEmpty), lines[first - 1].last != 0x0A {
            throw GitError.invalidRequest("This hunk does not fit the index. Refresh the diff and try again.")
        }
        lines.replaceSubrange(first..<(first + replacedCount), with: replacement)
        let contents = lines.reduce(into: Data()) { $0.append($1) }

        let hashed = try await mutate(["hash-object", "-w", "--path=\(path)", "--stdin"], stdin: contents)
        let newID = hashed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newID.count >= 40 else { throw GitError.invalidRequest("git did not return a blob id.") }
        // Re-check just before replacing: the lane serializes Umbra's own writes, not a terminal's.
        guard await indexEntry(path, ignoringErrors: true)?.blobID == request.baseBlobID else {
            throw GitError.invalidRequest("The index changed after this hunk was read. Refresh the diff and try again.")
        }
        let mode = entry?.mode ?? (FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(path).path) ? "100755" : "100644")
        var info = Data("\(mode) \(newID)\t".utf8)
        info.append(Data(path.utf8))
        info.append(0)
        _ = try await mutate(["update-index", "-z", "--index-info"], stdin: info)
    }

    struct IndexEntry: Equatable {
        var mode: String
        var blobID: String
    }

    /// `git ls-files -s -z` for one path. Nil when the index has no such file; throws for an
    /// unmerged path, which has no single blob to replace.
    func indexEntry(_ path: String) async throws -> IndexEntry? {
        let out = try await readOnly(["--literal-pathspecs", "ls-files", "-s", "-z", "--", path])
        let records = out.text.split(separator: "\0", omittingEmptySubsequences: true)
        guard !records.isEmpty else { return nil }
        guard records.count == 1 else { throw GitError.invalidRequest("This file has unresolved merge conflicts.") }
        // "<mode> <object> <stage>\t<path>"
        let fields = records[0].split(separator: "\t", maxSplits: 1)[0].split(separator: " ")
        guard fields.count == 3, fields[2] == "0" else { throw GitError.invalidRequest("This file has unresolved merge conflicts.") }
        return IndexEntry(mode: String(fields[0]), blobID: String(fields[1]))
    }

    private func indexEntry(_ path: String, ignoringErrors: Bool) async -> IndexEntry? {
        try? await indexEntry(path)
    }

    /// Splits at `\n` only, keeping each line's own break: a bare `\r` is not a line break to git.
    static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            lines.append(data[start...index])
            start = data.index(after: index)
        }
        if start < data.endIndex { lines.append(data[start...]) }
        return lines.map { Data($0) }
    }
}
