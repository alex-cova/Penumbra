import Foundation

/// The tools that change files, in the fixed order the request lists them.
public enum EditingTools {
    public static func all() -> [any AgentTool] {
        [EditFileTool(), WriteFileTool(), ApplyPatchTool()]
    }
}

/// What both edit tools need to judge a file: the text the model last saw, and its line endings.
enum EditSupport {
    /// The "not found" error. A model that copies a block with the wrong indentation, or repeats an
    /// edit that already went through, cannot fix that from "not found" alone, so say what the file
    /// really holds.
    static func notFoundMessage(path: String, old: String, new: String, in text: String) -> String {
        let base = "old_string was not found in \(path). It must match the file exactly, including indentation and line breaks."
        if let near = nearMatch(of: old, in: text) {
            let shown = near.lines.prefix(12).joined(separator: "\n")
            let more = near.lines.count > 12 ? "\n…" : ""
            let range = near.lines.count == 1 ? "line \(near.startLine)" : "lines \(near.startLine)–\(near.startLine + near.lines.count - 1)"
            let others = near.count > 1 ? " (\(near.count) places match this way; this is the first)" : ""
            return "\(base) The same text is at \(range) once spacing is ignored\(others); the file has exactly:\n\(shown)\(more)\nCopy those lines, with their indentation, as old_string."
        }
        if !new.isEmpty, let range = (text as NSString).range(of: new, options: .literal) as NSRange?, range.location != NSNotFound {
            return "\(base) new_string is already in the file at line \(line(atOffset: range.location, in: text)), so this edit may already have been made. Re-read \(path) before trying again."
        }
        return base + " Re-read the lines and copy the text again."
    }

