import AgentKit
import EditorIntelligence
import Foundation
import JavaIntelligence

/// One place a symbol is declared or used.
struct IDEAgentCodeLocation: Sendable, Equatable {
    /// `nil` for a target that has no file (a library class shown by name only).
    var fileURL: URL?
    /// 1-based.
    var line: Int
    var label: String
    var kind: String?
    var isAmbiguous = false
}

/// Java symbol navigation as the agent tools use it. `IDEWorkspace` backs it with the same
/// providers as Go to Definition and Find Usages; tests use a fake.
protocol IDEAgentJavaNavigating: Sendable {
    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation]
    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation]
}

/// Finds the character offset of a symbol on a line, so the model can name a symbol instead of
/// counting columns.
enum IDEAgentSymbolLocator {
    enum Failure: Error, Equatable, LocalizedError {
        case lineOutOfRange(line: Int, lineCount: Int)
        case notOnLine(symbol: String, line: Int, text: String)
        case ambiguous(symbol: String, line: Int, count: Int)

        var errorDescription: String? {
            switch self {
            case .lineOutOfRange(let line, let count): "The file has \(count) lines; line \(line) does not exist."
            case .notOnLine(let symbol, let line, let text):
                "“\(symbol)” does not appear as a whole word on line \(line): \(text.trimmingCharacters(in: .whitespaces))"
            case .ambiguous(let symbol, let line, let count):
                "“\(symbol)” appears \(count) times on line \(line). Pass `occurrence` (1 to \(count)) to say which."
            }
        }
    }

    /// UTF-16 offset of the `occurrence`th whole-word match of `symbol` on 1-based `line`.
    /// With one match `occurrence` may be omitted.
    static func offset(in text: String, line: Int, symbol: String, occurrence: Int? = nil) throws -> Int {
        let ns = text as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 10 { starts.append(index + 1) }
            else if unit == 13 {
                if index + 1 < ns.length, ns.character(at: index + 1) == 10 { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        // A trailing newline starts no line.
        if starts.count > 1, starts.last == ns.length { starts.removeLast() }
        guard line >= 1, line <= starts.count else { throw Failure.lineOutOfRange(line: line, lineCount: starts.count) }
        let start = starts[line - 1]
        var end = line < starts.count ? starts[line] : ns.length
        while end > start, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
        let lineText = ns.substring(with: NSRange(location: start, length: end - start))

        var matches: [Int] = []
        let needle = symbol as NSString
        guard needle.length > 0 else { throw Failure.notOnLine(symbol: symbol, line: line, text: lineText) }
        var search = NSRange(location: 0, length: (lineText as NSString).length)
        while true {
            let found = (lineText as NSString).range(of: symbol, options: [], range: search)
            if found.location == NSNotFound { break }
            if isWholeWord(found, in: lineText as NSString) { matches.append(start + found.location) }
            let next = found.location + max(1, found.length)
            search = NSRange(location: next, length: (lineText as NSString).length - next)
            if search.length <= 0 { break }
        }
        guard !matches.isEmpty else { throw Failure.notOnLine(symbol: symbol, line: line, text: lineText) }
        if let occurrence {
            guard occurrence >= 1, occurrence <= matches.count else {
                throw Failure.ambiguous(symbol: symbol, line: line, count: matches.count)
            }
            return matches[occurrence - 1]
        }
        guard matches.count == 1 else { throw Failure.ambiguous(symbol: symbol, line: line, count: matches.count) }
        return matches[0]
    }

    private static func isWholeWord(_ range: NSRange, in line: NSString) -> Bool {
        func isIdentifier(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
        }
        if range.location > 0, isIdentifier(line.character(at: range.location - 1)) { return false }
        let after = range.location + range.length
        if after < line.length, isIdentifier(line.character(at: after)) { return false }
        return true
    }
}

private enum NavigationOutput {
    static let maxLocations = 100

    /// `path:line: text`, in the form `grep` uses; a target outside the project is named, not opened.
    static func render(
        _ locations: [IDEAgentCodeLocation], root: URL, lineText: (URL, Int) async -> String?
    ) async -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        var lines: [String] = []
        for location in locations.prefix(maxLocations) {
            guard let url = location.fileURL else {
                lines.append("(library) \(location.label)")
                continue
            }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else {
                lines.append("(outside the project) \(location.label)")
                continue
            }
            let relative = String(path.dropFirst(base.count))
            var text = await lineText(url, location.line)?.trimmingCharacters(in: .whitespaces) ?? location.label
            if text.count > 300 { text = String(text.prefix(300)) + "…" }
            var suffix = ""
            if let kind = location.kind { suffix += "  [\(kind)]" }
            if location.isAmbiguous { suffix += "  (may belong to an overload or sibling)" }
            lines.append("\(relative):\(location.line): \(text)\(suffix)")
        }
        if locations.count > maxLocations { lines.append("… and \(locations.count - maxLocations) more.") }
        return lines
    }
}

/// The arguments both tools share, and the file they read the symbol's position from.
private struct SymbolQuery {
    let path: String
    let source: String
    let url: URL
    let offset: Int

