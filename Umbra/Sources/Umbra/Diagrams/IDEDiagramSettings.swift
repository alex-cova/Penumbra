import DiagramKit
import Foundation
import JavaIntelligence

/// How a diagram arranges its boxes.
nonisolated enum IDEDiagramLayoutKind: String, CaseIterable, Sendable {
    case hierarchical
    case hierarchicalLeftToRight
    case tree
    case radial
    case forceDirected
    case circular
    case grid

    var title: String {
        switch self {
        case .hierarchical: "Hierarchical (Top to Bottom)"
        case .hierarchicalLeftToRight: "Hierarchical (Left to Right)"
        case .tree: "Tree"
        case .radial: "Radial"
        case .forceDirected: "Force-Directed"
        case .circular: "Circular"
        case .grid: "Grid"
        }
    }
}

/// The diagram options, shared by every diagram tab and kept across launches.
nonisolated struct IDEDiagramSettings: Equatable, Sendable {
    var layout: IDEDiagramLayoutKind = .hierarchical
    var routing: EdgeRoutingStyle = .orthogonal
    var showMembers = true
    var showPrivateMembers = false
    var showExternalTypes = false
    var neighbourDepth = 0
    var libraryConfiguration = GradleDependencyGraphExtractor.defaultConfiguration

    static let libraryConfigurations = ["runtimeClasspath", "compileClasspath", "testRuntimeClasspath", "testCompileClasspath"]

    private static let prefix = "umbra.diagram."

    var classOptions: JavaClassGraphOptions {
        JavaClassGraphOptions(
            showMembers: showMembers,
            showPrivateMembers: showPrivateMembers,
            showExternalTypes: showExternalTypes,
            neighbourDepth: neighbourDepth
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> IDEDiagramSettings {
        var settings = IDEDiagramSettings()
        if let raw = defaults.string(forKey: prefix + "layout"), let value = IDEDiagramLayoutKind(rawValue: raw) { settings.layout = value }
        if let raw = defaults.string(forKey: prefix + "routing"), let value = EdgeRoutingStyle(rawValue: raw) { settings.routing = value }
        if defaults.object(forKey: prefix + "members") != nil { settings.showMembers = defaults.bool(forKey: prefix + "members") }
        if defaults.object(forKey: prefix + "privateMembers") != nil { settings.showPrivateMembers = defaults.bool(forKey: prefix + "privateMembers") }
        if defaults.object(forKey: prefix + "external") != nil { settings.showExternalTypes = defaults.bool(forKey: prefix + "external") }
        if defaults.object(forKey: prefix + "depth") != nil { settings.neighbourDepth = max(0, min(2, defaults.integer(forKey: prefix + "depth"))) }
        if let raw = defaults.string(forKey: prefix + "configuration"), !raw.isEmpty { settings.libraryConfiguration = raw }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: Self.prefix + "layout")
        defaults.set(routing.rawValue, forKey: Self.prefix + "routing")
        defaults.set(showMembers, forKey: Self.prefix + "members")
        defaults.set(showPrivateMembers, forKey: Self.prefix + "privateMembers")
        defaults.set(showExternalTypes, forKey: Self.prefix + "external")
        defaults.set(neighbourDepth, forKey: Self.prefix + "depth")
        defaults.set(libraryConfiguration, forKey: Self.prefix + "configuration")
    }
}

/// Positions for a diagram's boxes. Supertype edges are fed to the layout reversed, so a parent sits
/// above its children; every other edge points from the dependent down to what it depends on.
nonisolated enum IDEDiagramLayoutEngine {
    static func frames(for document: IDEDiagramDocument, kind: IDEDiagramLayoutKind) -> [NodeFrame] {
        let nodes = document.nodes.map { NodeFrame(id: $0.id, frame: $0.frame) }
        let edges = document.edges.map { edge in
            edge.kind.ranksDestinationFirst
                ? (source: edge.destinationID, destination: edge.sourceID)
                : (source: edge.sourceID, destination: edge.destinationID)
        }
        let graph = LayoutGraph(nodes: nodes, edges: edges)
        var options = LayoutOptions(origin: CGPoint(x: 40, y: 40), horizontalSpacing: 56, verticalSpacing: 72, direction: .topToBottom)
        switch kind {
        case .hierarchical:
            return HierarchicalLayout().layout(graph, options: options)
        case .hierarchicalLeftToRight:
            options.direction = .leftToRight
            options.horizontalSpacing = 96
            options.verticalSpacing = 40
            return HierarchicalLayout().layout(graph, options: options)
        case .tree:
            return TreeLayout().layout(graph, options: options)
        case .radial:
            return RadialLayout().layout(graph, options: options)
        case .forceDirected:
            return ForceDirectedLayout().layout(graph, options: options)
        case .circular:
            return CircularLayout().layout(graph, options: options)
        case .grid:
            return GridLayout().layout(graph, options: options)
        }
    }

    static func laidOut(_ document: IDEDiagramDocument, kind: IDEDiagramLayoutKind) -> IDEDiagramDocument {
        var next = document
        let frames = Dictionary(uniqueKeysWithValues: frames(for: document, kind: kind).map { ($0.id, $0.frame) })
        for index in next.nodes.indices {
            if let frame = frames[next.nodes[index].id] {
                next.nodes[index].frame.origin = frame.origin
            }
        }
        return next
    }
}