    /// Where `old` occurs if leading and repeated whitespace is ignored line by line.
    static func nearMatch(of old: String, in text: String) -> (startLine: Int, lines: [String], count: Int)? {
        func key(_ line: Substring) -> String {
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        }
        var needle = old.split(separator: "\n", omittingEmptySubsequences: false).map(key)
        while needle.first == "" { needle.removeFirst() }
        while needle.last == "" { needle.removeLast() }
        guard !needle.isEmpty, needle.contains(where: { !$0.isEmpty }) else { return nil }
        let fileLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let keys = fileLines.map(key)
        guard keys.count >= needle.count else { return nil }
        var first: Int?
        var count = 0
        var index = 0
        while index + needle.count <= keys.count {
            if Array(keys[index..<(index + needle.count)]) == needle {
                if first == nil { first = index }
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        guard let start = first else { return nil }
        let raw = fileLines[start..<(start + needle.count)].map { String($0).replacingOccurrences(of: "\r", with: "") }
        return (start + 1, raw, count)
    }

    static func lineEnding(of text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// The model writes `\n`; a CRLF file gets `\r\n` so the edit matches and keeps the file's style.
    static func adapt(_ text: String, toLineEnding ending: String) -> String {
        guard ending == "\r\n", !text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Refuses a file the model has not read, or that changed since it did.
    static func requireFreshRead(path: String, text: String, context: ToolContext) async throws {
        guard await context.ledger.hasRead(path) else {
            throw ToolError("Read \(path) with read_file before changing it.")
        }
        guard await context.ledger.isCurrent(path: path, text: text) else {
            throw ToolError("\(path) changed since you last read it (the user may have edited it). Read it again before changing it.")
        }
    }

    /// Numbered lines around an edit, so the model sees the result without another read.
    static func snippet(path: String, text: String, startLine: Int, lineCount: Int, context radius: Int = 3) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        let first = max(1, startLine - radius)
        let last = min(lines.count, startLine + max(lineCount, 1) - 1 + radius)
        guard first <= last else { return "" }
        var shown = Array(first...last)
        if shown.count > 40 { shown = Array(shown.prefix(40)) }
        let body = shown.map { number -> String in
            var line = lines[number - 1]
            if line.hasSuffix("\r") { line.removeLast() }
            if line.count > 300 { line = String(line.prefix(300)) + "…" }
            return LineNumbering.line(number, line)
        }
        return "[\(path): lines \(shown.first!)–\(shown.last!) after the change]\n" + body.joined(separator: "\n")
    }

    /// 1-based line number of a UTF-16 offset.
    static func line(atOffset offset: Int, in text: String) -> Int {
        let ns = text as NSString
        var line = 1
        var index = 0
        let end = min(offset, ns.length)
        while index < end {
            if ns.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }
}

public struct EditFileTool: AgentTool {
    public init() {}
    public var risk: ToolRisk { .edit }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: """
            Replace text in an existing file. old_string must match the file exactly, including \
            indentation, and must appear exactly once unless replace_all is true: include enough \
            surrounding lines to make it unique. Read the file with read_file first.
            """,
            parameters: [
                ToolParameter("path", .string, "Project-relative path of an existing file."),
                ToolParameter("old_string", .string, "The exact text to replace."),
                ToolParameter("new_string", .string, "The replacement text."),
                ToolParameter("replace_all", .boolean, "Replace every occurrence. Default false.", optional: true),
            ])
    }

    /// The change an `edit_file` call would make, checked but not made.
    struct Prepared {
        let path: String
        let original: String
        let expected: String
        let edits: [AgentTextEdit]
        let firstLocation: Int
        let replacedLineCount: Int
        let occurrences: Int
        /// Set when the match was not byte-for-byte, so the model is told what was relaxed.
        let matchNote: String
    }

    func prepare(_ arguments: ToolArguments, context: ToolContext) async throws -> Prepared {
        let path = try arguments.string("path")
        let old = try arguments.string("old_string")
        let new = try arguments.string("new_string")
        let replaceAll = try arguments.optionalBool("replace_all") ?? false
        guard !old.isEmpty else { throw ToolError("old_string must not be empty. Use write_file to create a file.") }
        guard old != new else { throw ToolError("old_string and new_string are identical; there is nothing to change.") }

        try context.workspace.checkWritable(path: path)
        let text = try await context.workspace.readText(path: path)
        try await EditSupport.requireFreshRead(path: path, text: text, context: context)

        let ending = EditSupport.lineEnding(of: text)
        let oldText = EditSupport.adapt(old, toLineEnding: ending)
        let newText = EditSupport.adapt(new, toLineEnding: ending)

        let ns = text as NSString
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: oldText, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            searchRange = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }

        if matches.isEmpty {
            return try prepareAlternative(
                path: path, old: old, new: new, text: text, replaceAll: replaceAll, context: context)
        }
        if matches.count > 1, !replaceAll {
            let lines = matches.prefix(5).map { String(EditSupport.line(atOffset: $0.location, in: text)) }.joined(separator: ", ")
            throw ToolError("old_string appears \(matches.count) times in \(path) (lines \(lines)\(matches.count > 5 ? ", …" : "")). Add surrounding lines to make it unique, or set replace_all to true.")
        }

        let chosen = replaceAll ? matches : [matches[0]]
        let edits = chosen.map { AgentTextEdit(location: $0.location, length: $0.length, replacement: newText) }
        return Prepared(
            path: path, original: text, expected: try AgentTextEdit.apply(edits, to: text), edits: edits,
            firstLocation: chosen[0].location, replacedLineCount: newText.components(separatedBy: "\n").count,
            occurrences: chosen.count, matchNote: "")
    }

    /// A unique canonical or indentation match, applied to those lines only.
    private func prepareAlternative(
        path: String, old: String, new: String, text: String, replaceAll: Bool, context: ToolContext
    ) throws -> Prepared {
        switch EditMatching.alternative(old: old, new: new, in: text, tolerance: context.editTolerance, replaceAll: replaceAll) {
        case .none:
            throw ToolError(EditSupport.notFoundMessage(path: path, old: old, new: new, in: text))
        case .noop:
            throw ToolError("old_string and new_string are identical once line endings, trailing whitespace or punctuation are normalized; there is nothing to change.")
        case .ambiguous(let count, let lines):
            let listed = lines.map(String.init).joined(separator: ", ")
            throw ToolError("old_string appears \(count) times in \(path) (lines \(listed)\(count > 5 ? ", …" : "")). Add surrounding lines to make it unique, or set replace_all to true.")
        case .hits(let hits):
            let edits = hits.map { AgentTextEdit(location: $0.range.location, length: $0.range.length, replacement: $0.replacement) }
            let note = hits[0].kind == .indentation
                ? " Applied after shifting indentation to match the file."
                : " Applied after normalizing line endings, trailing whitespace or punctuation."
            let lineCount = hits[0].replacement.components(separatedBy: "\n").count
            return Prepared(
                path: path, original: text, expected: try AgentTextEdit.apply(edits, to: text), edits: edits,
                firstLocation: hits[0].range.location, replacedLineCount: lineCount, occurrences: hits.count, matchNote: note)
        }
    }

    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? {
        guard let change = try? await prepare(arguments, context: context) else { return nil }
        return EditPreview(
            summary: "Edit \(change.path) (\(change.occurrences == 1 ? "1 occurrence" : "\(change.occurrences) occurrences"))",
            diff: UnifiedDiff.make(path: change.path, old: change.original, new: change.expected))
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = (try? arguments.string("path")) ?? ""
        do {
            let written = try await apply(arguments, context: context)
            if !path.isEmpty { await context.editFailures?.recordSuccess(path) }
            return await context.finishFileTool(written, path: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let count = path.isEmpty ? 0 : (await context.editFailures?.recordFailure(path) ?? 0)
            if let hint = EditFailureLog.hint(count: count) { throw ToolError(error.localizedDescription + hint) }
            throw error
        }
    }

    private func apply(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let change = try await prepare(arguments, context: context)
        let (path, text) = (change.path, change.original)

        await context.checkpoint?.willChange(path: path, original: text)
        try await context.workspace.replaceText(path: path, expecting: text, edits: change.edits)
        let after = try await context.workspace.readText(path: path)
        await context.checkpoint?.didChange(path: path, written: after)

        // The edit tool and the workspace must agree on the result; if the file moved under us the
        // model reads it again instead of building on a guess.
        guard after == change.expected else {
            throw ToolError("\(path) was changed while the edit was applied and no longer matches what was expected. Read it again.")
        }
        await context.ledger.record(path: path, text: after)

        let startLine = EditSupport.line(atOffset: change.firstLocation, in: after)
        let count = change.occurrences == 1 ? "1 occurrence" : "\(change.occurrences) occurrences"
        return "Edited \(path): replaced \(count), starting at line \(startLine).\(change.matchNote)\n"
            + EditSupport.snippet(path: path, text: after, startLine: startLine, lineCount: change.replacedLineCount)
    }
}

public struct WriteFileTool: AgentTool {
    static let maxBytes = 2_000_000

    public init() {}
    public var risk: ToolRisk { .edit }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: """
            Create a new file, or replace a whole existing file with new content. Replacing needs a \
            prior read_file of that file. For a change to part of a file use edit_file instead.
            """,
            parameters: [
                ToolParameter("path", .string, "Project-relative path. Folders are created as needed."),
                ToolParameter("content", .string, "The complete new content of the file."),
            ])
    }

