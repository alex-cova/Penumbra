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

/// Symbol navigation as the agent tools use it. The window backs it with ``NavigationEngine``;
/// tests use a fake, and the Java providers remain available for tests that call them directly.
protocol IDEAgentNavigating: Sendable {
    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation]
    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation]
    /// The types that extend or implement the type at the offset, or override the method there.
    func implementations(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation]
}

extension IDEAgentNavigating {
    func implementations(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] { [] }
}

typealias IDEAgentJavaNavigating = IDEAgentNavigating

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

    /// The project-relative path of a file, or `nil` when it is outside the project.
    static func relativePath(of url: URL, root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

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
        guard Self.languageIdentifier(for: path) != nil else {
            throw ToolError("Symbol navigation works on Java, Swift, TypeScript and JavaScript files; \(path) is not one. Use grep instead.")
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

    static func languageIdentifier(for path: String) -> String? { IDEAgentSourceLanguage.identifier(forPath: path) }

    static let parameters = [
        ToolParameter("path", .string, "Project-relative path of the source file where the symbol appears."),
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
            Find where a symbol is declared. Java, Swift, TypeScript and JavaScript use the language's \
            own navigation, which grep cannot do. Give the file, the line and the identifier as written there.
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
            List every place the project uses a symbol, not the declaration itself. Java, Swift, \
            TypeScript and JavaScript use the language's own navigation, so a method is told from \
            another of the same name. Safer than grep before renaming or changing a signature.
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

// MARK: - Name search and one-call exploration

private enum SymbolOutput {
    static let maxLineLength = 300

    /// `path:line: kind qualified.name(detail)`, in the form `grep` uses.
    static func row(_ symbol: IDEAgentSymbol, root: URL) -> String {
        var label = symbol.qualifiedName
        if let detail = symbol.detail {
            label += detail.hasPrefix("(") || detail.hasPrefix(":") ? detail : " " + detail
        }
        let described = "\(symbol.kind) \(label)"
        guard let relative = NavigationOutput.relativePath(of: symbol.fileURL, root: root) else {
            return "(outside the project) \(described)"
        }
        guard let line = symbol.line else {
            return "\(relative): \(described)  (not found where the index put it; the file changed since it was indexed)"
        }
        return "\(relative):\(line): \(described)" + (symbol.movedSinceIndexing ? "  (moved since indexing)" : "")
    }

    static func banner(_ status: String?) -> String? {
        status.map { "[The index is still being built (\($0)). Results may be incomplete; grep covers what it has not reached yet.]" }
    }

    /// `    12\ttext`, the form `read_file` shows code in.
    static func numbered(_ number: Int, _ text: String) -> String {
        let clipped = text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : text
        return String(repeating: " ", count: max(0, 6 - String(number).count)) + "\(number)\t\(clipped)"
    }
}

struct IDEFindSymbolTool: AgentTool {
    static let defaultLimit = 20
    static let maxLimit = 50

    let search: any IDEAgentSymbolSearching

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_symbol",
            description: """
            Find a project class, interface, method or field by its name or part of it (camel humps work, \
            like Go to Symbol). Needs no file. Searches the project's own Java, Swift and TypeScript \
            declarations, not libraries and not text: use grep for text.
            """,
            parameters: [
                ToolParameter("query", .string, "The name or part of it, e.g. `OrderService`, `OrdSer` or `findBy`."),
                ToolParameter("limit", .integer, "Most rows to return (default \(Self.defaultLimit), at most \(Self.maxLimit)).", optional: true),
            ])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let query = try arguments.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("Missing `query`.") }
        let limit = min(max(try arguments.optionalInt("limit") ?? Self.defaultLimit, 1), Self.maxLimit)
        let found = await search.symbols(matching: query, exactName: false, limit: limit)
        let status = await search.indexStatus()
        guard !found.isEmpty else {
            if let status {
                return "Nothing found yet: the index is still being built (\(status)). Use grep for now and try again later."
            }
            return "No project declaration matches “\(query)”. Libraries are not searched, and this is not a text search: use grep for text."
        }
        let root = URL(fileURLWithPath: context.workspace.rootPath)
        var lines: [String] = []
        if let banner = SymbolOutput.banner(status) { lines.append(banner) }
        lines += found.map { SymbolOutput.row($0, root: root) }
        if found.count == limit { lines.append("Showing the first \(limit). Use a longer query to narrow it.") }
        return lines.joined(separator: "\n")
    }
}

struct IDEExploreSymbolTool: AgentTool {
    static let maxDeclarationLines = 40
    static let maxHeaderLines = 12
    static let maxDocLines = 30
    static let maxMembers = 60
    static let maxImplementations = 20
    static let maxUsages = 25
    static let maxCandidates = 20

