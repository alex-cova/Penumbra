import Foundation

public enum MermaidParserError: Error, LocalizedError, Sendable {
    case emptyDiagram
    case unsupportedDiagram(String)
    case invalidDiagram(String)
    case limit(String)
    case syntax(message: String, line: Int, column: Int, snippet: String)

    public var errorDescription: String? {
        switch self {
        case .emptyDiagram:
            return "Empty diagram"
        case .unsupportedDiagram(let kind):
            return "Unsupported diagram type: \(kind)"
        case .invalidDiagram(let message):
            return message
        case .limit(let message):
            return message
        case .syntax(let message, let line, let column, let snippet):
            let marker = String(repeating: "-", count: max(0, column - 1)) + "^"
            let body = snippet.isEmpty ? marker : snippet + "\n" + marker
            return "Parse error on line \(line):\n\(body)\n\(message)"
        }
    }
}

/// Detected Mermaid diagram kind, including types Luna does not render (e.g. ZenUML).
public enum DiagramKind: String, Equatable, Sendable {
    case flowchart
    case stateDiagram
    case sequenceDiagram
    case classDiagram
    case erDiagram
    case xyChart
    case pie
    case gantt
    case gitGraph
    case journey
    case mindmap
    case timeline
    case quadrantChart
    case sankey
    case radar
    case treemap
    case venn
    case packet
    case block
    case requirement
    case architecture
    case c4
    case kanban
    case usecase
    case treeView
    case ishikawa
    case cynefin
    case wardley
    case eventmodeling
    case railroad
    case info
    case swimlane
    case agentflow
    case zenuml
    case unknown
}

public struct PreparedMermaidSource: Sendable {
    public var kind: DiagramKind
    public var headerToken: String
    public var source: String
    public var lines: [String]
    public var mindmapLayout: MindmapLayoutMode?
    public var title: String?
    public var config: [String: YamlValue]
    public var lineOffset: Int
}

