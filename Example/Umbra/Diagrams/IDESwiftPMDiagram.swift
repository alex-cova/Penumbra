import Foundation

/// The targets of one package and what each depends on. A dependency that is another target of the
/// package is drawn as a project dependency; one that is a product of an external package is a
/// library. Dependencies the manifest names but this reading cannot place appear as libraries too.
enum IDESwiftPMDiagram {
    static func document(manifest: IDESwiftPMManifest, title: String) -> IDEDiagramDocument {
        var nodes: [IDEDiagramNode] = []
        var ids: [String: UUID] = [:]
        var edges: [IDEDiagramEdge] = []
        for target in manifest.targets {
            let node = IDEDiagramNode(
                key: "swiftpm:\(target.name)", kind: .project, title: target.name, subtitle: target.kind.rawValue
            )
            nodes.append(node)
            ids[target.name] = node.id
        }
        for target in manifest.targets {
            guard let source = ids[target.name] else { continue }
            for dependency in target.dependencies {
                let destination: UUID
                let kind: IDEDiagramEdgeKind
                if let existing = ids[dependency] {
                    destination = existing
                    kind = manifest.target(named: dependency) != nil ? .projectDependency : .libraryDependency
                } else {
                    let node = IDEDiagramNode(
                        key: "swiftpm-dep:\(dependency)", kind: .library, title: dependency, subtitle: "package product"
                    )
                    nodes.append(node)
                    ids[dependency] = node.id
                    destination = node.id
                    kind = .libraryDependency
                }
                edges.append(IDEDiagramEdge(sourceID: source, destinationID: destination, kind: kind, label: ""))
            }
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }
}