    let search: any IDEAgentSymbolSearching
    let navigator: any IDEAgentNavigating
    let lineText: @Sendable (URL, Int) async -> String?

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "explore_symbol",
            description: """
            Everything about one symbol from its name alone, in one call: the declaration with its doc \
            comment, the members of a type, implementations and usages. Name it `Calc`, `Calc.add` or \
            `demo.Calc.add`. If several declarations share the name, the candidates come back; pick one with \
            `path` and `line`. For a symbol you already see in a file, go_to_definition and find_usages are exact.
            """,
            parameters: [
                ToolParameter("name", .string, "The symbol, optionally qualified by its class or package."),
                ToolParameter("path", .string, "Project-relative file, to pick one of several declarations.", optional: true),
                ToolParameter("line", .integer, "1-based line of the declaration's name, to pick one of several.", optional: true),
            ])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let name = try arguments.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let simple = name.split(separator: ".").last.map(String.init) ?? ""
        guard !simple.isEmpty else { throw ToolError("Missing `name`.") }
        let root = URL(fileURLWithPath: context.workspace.rootPath)

        var matches = await search.symbols(matching: simple, exactName: true, limit: 100)
        if name.contains(".") { matches = matches.filter { $0.qualifiedName == name || $0.qualifiedName.hasSuffix("." + name) } }
        if let path = try arguments.optionalString("path") {
            matches = matches.filter { NavigationOutput.relativePath(of: $0.fileURL, root: root) == path }
        }
        if let line = try arguments.optionalInt("line") { matches = matches.filter { $0.line == line } }
        let status = await search.indexStatus()

        guard !matches.isEmpty else {
            if let status {
                return "Nothing found yet: the index is still being built (\(status)). Use grep for now and try again later."
            }
            return "No project declaration is named “\(name)”. Try find_symbol with part of the name; libraries are not indexed here."
        }
        guard matches.count == 1, let symbol = matches.first else {
            var lines = ["\(matches.count) declarations match “\(name)”. Call explore_symbol again with `path` and `line` to pick one:"]
            if let banner = SymbolOutput.banner(status) { lines.insert(banner, at: 0) }
            lines += matches.prefix(Self.maxCandidates).map { SymbolOutput.row($0, root: root) }
            if matches.count > Self.maxCandidates { lines.append("… and \(matches.count - Self.maxCandidates) more.") }
            return lines.joined(separator: "\n")
        }
        return await describe(symbol, status: status, root: root)
    }

    private func describe(_ symbol: IDEAgentSymbol, status: String?, root: URL) async -> String {
        var out: [String] = []
        if let banner = SymbolOutput.banner(status) { out.append(banner) }
        guard let offset = symbol.utf16Offset, let nameLine = symbol.line,
              let source = await search.liveText(of: symbol.fileURL),
              let relative = NavigationOutput.relativePath(of: symbol.fileURL, root: root) else {
            out.append(SymbolOutput.row(symbol, root: root))
            out.append("Read the file or use grep to see what it holds now.")
            return out.joined(separator: "\n")
        }
        out.append("\(symbol.qualifiedName) — \(symbol.kind) — \(relative):\(nameLine)")
        if symbol.movedSinceIndexing { out.append("(The index had it elsewhere; this is where the file holds it now.)") }

        let lineIndex = IDEAgentLineIndex(source)
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let roots = await search.structure(file: symbol.fileURL, source: source)
        let node = StructureNode.path(toNameAt: offset, in: roots)?.last

        // Where the declaration runs: a member to the end of its body, a type to the end of its header.
        var start = nameLine
        var end = nameLine
        if let node {
            start = min(lineIndex.line(at: node.bodyRange.lowerBound), nameLine)
            end = symbol.isType
                ? Self.headerEnd(from: start, in: lines)
                : max(lineIndex.line(at: max(node.bodyRange.upperBound - 1, node.bodyRange.lowerBound)), nameLine)
        } else {
            end = Self.headerEnd(from: nameLine, in: lines)
        }
        var omitted = 0
        if end - start + 1 > Self.maxDeclarationLines {
            omitted = end - start + 1 - Self.maxDeclarationLines
            end = start + Self.maxDeclarationLines - 1
        }
        let first = Self.docStart(above: start, in: lines)
        out.append("")
        out.append("Declaration (\(relative):\(first)-\(min(end, lines.count))):")
        for number in first...max(first, min(end, lines.count)) where number <= lines.count {
            out.append(SymbolOutput.numbered(number, lines[number - 1]))
        }
        if omitted > 0 {
            out.append("… \(omitted) more lines: read_file \(relative) with offset=\(end + 1).")
        }

        if symbol.isType, let node, !node.children.isEmpty {
            out.append("")
            out.append("Members (\(node.children.count)):")
            for child in node.children.prefix(Self.maxMembers) {
                out.append("\(relative):\(lineIndex.line(at: child.nameRange.lowerBound)): \(child.kind.rawValue) \(child.title)")
            }
            if node.children.count > Self.maxMembers { out.append("… and \(node.children.count - Self.maxMembers) more.") }
        }

        async let implementing = navigator.implementations(file: symbol.fileURL, source: source, utf16Offset: offset)
        async let using = navigator.usages(file: symbol.fileURL, source: source, utf16Offset: offset)
        let (implementations, usages) = await (implementing, using)

        if !implementations.isEmpty {
            out.append("")
            out.append("Implementations (\(implementations.count)):")
            out += await NavigationOutput.render(Array(implementations.prefix(Self.maxImplementations)), root: root, lineText: lineText)
            if implementations.count > Self.maxImplementations {
                out.append("… and \(implementations.count - Self.maxImplementations) more.")
            }
        }

        out.append("")
        if usages.isEmpty {
            out.append("Usages: none found. The symbol may be unused, or the index may not have reached its callers yet.")
        } else {
            let files = Set(usages.compactMap { $0.fileURL?.standardizedFileURL.path }).count
            out.append("Usages (\(usages.count) in \(files) \(files == 1 ? "file" : "files")):")
            let ordered = usages.sorted { lhs, rhs in
                (lhs.fileURL?.path ?? "\u{10FFFF}", lhs.line) < (rhs.fileURL?.path ?? "\u{10FFFF}", rhs.line)
            }
            out += await NavigationOutput.render(Array(ordered.prefix(Self.maxUsages)), root: root, lineText: lineText)
            if usages.count > Self.maxUsages {
                out.append("… and \(usages.count - Self.maxUsages) more: call find_usages for all of them.")
            }
        }
        return out.joined(separator: "\n")
    }

    /// The first line from `start` that opens a body or ends a declaration, at most `maxHeaderLines` on.
    private static func headerEnd(from start: Int, in lines: [String]) -> Int {
        let last = min(lines.count, start + maxHeaderLines - 1)
        guard start <= last else { return start }
        for number in start...last {
            let text = lines[number - 1].trimmingCharacters(in: .whitespaces)
            if text.contains("{") || text.hasSuffix(";") { return number }
        }
        return last
    }

    /// The first line of the annotations and doc comment that sit directly above `line`.
    private static func docStart(above line: Int, in lines: [String]) -> Int {
        var first = line
        var number = line - 1
        while number >= 1, line - number <= maxDocLines {
            let text = lines[number - 1].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("@") || text.hasPrefix("//") {
                first = number
                number -= 1
            } else if text.hasSuffix("*/") {
                var open = number
                while open >= 1, !lines[open - 1].contains("/*") { open -= 1 }
                guard open >= 1, line - open <= maxDocLines else { break }
                first = open
                number = open - 1
            } else {
                break
            }
        }
        return first
    }
}