public enum DiagramKindDetector {
    public static func stripFrontmatter(_ source: String) -> String {
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstNonEmpty = rawLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              firstNonEmpty == "---"
        else {
            return source
        }
        var index = 0
        while index < rawLines.count,
              rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        guard index < rawLines.count,
              rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        else {
            return source
        }
        index += 1
        while index < rawLines.count {
            if rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                index += 1
                break
            }
            index += 1
        }
        return rawLines[index...].joined(separator: "\n")
    }

    /// Reads `layout:` from a leading `---` frontmatter block (supports nested `config:`).
    /// Now reads the parsed front-matter config: a top-level `layout:` or `config.layout:`.
    public static func parseFrontmatterLayout(_ source: String) -> MindmapLayoutMode? {
        guard let parsed = try? preprocessMermaid(source) else {
            return nil
        }
        if let mode = mindmapLayoutMode(fromConfigValue: parsed.config["layout"]) {
            return mode
        }
        if case .object(let cfg) = parsed.config["config"],
           let mode = mindmapLayoutMode(fromConfigValue: cfg["layout"]) {
            return mode
        }
        // Fall back to the raw line scan for front matter the YAML subset rejects.
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstNonEmpty = rawLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              firstNonEmpty == "---"
        else {
            return nil
        }
        var index = 0
        while index < rawLines.count,
              rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        guard index < rawLines.count,
              rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        else {
            return nil
        }
        index += 1
        while index < rawLines.count {
            let trimmed = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            if let mode = mindmapLayoutMode(fromFrontmatterLine: trimmed) {
                return mode
            }
            index += 1
        }
        return nil
    }

    private static func mindmapLayoutMode(fromConfigValue value: YamlValue?) -> MindmapLayoutMode? {
        guard let raw = value?.stringValue?.lowercased() else { return nil }
        switch raw {
        case "radial", "circle":
            return .radial
        case "tidy-tree", "tree", "lr", "default":
            return .treeLR
        default:
            return nil
        }
    }

    /// Mindmap layout from an already-parsed front-matter/init config.
    public static func mindmapLayout(fromConfig config: [String: YamlValue]) -> MindmapLayoutMode? {
        if let mode = mindmapLayoutMode(fromConfigValue: config["layout"]) {
            return mode
        }
        if case .object(let cfg) = config["config"] {
            return mindmapLayoutMode(fromConfigValue: cfg["layout"])
        }
        return nil
    }

    private static func mindmapLayoutMode(fromFrontmatterLine line: String) -> MindmapLayoutMode? {
        guard let match = line.range(
            of: #"(?i)layout:\s*(\S+)"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let value = String(line[match])
            .replacingOccurrences(of: #"(?i)^.*layout:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "radial", "circle":
            return .radial
        case "tidy-tree", "tree", "lr", "default":
            return .treeLR
        default:
            return nil
        }
    }

    public static func diagramLines(from source: String) -> [String] {
        stripFrontmatter(source)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    }

    public static func prepare(_ source: String) -> PreparedMermaidSource {
        let mindmapLayout = parseFrontmatterLayout(source)
        // Full preprocessing (front matter, init/wrap directives, comments). On invalid
        // YAML the throwing MermaidParser.parse path reports the syntax error; here we
        // fall back to the legacy strip so detection still works.
        let preprocessed = try? preprocessMermaid(source)
        let stripped = preprocessed?.text ?? stripFrontmatter(source)
        let lines = diagramLines(from: stripped)
        let header = lines.first ?? ""
        let lowered = header.lowercased()
        let token = firstToken(lowered)
        let kind = detect(headerLine: lowered)
        return PreparedMermaidSource(
            kind: kind,
            headerToken: token.isEmpty ? "unknown" : token,
            source: stripped,
            lines: lines,
            mindmapLayout: mindmapLayout,
            title: preprocessed?.title,
            config: preprocessed?.config ?? [:],
            lineOffset: preprocessed?.lineOffset ?? 0
        )
    }

    public static func detect(headerLine: String) -> DiagramKind {
        let line = headerLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !line.isEmpty else { return .unknown }

        if matches(line, #"^sequencediagram\b"#) { return .sequenceDiagram }
        if matches(line, #"^classdiagram\b"#) { return .classDiagram }
        if matches(line, #"^erdiagram\b"#) { return .erDiagram }
        if matches(line, #"^xychart(-beta)?\b"#) { return .xyChart }
        if matches(line, #"^statediagram(-v2)?\b"#) { return .stateDiagram }
        if matches(line, #"^pie\b"#) { return .pie }
        if matches(line, #"^gantt\b"#) { return .gantt }
        if matches(line, #"^gitgraph\b"#) { return .gitGraph }
        if matches(line, #"^info\b"#) { return .info }
        if matches(line, #"^journey\b"#) { return .journey }
        if matches(line, #"^mindmap\b"#) { return .mindmap }
        if matches(line, #"^timeline\b"#) { return .timeline }
        if matches(line, #"^quadrantchart\b"#) { return .quadrantChart }
        if matches(line, #"^sankey(-beta)?\b"#) { return .sankey }
        if matches(line, #"^radar(-beta)?\b"#) { return .radar }
        if matches(line, #"^treemap(-beta)?\b"#) { return .treemap }
        if matches(line, #"^venn\b"#) { return .venn }
        if matches(line, #"^packet(-beta)?\b"#) { return .packet }
        if matches(line, #"^block(-beta)?\b"#) { return .block }
        if matches(line, #"^requirement(diagram)?\b"#) { return .requirement }
        if matches(line, #"^architecture(-beta)?\b"#) { return .architecture }
        if matches(line, #"^c4(context|container|component|dynamic|deployment)\b"#) { return .c4 }
        if matches(line, #"^kanban\b"#) { return .kanban }
        if matches(line, #"^usecase(-beta)?\b"#) { return .usecase }
        if matches(line, #"^treeview\b"#) { return .treeView }
        if matches(line, #"^ishikawa\b"#) { return .ishikawa }
        if matches(line, #"^cynefin\b"#) { return .cynefin }
        if matches(line, #"^wardley(-beta)?\b"#) { return .wardley }
        if matches(line, #"^eventmodeling\b"#) { return .eventmodeling }
        if matches(line, #"^railroad\b"#) { return .railroad }
        if matches(line, #"^swimlane(-beta)?\b"#) { return .swimlane }
        if matches(line, #"^agentflow(-beta)?\b"#) { return .agentflow }
        if matches(line, #"^zenuml\b"#) { return .zenuml }
        if matches(line, #"^(graph|flowchart)\b"#) { return .flowchart }
        return .unknown
    }

    public static func diagramType(for kind: DiagramKind) -> DiagramType? {
        switch kind {
        case .flowchart: return .flowchart
        case .stateDiagram: return .stateDiagram
        case .sequenceDiagram: return .sequenceDiagram
        case .classDiagram: return .classDiagram
        case .erDiagram: return .erDiagram
        case .xyChart: return .xyChart
        case .pie: return .pie
        case .gantt: return .gantt
        case .gitGraph: return .gitGraph
        case .journey: return .journey
        case .mindmap: return .mindmap
        case .timeline: return .timeline
        case .quadrantChart: return .quadrantChart
        case .sankey: return .sankey
        case .radar: return .radar
        case .treemap: return .treemap
        case .venn: return .venn
        case .packet: return .packet
        case .block: return .block
        case .requirement: return .requirement
        case .architecture: return .architecture
        case .c4: return .c4
        case .kanban: return .kanban
        case .usecase: return .usecase
        case .treeView: return .treeView
        case .ishikawa: return .ishikawa
        case .cynefin: return .cynefin
        case .wardley: return .wardley
        case .eventmodeling: return .eventmodeling
        case .railroad: return .railroad
        case .info: return .info
        case .swimlane: return .swimlane
        case .agentflow: return .agentflow
        case .zenuml, .unknown: return nil
        }
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstToken(_ line: String) -> String {
        let scalars = line.split { $0.isWhitespace || $0 == ";" }
        return scalars.first.map(String.init) ?? ""
    }
}

enum ExtraText {
    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func width(_ text: String, size: Double = 13, weight: Int = 400) -> Double {
        max(8, original_src_styles.estimateTextWidth(text, size, weight))
    }

    static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func seriesIndex(_ value: String) -> Int {
        var hash = 0
        for byte in value.utf8 {
            hash = hash &* 31 &+ Int(byte)
        }
        return abs(hash % 6)
    }

    /// Shortens text with an ellipsis so its estimated width fits maxWidth.
    static func truncate(_ text: String, size: Double = 11, weight: Int = 400, maxWidth: Double) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if width(trimmed, size: size, weight: weight) <= maxWidth || trimmed.isEmpty {
            return trimmed
        }
        var result = trimmed
        while !result.isEmpty, width(result + "…", size: size, weight: weight) > maxWidth {
            result.removeLast()
        }
        return result + "…"
    }

    /// Greedy word wrap; overlong words are hard-split. Every returned line
    /// fits maxWidth by the same estimator the layouts use for spacing.
    static func wrap(_ text: String, size: Double = 10, weight: Int = 400, maxWidth: Double) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if width(trimmed, size: size, weight: weight) <= maxWidth {
            return [trimmed]
        }
        var lines: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                lines.append(current)
                current = ""
            }
        }
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if width(candidate, size: size, weight: weight) <= maxWidth {
                current = candidate
                continue
            }
            if current.isEmpty {
                var piece = ""
                for ch in word {
                    if width(piece + String(ch), size: size, weight: weight) > maxWidth, !piece.isEmpty {
                        lines.append(piece)
                        piece = String(ch)
                    } else {
                        piece.append(ch)
                    }
                }
                current = piece
            } else {
                flush()
                if width(word, size: size, weight: weight) <= maxWidth {
                    current = word
                } else {
                    var piece = ""
                    for ch in word {
                        if width(piece + String(ch), size: size, weight: weight) > maxWidth, !piece.isEmpty {
                            lines.append(piece)
                            piece = String(ch)
                        } else {
                            piece.append(ch)
                        }
                    }
                    current = piece
                }
            }
        }
        flush()
        return lines.isEmpty ? [trimmed] : lines
    }
}
