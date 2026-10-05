import Foundation

enum LineNumbering {
    /// `    12\ttext`, the form `read_file` and the edit tools show code in.
    static func line(_ number: Int, _ text: String) -> String {
        String(repeating: " ", count: max(0, 6 - String(number).count)) + "\(number)\t\(text)"
    }
}

/// The generic read-only tools, in the fixed order the request lists them (byte-stable for caching).
public enum ReadOnlyTools {
    /// `secretPatterns` are extra globs (one per entry) for files that must stay unread, on top of the built-in list.
    public static func all(secretPatterns: [String] = []) -> [any AgentTool] {
        let extra = SecretFilePolicy.patterns(from: secretPatterns)
        return [ReadFileTool(extraSecretPatterns: extra), ListDirTool(), GlobTool(), GrepTool(extraSecretPatterns: extra)]
    }
}

public struct ReadFileTool: AgentTool {
    public static let maxLines = 2_000
    public static let maxBytes = 64 * 1_024
    static let maxLineLength = 2_000
    private let extraSecretPatterns: [GlobPattern]

    public init(extraSecretPatterns: [GlobPattern] = []) {
        self.extraSecretPatterns = extraSecretPatterns
    }
    public var risk: ToolRisk { .read }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Read a text file from the project with numbered lines. Long files are paged: pass offset to continue.",
            parameters: [
                ToolParameter("path", .string, "Project-relative path."),
                ToolParameter("offset", .integer, "1-based line to start from. Default 1.", optional: true),
                ToolParameter("limit", .integer, "Maximum number of lines. Default \(Self.maxLines).", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = try arguments.string("path")
        let offset = max(1, try arguments.optionalInt("offset") ?? 1)
        let limit = min(Self.maxLines, max(1, try arguments.optionalInt("limit") ?? Self.maxLines))

        guard !SecretFilePolicy.isLikelySecret(path, extra: extraSecretPatterns) else {
            throw ToolError("\(path) looks like it holds credentials, so it is not read: file contents are sent to the model's provider. Ask the user to share what you need.")
        }
        let text = try await context.workspace.readText(path: path)
        await context.ledger.record(path: path, text: text)
        if text.isEmpty { return await context.finishFileTool("[\(path): empty file]", path: path) }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard offset <= lines.count else {
            throw ToolError("\(path) has \(lines.count) lines; offset \(offset) is past the end.")
        }

        var body = ""
        var last = offset - 1
        for number in offset...min(lines.count, offset + limit - 1) {
            var line = lines[number - 1]
            if line.hasSuffix("\r") { line.removeLast() }
            if line.count > Self.maxLineLength { line = String(line.prefix(Self.maxLineLength)) + "…[line truncated]" }
            let rendered = LineNumbering.line(number, line) + "\n"
            // Always return at least one line, however long.
            if !body.isEmpty, body.utf8.count + rendered.utf8.count > Self.maxBytes { break }
            body += rendered
            last = number
        }

        var result = "[\(path): lines \(offset)–\(last) of \(lines.count)]\n" + body
        if last < lines.count {
            result += "[\(lines.count - last) more lines. Use offset=\(last + 1) to continue.]"
        }
        return await context.finishFileTool(result, path: path)
    }
}

public struct ListDirTool: AgentTool {
    static let maxEntries = 500

    public init() {}
    public var risk: ToolRisk { .read }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "list_dir",
            description: "List the files and folders directly inside a project folder. Folders end with /.",
            parameters: [ToolParameter("path", .string, "Project-relative folder. Empty or \".\" for the project root.", optional: true)])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = try arguments.optionalString("path") ?? ""
        let entries = try await context.workspace.listDirectory(path: path == "." ? "" : path)
        let shown = entries.prefix(Self.maxEntries)
        var lines = shown.map { $0.isDirectory ? "\($0.name)/" : $0.name }
        if lines.isEmpty { return "[\(path.isEmpty ? "." : path): empty]" }
        if entries.count > shown.count { lines.append("[\(entries.count - shown.count) more entries not shown.]") }
        return lines.joined(separator: "\n")
    }
}

public struct GlobTool: AgentTool {
    static let maxResults = 200

    public init() {}
    public var risk: ToolRisk { .read }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "glob",
            description: "Find project files by path pattern, e.g. \"**/*Test.java\" or \"src/**/*.{java,kt}\". A pattern without / matches file names at any depth.",
            parameters: [ToolParameter("pattern", .string, "Glob pattern.")])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let pattern = try arguments.string("pattern")
        let glob = try GlobPattern(pattern)
        let matches = try await context.workspace.allFiles().filter(glob.matches)
        if matches.isEmpty { return "No files match \(pattern)." }
        var lines = Array(matches.prefix(Self.maxResults))
        if matches.count > lines.count { lines.append("[\(matches.count - lines.count) more files not shown. Narrow the pattern.]") }
        return lines.joined(separator: "\n")
    }
}

public struct GrepTool: AgentTool {
    public static let maxResults = 100
    static let maxLineLength = 300
    private let extraSecretPatterns: [GlobPattern]

    public init(extraSecretPatterns: [GlobPattern] = []) {
        self.extraSecretPatterns = extraSecretPatterns
    }
    public var risk: ToolRisk { .read }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "grep",
            description: "Search project files for a regular expression. Results are path:line: text.",
            parameters: [
                ToolParameter("pattern", .string, "Regular expression."),
                ToolParameter("path", .string, "Project-relative folder or file to search. Default: the whole project.", optional: true),
                ToolParameter("glob", .string, "Only search files matching this glob, e.g. \"*.java\".", optional: true),
                ToolParameter("case_sensitive", .boolean, "Default true.", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let query = SearchQuery(
            pattern: try arguments.string("pattern"),
            isRegex: true,
            caseSensitive: try arguments.optionalBool("case_sensitive") ?? true,
            path: try arguments.optionalString("path"),
            fileGlob: try arguments.optionalString("glob"),
            maxResults: Self.maxResults)
        let results = try await context.workspace.search(query)
        // Matches inside credential files are dropped for the same reason `read_file` refuses them.
        let visible = results.matches.filter { !SecretFilePolicy.isLikelySecret($0.path, extra: extraSecretPatterns) }
        if visible.isEmpty { return "No matches for \(query.pattern)." }

        var lines = visible.map { match -> String in
            let text = match.text.trimmingCharacters(in: .whitespaces)
            let shown = text.count > Self.maxLineLength ? String(text.prefix(Self.maxLineLength)) + "…" : text
            return "\(match.path):\(match.line): \(shown)"
        }
        if results.truncated { lines.append("[More matches exist. Narrow the pattern, path or glob.]") }
        return lines.joined(separator: "\n")
    }
}
