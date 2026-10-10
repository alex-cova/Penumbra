import Foundation

/// One TypeScript file's types, taken from the syntactic model. Neighbour depth is ignored:
/// a name written in `extends` or `implements` is linked when that file declares it.
enum IDETypeScriptDiagram {
    static func document(
        model: TypeScriptFileModel, fileURL: URL, title: String, settings: IDEDiagramSettings
    ) -> IDEDiagramDocument {
        let path = fileURL.standardizedFileURL.path
        var nodes: [IDEDiagramNode] = []
        var declared: [(name: String, heritage: [String], id: UUID)] = []
        collect(model.declarations, path: path, fileURL: fileURL, settings: settings, nodes: &nodes, declared: &declared)
        var idByName: [String: UUID] = [:]
        for entry in declared where idByName[entry.name] == nil {
            idByName[entry.name] = entry.id
        }
        var edges: [IDEDiagramEdge] = []
        var externalIDs: [String: UUID] = [:]
        for entry in declared {
            let source = entry.id
            for raw in entry.heritage {
                let name = simpleName(raw)
                guard !name.isEmpty, name != entry.name else { continue }
                let destination: UUID
                if let declaredID = idByName[name] {
                    destination = declaredID
                } else if settings.showExternalTypes {
                    if let existing = externalIDs[name] {
                        destination = existing
                    } else {
                        let node = IDEDiagramNode(
                            key: "typescript-external:\(name)", kind: .externalType, title: name
                        )
                        nodes.append(node)
                        externalIDs[name] = node.id
                        destination = node.id
                    }
                } else {
                    continue
                }
                edges.append(IDEDiagramEdge(sourceID: source, destinationID: destination, kind: .inheritance))
            }
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }

    private static func collect(
        _ declarations: [TypeScriptFileModel.Declaration],
        path: String,
        fileURL: URL,
        settings: IDEDiagramSettings,
        nodes: inout [IDEDiagramNode],
        declared: inout [(name: String, heritage: [String], id: UUID)]
    ) {
        for declaration in declarations {
            guard declaration.kind.isType else { continue }
            if declaration.isPrivate, !settings.showPrivateMembers { continue }
            let (kind, subtitle) = appearance(of: declaration.kind)
            var attributes: [String] = []
            var methods: [String] = []
            if settings.showMembers {
                for member in declaration.members {
                    if member.kind.isType { continue }
                    if member.isPrivate, !settings.showPrivateMembers { continue }
                    switch member.kind {
                    case .field, .enumMember: attributes.append(member.signature)
                    case .method: methods.append(member.signature)
                    default: break
                    }
                }
            }
            let node = IDEDiagramNode(
                key: "typescript:\(path)#\(declaration.nameBytes.lowerBound)",
                kind: kind, title: declaration.name, subtitle: subtitle,
                attributes: attributes, methods: methods, fileURL: fileURL
            )
            nodes.append(node)
            declared.append((declaration.name, declaration.heritage, node.id))
            collect(declaration.members, path: path, fileURL: fileURL, settings: settings, nodes: &nodes, declared: &declared)
        }
    }

    private static func appearance(of kind: TypeScriptFileModel.Kind) -> (IDEDiagramNodeKind, String) {
        switch kind {
        case .interface: (.interfaceType, "")
        case .enum: (.enumType, "")
        case .typeAlias: (.classType, "«type»")
        case .namespace: (.classType, "«namespace»")
        default: (.classType, "")
        }
    }

    /// `pkg.Foo<T>` is `Foo`. The model already stores a simple name; this still strips both.
    static func simpleName(_ raw: String) -> String {
        let withoutGenerics = raw.split(separator: "<", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = withoutGenerics.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: ".").last.map(String.init) ?? trimmed
    }
}