    init(_ arguments: ToolArguments, context: ToolContext) async throws {
        path = try arguments.string("path")
        guard path.lowercased().hasSuffix(".java") else {
            throw ToolError("Symbol navigation works on Java files; \(path) is not one. Use grep instead.")
        }
        guard let line = try arguments.optionalInt("line") else { throw ToolError("Missing `line`.") }
        let symbol = try arguments.string("symbol")
        source = try await context.workspace.readText(path: path)
        do {
            offset = try IDEAgentSymbolLocator.offset(
                in: source, line: line, symbol: symbol, occurrence: try arguments.optionalInt("occurrence"))
        } catch let failure as IDEAgentSymbolLocator.Failure {
            throw ToolError(failure.localizedDescription)
        }
        url = URL(fileURLWithPath: context.workspace.rootPath).appendingPathComponent(path).standardizedFileURL
    }

    static let parameters = [
        ToolParameter("path", .string, "Project-relative path of the Java file where the symbol appears."),
        ToolParameter("line", .integer, "1-based line where the symbol appears."),
        ToolParameter("symbol", .string, "The identifier, exactly as written on that line."),
        ToolParameter("occurrence", .integer, "Which match when the identifier appears more than once on the line.", optional: true),
    ]
}

struct IDEGoToDefinitionTool: AgentTool {
    let navigator: any IDEAgentJavaNavigating
    let lineText: @Sendable (URL, Int) async -> String?

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "go_to_definition",
            description: """
            Find where a Java symbol is declared, resolved by the compiler's rules (imports, overloads, \
            inheritance), which grep cannot do. Give the file, the line and the identifier as written there.
            """,
            parameters: SymbolQuery.parameters)
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let query = try await SymbolQuery(arguments, context: context)
        let found = await navigator.definitions(file: query.url, source: query.source, utf16Offset: query.offset)
        guard !found.isEmpty else {
            return "No definition found. The symbol may be unresolved (check `diagnostics`), or the Java index is still building."
        }
        let lines = await NavigationOutput.render(found, root: URL(fileURLWithPath: context.workspace.rootPath), lineText: lineText)
        return lines.joined(separator: "\n")
    }
}

struct IDEFindUsagesTool: AgentTool {
    let navigator: any IDEAgentJavaNavigating
    let lineText: @Sendable (URL, Int) async -> String?

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_usages",
            description: """
            List every place the project uses a Java symbol (calls, reads, writes, type references, \
            imports), not the declaration itself. It tells a method from another of the same name, so it \
            is safer than grep before renaming or changing a signature.
            """,
            parameters: SymbolQuery.parameters)
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let query = try await SymbolQuery(arguments, context: context)
        let found = await navigator.usages(file: query.url, source: query.source, utf16Offset: query.offset)
        guard !found.isEmpty else {
            return "No usages found. The symbol may be unused, unresolved (check `diagnostics`), or the Java index is still building."
        }
        let lines = await NavigationOutput.render(found, root: URL(fileURLWithPath: context.workspace.rootPath), lineText: lineText)
        return "\(found.count) \(found.count == 1 ? "usage" : "usages"):\n" + lines.joined(separator: "\n")
    }
}

// MARK: - The real navigator

/// Backs the tools with Umbra's Java providers. Definitions never ask about decompiling a class
/// file: the trigger is `.idle`, which the provider treats as "don't prompt".
struct IDEJavaAgentNavigator: IDEAgentJavaNavigating {
    let definitionProvider: JavaGoToDefinitionProvider
    let usageProvider: JavaFindUsagesProvider

    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        let position = Self.position(in: source, utf16Offset: utf16Offset)
        let range = TextRange(start: position, end: position)
        let document = Document(
            url: file, displayName: file.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: range), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0), languageIdentifier: "java")
        let context = NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, trigger: .idle, kind: .definition)
        let locations: [Location]
        switch await definitionProvider.provide(context: context) {
        case .single(let location)?: locations = [location]
        case .multiple(let found)?: locations = found
        case nil: locations = []
        }
        return locations.map { location in
            IDEAgentCodeLocation(
                fileURL: location.url ?? (location.documentID == document.id ? file : nil),
                line: location.range.start.line + 1, label: location.displayName)
        }
    }

    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        await usageProvider.findUsages(source: source, url: file, utf16Offset: utf16Offset).map { usage in
            IDEAgentCodeLocation(
                fileURL: usage.url, line: usage.line + 1, label: usage.lineText,
                kind: String(describing: usage.kind), isAmbiguous: usage.confidence == .ambiguous)
        }
    }

    private static func position(in text: String, utf16Offset: Int) -> TextPosition {
        let ns = text as NSString
        let end = min(max(0, utf16Offset), ns.length)
        var line = 0
        var lineStart = 0
        var index = 0
        while index < end {
            let unit = ns.character(at: index)
            if unit == 10 || (unit == 13 && !(index + 1 < ns.length && ns.character(at: index + 1) == 10)) {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return TextPosition(line: line, column: end - lineStart, utf16Offset: end)
    }
}
