import Foundation

internal enum _LunaBridge {
    // Keeps explicit linkage to Luna's own layout engine.
    static var version: String { MermaidRenderer.version }
}

public enum MermaidParser {
    private static func _decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
    }

    public static func parse(_ source: String) throws -> MermaidGraph {
        _ = _LunaBridge.version
        guard source.count <= LunaLimits.maxSourceLength else {
            throw MermaidParserError.limit(
                "Source exceeds the \(LunaLimits.maxSourceLength)-character limit.")
        }
        // Full preprocessing first: CRLF, front matter, init/wrap directives, comments.
        // Throws .syntax when the front matter is not valid YAML.
        let preprocessed = try preprocessMermaid(source)
        let decoded = _decodeXMLEntities(preprocessed.text)
        // Entity codes are hidden behind placeholders so `#` and `;` survive parsing,
        // and decoded back in labels below.
        var prepared = DiagramKindDetector.prepare(encodeEntities(decoded))
        guard !prepared.lines.isEmpty else {
            throw MermaidParserError.emptyDiagram
        }
        let config = preprocessed.config
        // Front matter is consumed before detection; recover the mindmap layout from its config.
        if prepared.mindmapLayout == nil {
            prepared.mindmapLayout = DiagramKindDetector.mindmapLayout(fromConfig: config)
        }

        switch prepared.kind {
        case .sequenceDiagram:
            let parsed = try parseSequenceDiagram(prepared.lines)
            try checkEdgeLimit(parsed.messages.count, what: "sequence messages")
            return MermaidGraph(type: .sequenceDiagram, payload: parsed, mermaidConfig: config)
        case .classDiagram:
            let parsed = try parseClassDiagram(prepared.lines)
            try checkEdgeLimit(parsed.relationships.count, what: "class relationships")
            return MermaidGraph(type: .classDiagram, payload: parsed, mermaidConfig: config)
        case .erDiagram:
            let parsed = try parseErDiagram(prepared.lines)
            try checkEdgeLimit(parsed.relationships.count, what: "ER relationships")
            return MermaidGraph(type: .erDiagram, payload: parsed, mermaidConfig: config)
        case .xyChart:
            let chart = parseXYChart(prepared.lines)
            return MermaidGraph(type: .xyChart, payload: chart, mermaidConfig: config)
        case .flowchart:
            let parsed = try parseMermaid(prepared.source)
            try checkEdgeLimit((parsed.payload as? ParsedGraphModel)?.edges.count ?? 0, what: "edges")
            let decoded = decodeGraphLabels(parsed.payload)
            return MermaidGraph(type: .flowchart, payload: decoded, mermaidConfig: config)
        case .stateDiagram:
            let parsed = try parseMermaid(prepared.source)
            try checkEdgeLimit((parsed.payload as? ParsedGraphModel)?.edges.count ?? 0, what: "edges")
            let decoded = decodeGraphLabels(parsed.payload)
            return MermaidGraph(type: .stateDiagram, payload: decoded, mermaidConfig: config)
        case .agentflow:
            let rewritten = rewriteAgentflowAsFlowchart(prepared.source)
            let parsed = try parseMermaid(rewritten)
            try checkEdgeLimit((parsed.payload as? ParsedGraphModel)?.edges.count ?? 0, what: "edges")
            let decoded = decodeGraphLabels(parsed.payload)
            return MermaidGraph(type: .agentflow, payload: decoded, mermaidConfig: config)
        case .swimlane:
            let rewritten = rewriteSwimlaneAsFlowchart(prepared.source)
            let parsed = try parseMermaid(rewritten)
            try checkEdgeLimit((parsed.payload as? ParsedGraphModel)?.edges.count ?? 0, what: "edges")
            let decoded = decodeGraphLabels(parsed.payload)
            return MermaidGraph(type: .swimlane, payload: decoded, mermaidConfig: config)
        case .zenuml:
            throw MermaidParserError.unsupportedDiagram("zenuml")
        case .unknown:
            throw MermaidParserError.unsupportedDiagram(prepared.headerToken)
        default:
            let extra = try parseExtra(
                kind: prepared.kind,
                lines: prepared.lines,
                source: prepared.source,
                mindmapLayout: prepared.mindmapLayout,
                config: prepared.config
            )
            guard let type = DiagramKindDetector.diagramType(for: prepared.kind) else {
                throw MermaidParserError.unsupportedDiagram(prepared.headerToken)
            }
            return MermaidGraph(type: type, payload: extra, mermaidConfig: config)
        }
    }

    private static func checkEdgeLimit(_ count: Int, what: String) throws {
        if count > LunaLimits.maxEdges {
            throw MermaidParserError.limit(
                "Too many \(what) (\(count) exceeds the \(LunaLimits.maxEdges) limit).")
        }
    }

    /// Decodes entity placeholders back in node, edge and subgraph labels.
    private static func decodeGraphLabels(_ payload: Any?) -> Any? {
        guard var graph = payload as? ParsedGraphModel else { return payload }
        for i in graph.nodesInOrder.indices {
            graph.nodesInOrder[i].node.label = decodeEntities(graph.nodesInOrder[i].node.label)
        }
        for i in graph.edges.indices {
            if let label = graph.edges[i].label {
                graph.edges[i].label = decodeEntities(label)
            }
        }
        var stack = graph.subgraphs
        while let sub = stack.popLast() {
            sub.label = decodeEntities(sub.label)
            stack.append(contentsOf: sub.children)
        }
        return graph
    }
}
