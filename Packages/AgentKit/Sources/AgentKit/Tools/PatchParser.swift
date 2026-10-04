import Foundation

public enum PatchLine: Sendable, Equatable {
    case context(String)
    case removed(String)
    case added(String)

    var text: String {
        switch self {
        case .context(let text), .removed(let text), .added(let text): text
        }
    }
}

public struct PatchHunk: Sendable, Equatable {
    /// 1-based, for error messages.
    public let number: Int
    public let header: String
    /// 1-based line in the old file where the hunk says it starts (a hint: matching is by content).
    public let oldStart: Int
    public let lines: [PatchLine]
    /// `\ No newline at end of file` followed an old-side / new-side line of this hunk.
    public let oldMissingEOL: Bool
    public let newMissingEOL: Bool

    public var oldLines: [String] {
        lines.compactMap { line in
            switch line {
            case .context(let text), .removed(let text): text
            case .added: nil
            }
        }
    }

    public var newLines: [String] {
        lines.compactMap { line in
            switch line {
            case .context(let text), .added(let text): text
            case .removed: nil
            }
        }
    }

    public var addedCount: Int { lines.filter { if case .added = $0 { true } else { false } }.count }
    public var removedCount: Int { lines.filter { if case .removed = $0 { true } else { false } }.count }
}

public struct FilePatch: Sendable, Equatable {
    public let path: String
    public let isCreation: Bool
    public let isDeletion: Bool
    public let hunks: [PatchHunk]
}

public struct PatchError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A strict reader for unified diffs, as models write them. Structure must be right (headers, hunk
/// markers, a prefix on every line); the line numbers and counts in `@@` headers need not be, since
/// models miscount, and hunks are located by their content instead.
public enum PatchParser {
    public static func parse(_ patch: String) throws -> [FilePatch] {
        var lines = patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { throw PatchError("The patch is empty.") }

        var result: [FilePatch] = []
        var index = 0
        while index < lines.count {
            guard isFileHeader(lines, index) else {
                // `diff --git`, `index`, `new file mode`, blank lines and prose before a header.
                index += 1
                continue
            }
            let (file, next) = try parseFile(lines, from: index)
            result.append(file)
            index = next
        }
        guard !result.isEmpty else {
            throw PatchError("No file was found in the patch. Each file needs `--- a/path` and `+++ b/path` lines followed by `@@` hunks.")
        }
        var seen = Set<String>()
        for file in result where !seen.insert(file.path).inserted {
            throw PatchError("\(file.path) appears twice in the patch. Put all of a file's hunks under one header.")
        }
        return result
    }

    // MARK: - Files

    private static func isFileHeader(_ lines: [String], _ index: Int) -> Bool {
        index + 1 < lines.count && lines[index].hasPrefix("--- ") && lines[index + 1].hasPrefix("+++ ")
    }

    private static func parseFile(_ lines: [String], from start: Int) throws -> (FilePatch, Int) {
        let oldPath = cleanPath(String(lines[start].dropFirst(4)))
        let newPath = cleanPath(String(lines[start + 1].dropFirst(4)))
        let isCreation = oldPath == "/dev/null"
        let isDeletion = newPath == "/dev/null"
        let path = stripPrefix(isDeletion ? oldPath : newPath, other: isDeletion ? newPath : oldPath)
        guard !path.isEmpty else { throw PatchError("The file header at patch line \(start + 1) has no path.") }

        var hunks: [PatchHunk] = []
        var index = start + 2
        while index < lines.count, !isFileHeader(lines, index), !lines[index].hasPrefix("diff --git") {
            guard lines[index].hasPrefix("@@") else {
                if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
                throw PatchError("Expected a hunk header (`@@ -a,b +c,d @@`) at patch line \(index + 1) but found: \(preview(lines[index]))")
            }
            let (hunk, next) = try parseHunk(lines, from: index, number: hunks.count + 1, path: path)
            hunks.append(hunk)
            index = next
        }
        guard !hunks.isEmpty || isDeletion else { throw PatchError("\(path) has a header but no `@@` hunk.") }
        return (FilePatch(path: path, isCreation: isCreation, isDeletion: isDeletion, hunks: hunks), index)
    }

    // MARK: - Hunks

    private static func parseHunk(_ lines: [String], from start: Int, number: Int, path: String) throws -> (PatchHunk, Int) {
        let header = lines[start]
        guard let match = header.firstMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) else {
            throw PatchError("Hunk \(number) of \(path): the header is not understood: \(preview(header)). Use `@@ -oldStart,oldCount +newStart,newCount @@`.")
        }
        let oldStart = Int(match.1) ?? 1
        let declaredOld = match.2.flatMap { Int($0) }

        var body: [PatchLine] = []
        var oldMissingEOL = false
        var newMissingEOL = false
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@") || isFileHeader(lines, index) || line.hasPrefix("diff --git") { break }
            if line.hasPrefix("\\") {
                // `\ No newline at end of file` refers to the line just above it.
                switch body.last {
                case .removed?: oldMissingEOL = true
                case .added?: newMissingEOL = true
                case .context?: oldMissingEOL = true; newMissingEOL = true
                case nil: throw PatchError("Hunk \(number) of \(path): a `\\` marker at patch line \(index + 1) has no line above it.")
                }
                index += 1
                continue
            }
            switch line.first {
            case " "?: body.append(.context(String(line.dropFirst())))
            case "-"?: body.append(.removed(String(line.dropFirst())))
            case "+"?: body.append(.added(String(line.dropFirst())))
            // Models drop the single space of a blank context line.
            case nil: body.append(.context(""))
            default:
                throw PatchError("Hunk \(number) of \(path): patch line \(index + 1) must start with a space, `-` or `+`: \(preview(line))")
            }
            index += 1
        }

        // Blank lines that only separate this hunk from the next file are not context: drop them
        // while the old side is longer than the header says.
        while case .context("")? = body.last, let declaredOld, body.filter({ if case .added = $0 { false } else { true } }).count > declaredOld {
            body.removeLast()
        }
        guard body.contains(where: { if case .context = $0 { false } else { true } }) else {
            throw PatchError("Hunk \(number) of \(path) changes nothing: it has no `-` or `+` lines.")
        }
        return (PatchHunk(
            number: number, header: header, oldStart: oldStart, lines: body,
            oldMissingEOL: oldMissingEOL, newMissingEOL: newMissingEOL), index)
    }

    // MARK: - Helpers

    private static func cleanPath(_ raw: String) -> String {
        var path = raw
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }  // `path<TAB>timestamp`
        path = path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        return path
    }

    /// `a/` and `b/` are git's markers, not directories; drop them when either side carries one.
    private static func stripPrefix(_ path: String, other: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/"), other.hasPrefix("a/") || other.hasPrefix("b/") || other == "/dev/null" {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func preview(_ line: String) -> String {
        let shown = line.count > 80 ? String(line.prefix(80)) + "…" : line
        return "`\(shown)`"
    }
}
