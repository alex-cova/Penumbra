import CoreGraphics
import Foundation
import JavaIntelligence

/// Turns the pure graphs of JavaIntelligence into the document the canvas draws. Ids come from the
/// content, so building the same graph twice gives the same boxes (selection and viewport survive a refresh).
nonisolated enum IDEDiagramDocumentBuilder {
    static func document(from graph: JavaClassGraph, title: String) -> IDEDiagramDocument {
        var nodes: [IDEDiagramNode] = []
        var idByName: [String: UUID] = [:]
        for source in graph.nodes {
            let kind = nodeKind(for: source)
            let node = IDEDiagramNode(
                key: source.qualifiedName,
                kind: kind,
                title: source.displayName,
                subtitle: source.isExternal ? source.packageName : stereotype(for: source),
                attributes: source.attributes,
                methods: source.methods,
                fileURL: source.sourceURL
            )
            nodes.append(node)
            idByName[source.qualifiedName] = node.id
        }
        var edges: [IDEDiagramEdge] = []
        for source in graph.edges {
            guard let from = idByName[source.source], let to = idByName[source.destination] else { continue }
            edges.append(IDEDiagramEdge(sourceID: from, destinationID: to, kind: edgeKind(source.kind), label: source.label))
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }

    static func document(from graph: GradleDependencyGraph, title: String) -> IDEDiagramDocument {
        var nodes: [IDEDiagramNode] = []
        var idByKey: [String: UUID] = [:]
        for component in graph.components {
            let node: IDEDiagramNode
            switch component.kind {
            case .project:
                node = IDEDiagramNode(
                    key: component.key, kind: .project, title: component.name,
                    subtitle: component.projectPath == ":" ? "root project" : component.projectPath
                )
            case .module:
                node = IDEDiagramNode(
                    key: component.key,
                    kind: component.conflictResolved ? .replacedLibrary : .library,
                    title: component.name,
                    subtitle: [component.group, component.version].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            case .unresolved:
                node = IDEDiagramNode(
                    key: component.key, kind: .unresolvedLibrary, title: component.name,
                    subtitle: component.message.isEmpty ? "unresolved" : String(component.message.prefix(48))
                )
            }
            nodes.append(node)
            idByKey[component.key] = node.id
        }
        var edges: [IDEDiagramEdge] = []
        let projectKeys = Set(graph.components.filter { $0.kind == .project }.map(\.key))
        for source in graph.edges {
            guard let from = idByKey[source.from], let to = idByKey[source.to] else { continue }
            let kind: IDEDiagramEdgeKind
            var label = ""
            if let requested = source.requestedVersion {
                kind = .replaced
                label = "asked " + requested
            } else if projectKeys.contains(source.from), projectKeys.contains(source.to) {
                kind = .projectDependency
                if source.runtimeOnly { label = "runtime" }
            } else {
                kind = .libraryDependency
            }
            if source.constraint, label.isEmpty { label = "constraint" }
            edges.append(IDEDiagramEdge(sourceID: from, destinationID: to, kind: kind, label: label))
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }

    /// A class graph as the session's loader returns it, including the truncation notice.
    static func load(from graph: JavaClassGraph, title: String) -> IDEDiagramLoad {
        var notice: String?
        if graph.truncated {
            notice = "Showing \(graph.nodes.count) types; \(graph.omittedCount) more omitted. Narrow the scope to see them."
        }
        return IDEDiagramLoad(
            document: document(from: graph, title: title),
            notice: notice,
            emptyMessage: "No Java types found for this scope. If the project was just opened, wait for indexing to finish and reload."
        )
    }

    /// A Gradle dependency graph as the session's loader returns it.
    static func load(from graph: GradleDependencyGraph, title: String, emptyMessage: String) -> IDEDiagramLoad {
        var notice: String?
        if let error = graph.error, !error.isEmpty {
            notice = error
        } else if graph.truncated {
            notice = "Showing \(graph.components.count) libraries; \(graph.omittedCount) more omitted."
        }
        return IDEDiagramLoad(document: document(from: graph, title: title), notice: notice, emptyMessage: emptyMessage)
    }

    private static func nodeKind(for node: JavaClassGraph.Node) -> IDEDiagramNodeKind {
        if node.isExternal { return .externalType }
        switch node.kind {
        case .classKind: return node.isAbstract ? .abstractClass : .classType
        case .interfaceKind: return .interfaceType
        case .enumKind: return .enumType
        case .recordKind: return .recordType
        case .annotationKind: return .annotationType
        }
    }

    private static func stereotype(for node: JavaClassGraph.Node) -> String {
        switch node.kind {
        case .classKind: node.isAbstract ? "«abstract»" : ""
        case .interfaceKind: "«interface»"
        case .enumKind: "«enumeration»"
        case .recordKind: "«record»"
        case .annotationKind: "«annotation»"
        }
    }

    private static func edgeKind(_ kind: JavaClassGraph.EdgeKind) -> IDEDiagramEdgeKind {
        switch kind {
        case .inheritance: .inheritance
        case .realization: .realization
        case .association: .association
        case .aggregation: .aggregation
        case .dependency: .dependency
        }
    }
}
