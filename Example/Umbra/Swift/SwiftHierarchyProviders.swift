import EditorIntelligence
import Foundation

/// What a Swift hierarchy item points at, kept in `HierarchyItem.payload`.
struct SwiftHierarchyPayload: Sendable {
    var name: String
    var url: URL?
    var nameBytes: Range<Int>?
    var labels: [String]
    var owner: String?
}

/// Type hierarchy: what a type inherits or conforms to, and what the project has below it.
/// Extensions that add a conformance count toward the type they extend.
struct SwiftTypeHierarchyProvider: TypeHierarchyProviding {
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        if let fileURL { await index.noteOpenDocument(url: fileURL, text: source) }
        let byte = parsed.text.byteOffset(utf16: utf16Offset)
        guard let type = parsed.model.enclosingTypes(at: byte).last, !type.name.isEmpty else { return nil }
        let kind = await kindOf(type.name, file: fileURL, fallback: type.kind)
        return HierarchyItem(
            id: type.name, name: type.name, detail: fileURL?.lastPathComponent ?? "", kind: Self.itemKind(kind),
            origin: .project, payload: SwiftHierarchyPayload(name: type.name, url: fileURL, nameBytes: nil, labels: [], owner: nil)
        )
    }

    func supertypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        let names = await index.supertypes(of: item.name, visibleFrom: file)
        var items: [HierarchyItem] = []
        for name in names {
            let refs = await index.types(named: name, visibleFrom: file)
            if let ref = refs.first(where: { $0.declaration.kind != .typeAlias }) ?? refs.first {
                items.append(HierarchyItem(
                    id: "\(item.id)>\(name)", name: name, detail: ref.url.lastPathComponent,
                    kind: Self.itemKind(ref.declaration.kind), origin: .project,
                    payload: SwiftHierarchyPayload(name: name, url: ref.url, nameBytes: ref.declaration.nameBytes, labels: [], owner: nil)
                ))
            } else {
                // Declared outside the project: the standard library or a framework.
                items.append(HierarchyItem(
                    id: "\(item.id)>\(name)", name: name, kind: .interfaceType, origin: .runtime, badge: "SDK",
                    payload: SwiftHierarchyPayload(name: name, url: nil, nameBytes: nil, labels: [], owner: nil)
                ))
            }
        }
        return items
    }

    func subtypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        var items: [HierarchyItem] = []
        var seen = Set<String>()
        for ref in await index.subtypes(of: item.name, visibleFrom: file) {
            let name = ref.declaration.name
            guard seen.insert(name).inserted else { continue }
            let target = await index.types(named: name, visibleFrom: file).first { $0.declaration.kind != .extension } ?? ref
            items.append(HierarchyItem(
                id: "\(item.id)<\(name)", name: name, detail: target.url.lastPathComponent,
                kind: Self.itemKind(target.declaration.kind), origin: .project,
                payload: SwiftHierarchyPayload(name: name, url: target.url, nameBytes: target.declaration.nameBytes, labels: [], owner: nil)
            ))
        }
        return items.sorted { $0.name < $1.name }
    }

    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        guard let payload = item.payload as? SwiftHierarchyPayload else { return nil }
        let refs = await index.types(named: payload.name, visibleFrom: file)
        guard let ref = refs.first(where: { $0.declaration.kind != .typeAlias }) ?? refs.first,
              let source = await index.source(for: ref.url) else { return nil }
        let text = SourceTextMap(source)
        return HierarchyLocation(url: ref.url, range: text.range(bytes: ref.declaration.nameBytes))
    }

    private func kindOf(_ name: String, file: URL?, fallback: SwiftFileModel.Kind) async -> SwiftFileModel.Kind {
        await index.types(named: name, visibleFrom: file).first { $0.declaration.kind.isNominalType }?.declaration.kind ?? fallback
    }

    static func itemKind(_ kind: SwiftFileModel.Kind) -> HierarchyItemKind {
        switch kind {
        case .protocol: return .interfaceType
        case .enum: return .enumType
        case .function, .initializer, .subscript, .deinitializer: return .method
        default: return .classType
        }
    }
}

