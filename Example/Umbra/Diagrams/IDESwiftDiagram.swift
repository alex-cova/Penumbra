import Foundation

/// One Swift file's types as a class diagram. An extension is folded into the type it extends when
/// that type is in the file; one for a type declared elsewhere is its own box. Conformances are
/// realizations, a class's superclass an inheritance edge.
enum IDESwiftDiagram {
    static func document(
        model: SwiftFileModel, fileURL: URL, title: String, settings: IDEDiagramSettings
    ) -> IDEDiagramDocument {
        let path = fileURL.standardizedFileURL.path
        var nodes: [IDEDiagramNode] = []
        var declared: [(name: String, inherits: [String], id: UUID, isProtocolEdge: Set<String>)] = []
        var protocols = Set<String>()
        func gather(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations where declaration.kind == .protocol { protocols.insert(declaration.name) }
            for declaration in declarations where declaration.kind.isNominalType || declaration.kind == .extension {
                gather(declaration.members)
            }
        }
        gather(model.declarations)

        var byName: [String: Int] = [:]
        func collect(_ declarations: [SwiftFileModel.Declaration]) {
            for declaration in declarations {
                guard declaration.kind.isNominalType || declaration.kind == .extension else { continue }
                if declaration.access <= .fileprivate, !settings.showPrivateMembers { continue }
                if declaration.kind == .extension, let existing = byName[declaration.name] {
                    // Folded: the extension's members and conformances join the type's box.
                    fold(declaration, into: existing)
                } else {
                    let (kind, subtitle) = appearance(of: declaration)
                    let attributes = settings.showMembers ? members(of: declaration, properties: true, settings: settings) : []
                    let methods = settings.showMembers ? members(of: declaration, properties: false, settings: settings) : []
                    let node = IDEDiagramNode(
                        key: "swift:\(path)#\(declaration.nameBytes.lowerBound)",
                        kind: kind, title: declaration.name, subtitle: subtitle,
                        attributes: attributes, methods: methods, fileURL: fileURL
                    )
                    nodes.append(node)
                    if byName[declaration.name] == nil { byName[declaration.name] = nodes.count - 1 }
                    declared.append((declaration.name, declaration.inherits, node.id, []))
                }
                collect(declaration.members)
            }
        }
        func fold(_ declaration: SwiftFileModel.Declaration, into nodeIndex: Int) {
            let extra = settings.showMembers
                ? members(of: declaration, properties: true, settings: settings) : []
            let extraMethods = settings.showMembers
                ? members(of: declaration, properties: false, settings: settings) : []
            nodes[nodeIndex].attributes.append(contentsOf: extra)
            nodes[nodeIndex].methods.append(contentsOf: extraMethods)
            if let entry = declared.firstIndex(where: { $0.id == nodes[nodeIndex].id }) {
                declared[entry].inherits.append(contentsOf: declaration.inherits)
            }
        }
        // Types before the extensions that fold into them, whatever their order in the file.
        let ordered = model.declarations.filter { $0.kind != .extension } + model.declarations.filter { $0.kind == .extension }
        collect(ordered)

        var idByName: [String: UUID] = [:]
        for entry in declared where idByName[entry.name] == nil { idByName[entry.name] = entry.id }
        var edges: [IDEDiagramEdge] = []
        var externalIDs: [String: UUID] = [:]
        for entry in declared {
            for name in entry.inherits where name != entry.name {
                let destination: UUID
                if let known = idByName[name] {
                    destination = known
                } else if settings.showExternalTypes {
                    if let existing = externalIDs[name] {
                        destination = existing
                    } else {
                        let node = IDEDiagramNode(key: "swift-external:\(name)", kind: .externalType, title: name)
                        nodes.append(node)
                        externalIDs[name] = node.id
                        destination = node.id
                    }
                } else {
                    continue
                }
                // A name the file declares as a protocol, or an unknown capitalized `…able`/`…Protocol`,
                // is a conformance; a class's first unknown supertype is its superclass.
                let isConformance = protocols.contains(name) || name.hasSuffix("able") || name.hasSuffix("Protocol")
                edges.append(IDEDiagramEdge(
                    sourceID: entry.id, destinationID: destination, kind: isConformance ? .realization : .inheritance
                ))
            }
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }

    private static func members(
        of declaration: SwiftFileModel.Declaration, properties: Bool, settings: IDEDiagramSettings
    ) -> [String] {
        var lines: [String] = []
        for member in declaration.members {
            if member.access <= .fileprivate, !settings.showPrivateMembers { continue }
            switch member.kind {
            case .property where properties:
                lines.append(member.signature)
            case .enumCase where properties:
                lines.append(member.signature)
            case .function where !properties, .initializer where !properties:
                lines.append(member.signature)
            default:
                break
            }
        }
        return lines
    }

    private static func appearance(of declaration: SwiftFileModel.Declaration) -> (IDEDiagramNodeKind, String) {
        switch declaration.kind {
        case .protocol: return (.interfaceType, "")
        case .enum: return (.enumType, "")
        case .struct: return (.recordType, "«struct»")
        case .actor: return (.classType, "«actor»")
        case .extension: return (.classType, "«extension»")
        default: return (.classType, "")
        }
    }
}
