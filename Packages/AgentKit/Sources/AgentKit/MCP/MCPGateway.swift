import Foundation

/// One deferred tool: listed in no request, found with `tool_search`, run with `tool_call`.
struct MCPGatewayEntry: Sendable {
    var serverName: String
    var tool: MCPTool
}

/// The deferred tools of a hub, fixed when the hub started. Both gateway tools hold the same catalog.
final class MCPGatewayCatalog: Sendable {
    let entries: [MCPGatewayEntry]
    private let byName: [String: MCPGatewayEntry]
    private let documents: [[String: Int]]

    init(entries: [MCPGatewayEntry]) {
        self.entries = entries
        byName = Dictionary(entries.map { ($0.tool.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Words with a weight: the tool's own name counts most, its server less, its description least.
        documents = entries.map { entry in
            var words: [String: Int] = [:]
            for word in Self.words(of: entry.tool.remoteName) { words[word, default: 0] += 3 }
            for word in Self.words(of: entry.serverName) { words[word, default: 0] += 1 }
            for word in Self.words(of: entry.tool.definition.description) { words[word, default: 0] += 1 }
            return words
        }
    }

    func entry(named name: String) -> MCPGatewayEntry? { byName[name] }

    /// A server and how many deferred tools it has, in the order servers were given.
    var servers: [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in entries {
            if counts[entry.serverName] == nil { order.append(entry.serverName) }
            counts[entry.serverName, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// Entries that match the words of `query`, best first. A query word matches a document word equal to
    /// it, or one that starts with it or that it starts with (so `issues` finds `issue_create`).
    func search(_ query: String, server: String?, limit: Int) -> [MCPGatewayEntry] {
        let wanted = Self.words(of: query)
        guard !wanted.isEmpty else { return [] }
        var scored: [(index: Int, score: Int)] = []
        for (index, entry) in entries.enumerated() {
            if let server, entry.serverName.caseInsensitiveCompare(server) != .orderedSame { continue }
            var score = 0
            for word in wanted {
                for (document, weight) in documents[index] {
                    if document == word { score += weight * 3 }
                    else if document.hasPrefix(word) || (word.count > 3 && word.hasPrefix(document) && document.count > 2) { score += weight }
                }
            }
            if score > 0 { scored.append((index, score)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map { entries[$0.index] }
    }

    /// Lower-case words of at least two letters, with `snake_case` and `camelCase` split.
    static func words(of text: String) -> [String] {
        var spaced = ""
        var previousLower = false
        for character in text {
            if character.isUppercase, previousLower { spaced.append(" ") }
            spaced.append(character)
            previousLower = character.isLowercase
        }
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "are", "use", "can", "you", "your", "will", "all", "any", "not"]
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
    }
}

/// `tool_search`: finds deferred tools by keyword and returns each with the schema to call it. A read:
/// it only looks in a list the hub already holds.
public struct MCPToolSearchTool: AgentTool {
    public static let defaultLimit = 5
    public static let maximumLimit = 10
    public static let maxOutputCharacters = 8_000

    let catalog: MCPGatewayCatalog

    public var risk: ToolRisk { .read }

    /// Useless without `tool_call`, which plan mode does not offer.
    public func isOffered(in mode: PermissionMode) -> Bool { mode != .plan }

    public var definition: ToolDefinition {
        let servers = catalog.servers.map { "- \($0.name): \($0.count) tools" }.joined(separator: "\n")
        return ToolDefinition(
            name: "tool_search",
            description: """
            Find tools of connected services that are not listed above. Pass a few keywords (what you want to do, \
            the thing it applies to); the result gives each matching tool's name, description and input schema. \
            Call one with tool_call. Services you can search:
            \(servers)
            """,
            parameters: [
                ToolParameter("query", .string, "Keywords, such as \"create issue\" or \"list pull requests\"."),
                ToolParameter("server", .string, "Only search this service.", optional: true),
                ToolParameter("limit", .integer, "How many tools to return (default \(Self.defaultLimit), at most \(Self.maximumLimit)).", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let query = try arguments.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("Pass keywords as \"query\".") }
        let limit = min(Self.maximumLimit, max(1, try arguments.optionalInt("limit") ?? Self.defaultLimit))
        let server = try arguments.optionalString("server")?.trimmingCharacters(in: .whitespaces)
        let found = catalog.search(query, server: server?.isEmpty == true ? nil : server, limit: limit)
        guard !found.isEmpty else {
            let names = catalog.servers.map { "\($0.name) (\($0.count) tools)" }.joined(separator: ", ")
            return "No tool matches “\(query)”. Try other words, or fewer. Searchable: \(names)."
        }
        var text = "\(found.count) tool\(found.count == 1 ? "" : "s") found. Call one with tool_call, passing its name and arguments that fit its schema.\n"
        for entry in found {
            let definition = entry.tool.definition
            let schema = (try? definition.schema(strict: false).serialized()) ?? "{}"
            let block = "\n\(definition.name)\n\(definition.description)\nschema: \(schema)\n"
            if text.count + block.count > Self.maxOutputCharacters, text.contains("schema:") { break }
            text += block
        }
        return UntrustedContent.wrap(text, source: "tool_search")
    }
}

/// `tool_call`: runs a deferred tool by its full name. The session swaps in the real tool before it
/// decides anything (`AgentTool.forwardedCall`), so rules, the approval card, "always allow" and the
/// untrusted wrapper behave exactly as for a tool that is listed. `run` only sees a call that could not be
/// forwarded: an unknown name, or arguments missing something required.
public struct MCPToolCallTool: AgentTool {
    let catalog: MCPGatewayCatalog

    /// Conservative on its own; the real call is judged by the tool it names.
    public var risk: ToolRisk { .command }
    public var runsWithoutTimeout: Bool { true }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "tool_call",
            description: "Run a tool found with tool_search, by its full name, with arguments that fit its schema.",
            rawSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The tool's full name, from tool_search."],
                    "arguments": ["type": "object", "description": "The tool's arguments."],
                ],
                "required": ["name", "arguments"],
            ])
    }

    private func parse(_ arguments: ToolArguments) -> (name: String, arguments: ToolArguments)? {
        guard let name = try? arguments.optionalString("name") else { return nil }
        let values = arguments.presentValues
        var inner: [String: JSONValue] = [:]
        if let object = values["arguments"]?.objectValue {
            inner = object
        } else if let text = values["arguments"]?.stringValue, let parsed = (try? JSONValue(parsing: text))?.objectValue {
            inner = parsed
        }
        return (name.trimmingCharacters(in: .whitespacesAndNewlines), ToolArguments(inner))
    }

    public func forwardedCall(for arguments: ToolArguments) -> ForwardedCall? {
        guard let call = parse(arguments), let entry = catalog.entry(named: call.name), missingRequired(entry, call.arguments).isEmpty,
              let json = try? JSONValue.object(call.arguments.presentValues).serialized()
        else { return nil }
        return ForwardedCall(tool: entry.tool, argumentsJSON: json)
    }

    private func missingRequired(_ entry: MCPGatewayEntry, _ arguments: ToolArguments) -> [String] {
        let required = entry.tool.definition.schema(strict: false)["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let present = arguments.presentValues
        return required.filter { present[$0] == nil }
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        guard let call = parse(arguments), !call.name.isEmpty else {
            throw ToolError("Pass the tool's full name as \"name\" and its arguments as \"arguments\".")
        }
        guard let entry = catalog.entry(named: call.name) else {
            let close = catalog.search(call.name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " "), server: nil, limit: 3)
            let hint = close.isEmpty ? "Use tool_search to find it." : "Did you mean: \(close.map(\.tool.name).joined(separator: ", "))?"
            throw ToolError("There is no tool named “\(call.name)”. \(hint)")
        }
        let missing = missingRequired(entry, call.arguments)
        let schema = (try? entry.tool.definition.schema(strict: false).serialized()) ?? "{}"
        if !missing.isEmpty {
            throw ToolError("Not run: \(entry.tool.name) needs \(missing.joined(separator: ", ")). Its schema: \(schema)")
        }
        // Not forwarded (a host that does not support it): run the real tool directly.
        return try await entry.tool.run(call.arguments, context: context)
    }
}
