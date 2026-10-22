import Foundation

/// Keeps the full text of tool output that was too large to show the model, so the model can read the
/// part it needs later with `read_tool_output` instead of running the command again. The host decides
/// where and for how long (a folder beside the conversation, a week); AgentKit never touches the disk
/// for this and only asks these two questions.
public protocol ToolOutputStore: Sendable {
    /// Keeps `text` under `id` (see `ToolOutputID`). `false` when it could not be kept: the output is
    /// then cut the way it was before the store existed.
    func save(_ text: String, id: String) -> Bool
    /// What was saved under `id`, or `nil` (never saved, expired, deleted).
    func load(id: String) -> String?
}

public enum ToolOutputID {
    /// A fresh id. Random, not the call's id: some providers reuse call ids across turns, and a reused
    /// id would make an old pointer read the wrong text.
    public static func make() -> String {
        "out_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// Ids are file names in a host's store, and the model writes the one it reads: letters, digits, `_`
    /// and `-` only, so no id can name another path.
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `read_tool_output(id: "out_…", offset: 120)`, the form the model is told to call (and the stubs keep).
    static func pointer(id: String, offset: Int? = nil) -> String {
        "read_tool_output(id: \"\(id)\"" + (offset.map { ", offset: \($0)" } ?? "") + ")"
    }

    /// The id inside a pointer, to carry it into a compaction stub.
    static func id(inPointerIn text: String) -> String? {
        guard let range = text.range(of: #"read_tool_output\(id: "([A-Za-z0-9_-]{1,64})""#, options: .regularExpression) else { return nil }
        let match = text[range]
        guard let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""), open < close else { return nil }
        return String(match[match.index(after: open)..<close])
    }
}

extension OutputTruncation {
    /// `headAndTail`, but the whole text is first saved (scrubbed the way this call's output is) and the
    /// marker in the middle says how to read it: the id, the line the omitted part starts at, and that a
    /// pattern searches it. Without a store, or when saving fails, it is exactly `headAndTail`.
    public static func headAndTailSaving(
        _ text: String, maxCharacters: Int, headShare: Double = 0.3, context: ToolContext
    ) async -> String {
        guard let pieces = cut(text, maxCharacters: maxCharacters, headShare: headShare) else { return text }
        guard let store = context.outputStore else {
            return pieces.head + "\n[… \(pieces.omitted) characters omitted from the middle …]\n" + pieces.tail
        }
        let id = ToolOutputID.make()
        let copy = await context.redactOutput?(text) ?? text
        guard store.save(copy, id: id) else {
            return pieces.head + "\n[… \(pieces.omitted) characters omitted from the middle …]\n" + pieces.tail
        }
        let headLines = pieces.head.split(separator: "\n", omittingEmptySubsequences: false).count
        let marker = "[… \(pieces.omitted) characters omitted from the middle. Full output saved: "
            + "\(ToolOutputID.pointer(id: id, offset: headLines + 1)) pages it, pattern: \"<regex>\" searches it …]"
        return pieces.head + "\n" + marker + "\n" + pieces.tail
    }
}

/// The safety net under every tool: an output no tool bounded itself is saved whole and cut to its
/// first lines. It sits above each built-in tool's own cap, so it only catches what they miss.
enum ToolOutputNet {
    static let maxLines = 2_500
    static let maxBytes = 100 * 1024
    /// When even the first line is over the byte cap, this many characters of it are shown.
    static let maxFirstLineCharacters = 2_000

    /// `text` itself when it is within the limits or cannot be saved.
    static func spill(_ text: String, into store: any ToolOutputStore) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines || text.utf8.count > maxBytes else { return text }
        let id = ToolOutputID.make()
        guard store.save(text, id: id) else { return text }

