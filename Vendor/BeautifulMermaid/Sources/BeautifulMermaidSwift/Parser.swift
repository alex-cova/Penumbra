import Foundation
import PenumbraElkSwift

internal enum _ElkBridge {
    // Keeps explicit linkage to ElkSwift runtime.
    static var version: String { ElkSwift.version }
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
        _ = _ElkBridge.version
        let decoded = _decodeXMLEntities(source)
        let prepared = DiagramKindDetector.prepare(decoded)
        guard !prepared.lines.isEmpty else {
            throw MermaidParserError.emptyDiagram
        }

        switch prepared.kind {
        case .sequenceDiagram:
            let parsed = try parseSequenceDiagram(prepared.lines)
            return MermaidGraph(type: .sequenceDiagram, payload: parsed)
        case .classDiagram:
            let parsed = try parseClassDiagram(prepared.lines)
            return MermaidGraph(type: .classDiagram, payload: parsed)
        case .erDiagram:
            let parsed = try parseErDiagram(prepared.lines)
            return MermaidGraph(type: .erDiagram, payload: parsed)
        case .xyChart:
            let chart = parseXYChart(prepared.lines)
            return MermaidGraph(type: .xyChart, payload: chart)
        case .flowchart:
            let parsed = try parseMermaid(prepared.source)
            return MermaidGraph(type: .flowchart, payload: parsed.payload)
        case .stateDiagram:
            let parsed = try parseMermaid(prepared.source)
            return MermaidGraph(type: .stateDiagram, payload: parsed.payload)
        case .agentflow:
            let rewritten = rewriteAgentflowAsFlowchart(prepared.source)
            let parsed = try parseMermaid(rewritten)
            return MermaidGraph(type: .agentflow, payload: parsed.payload)
        case .zenuml:
            throw MermaidParserError.unsupportedDiagram("zenuml")
        case .unknown:
            throw MermaidParserError.unsupportedDiagram(prepared.headerToken)
        default:
            let extra = try parseExtra(kind: prepared.kind, lines: prepared.lines, source: prepared.source)
            guard let type = DiagramKindDetector.diagramType(for: prepared.kind) else {
                throw MermaidParserError.unsupportedDiagram(prepared.headerToken)
            }
            return MermaidGraph(type: type, payload: extra)
        }
    }
}
