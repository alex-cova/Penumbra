import DiagramKit
import Foundation
import SpringIntelligence

/// The two Spring pictures as diagram requests. The request id carries everything that identifies the picture (application,
/// focus bean, direction, depth), so asking for the same one selects its tab; the filters in the tool window apply on (re)load.
enum IDESpringDiagramRequest {
    static func beanGraph(contextID: String, focus: SpringBeanID?, direction: SpringBeanGraphOptions.Direction, depth: Int?) -> IDEDiagramRequest {
        let focusPart = focus?.raw ?? "*"
        let id = ["spring.beans", contextID, focusPart, direction.rawValue, depth.map(String.init) ?? "all"].joined(separator: "|")
        let name = contextID.split(separator: ".").last.map(String.init) ?? contextID
        let title = focus == nil ? "Beans: \(name)" : "Bean graph: \(focusPart.split(separator: ":").last.map(String.init) ?? focusPart)"
        return IDEDiagramRequest(id: id, title: title, symbolName: "point.3.connected.trianglepath.dotted", presentation: .dependencies)
    }

    static func contextGraph(contextID: String) -> IDEDiagramRequest {
        let name = contextID.split(separator: ".").last.map(String.init) ?? contextID
        return IDEDiagramRequest(id: "spring.context|\(contextID)", title: "Context: \(name)", symbolName: "square.stack.3d.up", presentation: .dependencies)
    }

    enum Parsed {
        case beans(contextID: String, focus: SpringBeanID?, direction: SpringBeanGraphOptions.Direction, depth: Int?)
        case context(contextID: String)
    }

    static func parse(_ request: IDEDiagramRequest) -> Parsed? {
        let parts = request.id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "spring.beans" where parts.count == 5:
            return .beans(contextID: parts[1], focus: parts[2] == "*" ? nil : SpringBeanID(raw: parts[2]),
                          direction: SpringBeanGraphOptions.Direction(rawValue: parts[3]) ?? .both, depth: Int(parts[4]))
        case "spring.context" where parts.count == 2:
            return .context(contextID: parts[1])
        default:
            return nil
        }
    }
}

/// Builds the diagram documents from the Spring graph models, off the main actor.
enum IDESpringDiagram {
    @MainActor
    static func load(_ request: IDEDiagramRequest, workspace: IDEWorkspace) async -> IDEDiagramLoad? {
        guard let parsed = IDESpringDiagramRequest.parse(request) else { return nil }
        let indexer = workspace.javaSupport.springIndexer
        let options = workspace.springStore.graphOptions
        let title = request.title
        return await Task.detached(priority: .userInitiated) { () -> IDEDiagramLoad in
            let store = indexer.store
            let modules = await indexer.modules
            let contexts = await store.contexts()
            let resolver = SpringModuleResolver(modules: modules)
            let moduleOf: @Sendable (URL) -> String? = { resolver.owner(of: $0) }
            switch parsed {
            case .beans(let contextID, let focus, let direction, let depth):
                guard let context = contexts.first(where: { $0.id == contextID }) else {
                    return IDEDiagramLoad(document: .empty(title: title), failure: "That Spring application is no longer in the project.")
                }
                var o = options
                o.focus = focus; o.direction = direction; o.depth = depth
                let graph = SpringBeanGraph(context: context, moduleOf: moduleOf)
                let slice = graph.slice(o)
                return load(from: slice, title: title,
                            empty: focus == nil ? "This application registers no beans." : "That bean is not in this application.")
            case .context(let contextID):
                guard let context = contexts.first(where: { $0.id == contextID }) else {
                    return IDEDiagramLoad(document: .empty(title: title), failure: "That Spring application is no longer in the project.")
                }
                let graph = SpringContextGraph(context: context, moduleOf: moduleOf)
                return load(nodes: graph.nodes, edges: graph.edges, title: title, notes: graph.notes, empty: "No configuration classes to show.")
            }
        }.value
    }

    static func load(from slice: SpringGraphSlice, title: String, empty: String) -> IDEDiagramLoad {
        load(nodes: slice.nodes, edges: slice.edges, title: title, notes: slice.notes, empty: empty)
    }

    static func load(nodes: [SpringGraphNode], edges: [SpringGraphEdge], title: String, notes: [String], empty: String) -> IDEDiagramLoad {
        IDEDiagramLoad(document: document(nodes: nodes, edges: edges, title: title), notice: notes.isEmpty ? nil : notes.joined(separator: " "), emptyMessage: empty)
    }

    static func document(nodes: [SpringGraphNode], edges: [SpringGraphEdge], title: String) -> IDEDiagramDocument {
        var out: [IDEDiagramNode] = []
        var idByKey: [String: UUID] = [:]
        for node in nodes {
            let n = IDEDiagramNode(
                key: node.id, kind: kind(of: node), title: node.title,
                subtitle: [node.subtitle, node.module].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                fileURL: node.location?.url, sourceByteRange: node.location?.byteRange)
            out.append(n)
            idByKey[node.id] = n.id
        }
        var outEdges: [IDEDiagramEdge] = []
        for e in edges {
            guard let from = idByKey[e.from], let to = idByKey[e.to] else { continue }
            outEdges.append(IDEDiagramEdge(sourceID: from, destinationID: to, kind: kind(of: e), label: label(of: e)))
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: out, edges: outEdges)
    }

    static func kind(of node: SpringGraphNode) -> IDEDiagramNodeKind {
        switch node.kind {
        case .external: return node.subtitle.hasPrefix("no bean") ? .springUnresolved : .springExternal
        case .configuration: return .springConfiguration
        case .scannedPackage: return .springPackage
        case .unknown: return .springExternal
        case .bean(let label):
            if node.isInCycle { return .springUnresolved }
            if node.certainty.isConditional || node.certainty.isInactive { return .springConditionalBean }
            switch label {
            case "Controller", "RestController", "ControllerAdvice": return .springController
            case "Repository": return .springRepository
            case "Configuration", "Application": return .springConfiguration
            default: return .springBean
            }
        }
    }

    static func kind(of edge: SpringGraphEdge) -> IDEDiagramEdgeKind {
        switch edge.relation {
        case .declares: return .springDeclares
        case .importClass: return edge.status == .unresolved ? .springUnresolved : .springImport
        case .importResource: return .springUnresolved
        case .componentScan: return .springScan
        case .injection:
            if edge.isInCycle { return .springCycle }
            switch edge.status {
            case .verified: return .springDependency
            case .conditional: return .springConditional
            case .ambiguous: return .springAmbiguous
            case .unresolved: return .springUnresolved
            }
        }
    }

    /// The status is also in words, so the picture does not rely on line style alone.
    static func label(of edge: SpringGraphEdge) -> String {
        var parts: [String] = [edge.label]
        if edge.isInCycle { parts.append("cycle") }
        else {
            switch (edge.relation, edge.status) {
            case (.injection, .conditional): parts.append("conditional")
            case (.injection, .ambiguous): parts.append("ambiguous")
            case (.injection, .unresolved): parts.append("unresolved")
            default: break
            }
        }
        if edge.isDeferred { parts.append("lazy") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