        var kept: [Substring] = []
        var bytes = 0
        for line in lines {
            let size = line.utf8.count + 1
            guard kept.count < maxLines, bytes + size <= maxBytes else { break }
            kept.append(line)
            bytes += size
        }
        let how = "full output saved: \(ToolOutputID.pointer(id: id, offset: kept.count + 1)) pages it, pattern: \"<regex>\" searches it"
        if kept.isEmpty {
            return String(text.prefix(maxFirstLineCharacters))
                + "\n[showing the first \(maxFirstLineCharacters) characters of \(lines.count) lines; \(how)]"
        }
        return kept.joined(separator: "\n") + "\n[showing lines 1-\(kept.count) of \(lines.count); \(how)]"
    }
}

/// Reads back output that was saved because it was too large to show. Read-only, so plan mode keeps it.
public struct ReadToolOutputTool: AgentTool {
    public static let defaultLimit = 400
    public static let maxLimit = 2_000
    static let maxBytes = 32 * 1024
    static let maxMatches = 200
    static let maxLineLength = 500

    private let store: any ToolOutputStore

    public init(store: any ToolOutputStore) {
        self.store = store
    }

    public var risk: ToolRisk { .read }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read_tool_output",
            description: "Read part of a tool result that was too large to show and was saved. Pass the id from its note: [… full output saved: read_tool_output(id: \"…\") …]. Use offset and limit (lines) to page through it, or pattern (a regular expression) to list only the matching lines with their line numbers. Prefer this to running the command again.",
            parameters: [
                ToolParameter("id", .string, "The id from the note."),
                ToolParameter("offset", .integer, "1-based line to start from. Default 1.", optional: true),
                ToolParameter("limit", .integer, "Maximum number of lines. Default \(Self.defaultLimit).", optional: true),
                ToolParameter("pattern", .string, "A regular expression; returns the matching lines instead of a page.", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let id = try arguments.string("id")
        guard ToolOutputID.isValid(id), let text = store.load(id: id) else {
            throw ToolError("No saved output with id \"\(id)\". It may have expired; run the tool again.")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return "[tool output \(id): empty]" }

        if let pattern = try arguments.optionalString("pattern"), !pattern.isEmpty {
            return try search(lines, pattern: pattern, id: id)
        }
        let offset = max(1, try arguments.optionalInt("offset") ?? 1)
        let limit = min(Self.maxLimit, max(1, try arguments.optionalInt("limit") ?? Self.defaultLimit))
        guard offset <= lines.count else {
            throw ToolError("Saved output \(id) has \(lines.count) lines; offset \(offset) is past the end.")
        }
        var body = ""
        var last = offset - 1
        for number in offset...min(lines.count, offset + limit - 1) {
            let rendered = LineNumbering.line(number, Self.clipped(lines[number - 1])) + "\n"
            // Always return at least one line, however long.
            if !body.isEmpty, body.utf8.count + rendered.utf8.count > Self.maxBytes { break }
            body += rendered
            last = number
        }
        var result = "[tool output \(id): lines \(offset)–\(last) of \(lines.count)]\n" + body
        if last < lines.count {
            result += "[\(lines.count - last) more lines. Use offset=\(last + 1) to continue.]"
        }
        return result
    }

    private func search(_ lines: [String], pattern: String, id: String) throws -> String {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern) } catch {
            throw ToolError("\"\(pattern)\" is not a valid regular expression.")
        }
        var shown: [String] = []
        var total = 0
        for (index, line) in lines.enumerated() {
            if index % 1_000 == 0 { try Task.checkCancellation() }
            guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
            total += 1
            if shown.count < Self.maxMatches { shown.append(LineNumbering.line(index + 1, Self.clipped(line))) }
        }
        guard total > 0 else { return "[tool output \(id): no line matches \"\(pattern)\" in \(lines.count) lines.]" }
        var result = "[tool output \(id): \(total) matching lines of \(lines.count)]\n" + shown.joined(separator: "\n")
        if total > shown.count { result += "\n[\(total - shown.count) more matches. Use a narrower pattern.]" }
        return result
    }

    private static func clipped(_ line: String) -> String {
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }
        return line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…[line truncated]" : line
    }
}