/// Call hierarchy: who calls a function, and what its body calls. A call counts when it resolves
/// to the function, so an unrelated function with the same name is not a caller.
struct SwiftCallHierarchyProvider: CallHierarchyProviding {
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        guard let parsed = SwiftAnalysis.parse(source) else { return nil }
        if let fileURL { await index.noteOpenDocument(url: fileURL, text: source) }
        let byte = parsed.text.byteOffset(utf16: utf16Offset)
        guard let member = parsed.model.enclosingMember(at: byte), member.kind == .function || member.kind == .initializer
        else { return nil }
        let owner = parsed.model.enclosingTypes(at: byte).last?.name
        return item(for: member, owner: owner, url: fileURL, parent: nil)
    }

    func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let payload = item.payload as? SwiftHierarchyPayload, let nameBytes = payload.nameBytes else { return [] }
        let identity = SwiftResolver.Target.declarationIdentity(url: payload.url, nameBytes: nameBytes, name: payload.name)
        var items: [HierarchyItem] = []
        var seen = Set<String>()
        var candidates = await index.candidateFiles(mentioning: payload.name)
        if let url = payload.url { candidates.insert(url.standardizedFileURL) }
        for url in candidates.sorted(by: { $0.path < $1.path }).prefix(400) {
            if Task.isCancelled { break }
            guard let source = await index.source(for: url), let parsed = SwiftAnalysis.parse(source) else { continue }
            let resolver = SwiftResolver(index: index, model: parsed.model, url: url)
            for use in parsed.model.uses where use.isCall && use.name == payload.name {
                guard let target = await resolver.target(forNameAt: use.bytes), target.identity == identity,
                      let caller = parsed.model.enclosingMember(at: use.bytes.lowerBound) else { continue }
                let owner = parsed.model.enclosingTypes(at: use.bytes.lowerBound).last?.name
                let key = "\(url.path):\(caller.nameBytes.lowerBound)"
                guard seen.insert(key).inserted else { continue }
                items.append(self.item(for: caller, owner: owner, url: url, parent: item))
            }
        }
        return items
    }

    func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let payload = item.payload as? SwiftHierarchyPayload, let url = payload.url,
              let nameBytes = payload.nameBytes,
              let source = await index.source(for: url), let parsed = SwiftAnalysis.parse(source),
              let declaration = parsed.model.declaration(atNameBytes: nameBytes) else { return [] }
        let resolver = SwiftResolver(index: index, model: parsed.model, url: url)
        var items: [HierarchyItem] = []
        var seen = Set<String>()
        for use in parsed.model.uses where use.isCall && declaration.bodyBytes.contains(use.bytes.lowerBound) {
            guard let target = await resolver.target(forNameAt: use.bytes),
                  case .declaration(let targetURL, let called, let owner) = target,
                  called.kind == .function || called.kind == .initializer else { continue }
            let key = target.identity ?? ""
            guard seen.insert(key).inserted else { continue }
            items.append(self.item(for: called, owner: owner, url: targetURL, parent: item))
        }
        return items
    }

    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        guard let payload = item.payload as? SwiftHierarchyPayload, let url = payload.url, let nameBytes = payload.nameBytes,
              let source = await index.source(for: url) else { return nil }
        return HierarchyLocation(url: url, range: SourceTextMap(source).range(bytes: nameBytes))
    }

    private func item(
        for declaration: SwiftFileModel.Declaration, owner: String?, url: URL?, parent: HierarchyItem?
    ) -> HierarchyItem {
        let labels = declaration.parameters.map { ($0.label ?? "_") + ":" }.joined()
        let name = declaration.kind == .initializer ? "init" : declaration.name
        return HierarchyItem(
            id: "\(parent?.id ?? "")/\(url?.path ?? ""):\(declaration.nameBytes.lowerBound)",
            name: "\(name)(\(labels))", detail: owner ?? url?.lastPathComponent ?? "", kind: .method, origin: .project,
            payload: SwiftHierarchyPayload(
                name: declaration.name, url: url, nameBytes: declaration.nameBytes,
                labels: declaration.parameters.map { $0.label ?? "_" }, owner: owner
            )
        )
    }
}