    struct Prepared {
        let path: String
        /// `nil` when the file does not exist yet.
        let existing: String?
        /// What the file will hold.
        let result: String
    }

    func prepare(_ arguments: ToolArguments, context: ToolContext) async throws -> Prepared {
        let path = try arguments.string("path")
        let content = try arguments.string("content")
        guard content.utf8.count <= Self.maxBytes else {
            throw ToolError("The content is \(content.utf8.count) bytes; write_file takes at most \(Self.maxBytes). Write the file in parts with edit_file.")
        }
        try context.workspace.checkWritable(path: path)

        let existing: String?
        do {
            existing = try await context.workspace.readText(path: path)
        } catch AgentWorkspaceError.notFound {
            existing = nil
        } catch AgentWorkspaceError.notText {
            throw ToolError("\(path) exists but is not a UTF-8 text file; it will not be overwritten.")
        }
        guard let existing else { return Prepared(path: path, existing: nil, result: content) }

        try await EditSupport.requireFreshRead(path: path, text: existing, context: context)
        let replacement = EditSupport.adapt(content, toLineEnding: EditSupport.lineEnding(of: existing))
        guard replacement != existing else { throw ToolError("\(path) already has exactly this content.") }
        return Prepared(path: path, existing: existing, result: replacement)
    }

    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? {
        guard let change = try? await prepare(arguments, context: context) else { return nil }
        let verb = change.existing == nil ? "Create" : "Overwrite"
        return EditPreview(summary: "\(verb) \(change.path)", diff: UnifiedDiff.make(path: change.path, old: change.existing, new: change.result))
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let change = try await prepare(arguments, context: context)
        let path = change.path

        if let existing = change.existing {
            let whole = AgentTextEdit(location: 0, length: (existing as NSString).length, replacement: change.result)
            await context.checkpoint?.willChange(path: path, original: existing)
            try await context.workspace.replaceText(path: path, expecting: existing, edits: [whole])
            let after = try await context.workspace.readText(path: path)
            await context.checkpoint?.didChange(path: path, written: after)
            guard after == change.result else {
                throw ToolError("\(path) was changed while it was written and no longer matches. Read it again.")
            }
            await context.ledger.record(path: path, text: after)
            return await context.finishFileTool("Overwrote \(path) (\(Self.lineCount(after)) lines).", path: path)
        }

        await context.checkpoint?.willChange(path: path, original: nil)
        try await context.workspace.createFile(path: path, contents: change.result)
        let after = try await context.workspace.readText(path: path)
        await context.checkpoint?.didChange(path: path, written: after)
        await context.ledger.record(path: path, text: after)
        return await context.finishFileTool("Created \(path) (\(Self.lineCount(after)) lines).", path: path)
    }

    private static func lineCount(_ text: String) -> Int {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }
}
