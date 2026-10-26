import Foundation

/// The dependency picture of one package.json: the package, and one node per declared name.
/// Edges are labeled with the version range. A lockfile is not read.
enum IDENpmDiagram {
    static func document(manifest: IDENpmManifest, title: String) -> IDEDiagramDocument {
        let package = IDEDiagramNode(
            key: "npm:\(manifest.packageName)", kind: .project, title: manifest.packageName, subtitle: "package"
        )
        var nodes = [package]
        var dependencyIDs: [String: UUID] = [:]
        var edges: [IDEDiagramEdge] = []
        for dependency in manifest.dependencies {
            let destination: UUID
            if let existing = dependencyIDs[dependency.name] {
                destination = existing
            } else {
                let node = IDEDiagramNode(
                    key: "npm-dep:\(dependency.name)", kind: .library, title: dependency.name, subtitle: dependency.section
                )
                nodes.append(node)
                dependencyIDs[dependency.name] = node.id
                destination = node.id
            }
            edges.append(IDEDiagramEdge(
                sourceID: package.id, destinationID: destination, kind: .libraryDependency, label: dependency.requirement
            ))
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }
}