// MARK: - The real navigator

/// Backs the tools with Umbra's Java providers. Definitions never ask about decompiling a class
/// file: the trigger is `.idle`, which the provider treats as "don't prompt".
/// Asks ``NavigationEngine``, so every language that registered navigation answers.
struct IDEEngineAgentNavigator: IDEAgentNavigating {
    let engine: NavigationEngine

    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        await locate(file: file, source: source, utf16Offset: utf16Offset, kind: .definition)
    }

    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        await locate(file: file, source: source, utf16Offset: utf16Offset, kind: .references)
    }

    func implementations(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        await locate(file: file, source: source, utf16Offset: utf16Offset, kind: .implementation)
    }

    private func locate(file: URL, source: String, utf16Offset: Int, kind: NavigationKind) async -> [IDEAgentCodeLocation] {
        let position = IDEJavaAgentNavigator.position(in: source, utf16Offset: utf16Offset)
        let range = TextRange(start: position, end: position)
        let document = Document(
            url: file, displayName: file.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: range), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
            languageIdentifier: SymbolQuery.languageIdentifier(for: file.path))
        let context = NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, trigger: .idle, kind: kind)
        let locations: [Location]
        switch await engine.navigate(context: context) {
        case .single(let location)?: locations = [location]
        case .multiple(let found)?: locations = found
        case nil: locations = []
        }
        return locations.map { location in
            IDEAgentCodeLocation(
                fileURL: location.url ?? (location.documentID == document.id ? file : nil),
                line: location.range.start.line + 1,
                label: location.displayName,
                kind: location.usage?.kindLabel,
                isAmbiguous: location.usage?.isAmbiguous ?? false)
        }
    }
}

struct IDEJavaAgentNavigator: IDEAgentNavigating {
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

    static func position(in text: String, utf16Offset: Int) -> TextPosition {
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
