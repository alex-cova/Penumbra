import EditorIntelligence
import Foundation
import LanguageSyntax

/// Definition, usages, implementations, super method and type definition for Swift, all through
/// the resolver: a name that cannot be tied to a declaration answers nothing rather than a guess.
public struct SwiftNavigationProvider: NavigationProvider {
    public let name = SwiftAnalysis.providerName
    private let index: SwiftIndex

    public init(index: SwiftIndex) {
        self.index = index
    }

    public func isPrimary(for context: NavigationContext) -> Bool {
        context.document.languageIdentifier == SwiftAnalysis.languageIdentifier
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard isPrimary(for: context) else { return nil }
        guard let parsed = await SwiftAnalysis.parse(document: context.document) else { return nil }
        if let url = context.document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        let resolver = SwiftResolver(index: index, model: parsed.model, url: context.document.url)
        switch context.kind {
        case .definition:
            guard let location = await definition(context, parsed: parsed, byte: byte, resolver: resolver) else { return nil }
            return .single(location)
        case .references:
            let locations = await references(context, parsed: parsed, byte: byte, resolver: resolver)
            return locations.isEmpty ? nil : .multiple(locations)
        case .implementation:
            let locations = await implementations(context, parsed: parsed, byte: byte, resolver: resolver)
            switch locations.count {
            case 0: return nil
            case 1: return .single(locations[0])
            default: return .multiple(locations)
            }
        case .superMethod:
            guard let location = await superMethod(context, parsed: parsed, byte: byte, resolver: resolver) else { return nil }
            return .single(location)
        case .typeDefinition:
            guard let location = await typeDefinition(context, parsed: parsed, byte: byte, resolver: resolver) else { return nil }
            return .single(location)
        }
    }

    // MARK: Target

    /// The symbol at the caret, with the expected type a leading-dot member needs.
    private func target(
        parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> (target: SwiftResolver.Target, node: SyntaxNode)? {
        guard let node = SwiftNames.name(atByte: byte, in: parsed.tree) else { return nil }
        var expected: String?
        if let use = parsed.model.use(at: node.byteRange), case .implicitMember = use.role {
            expected = await SwiftExpectedType.find(at: node.startByte, parsed: parsed, resolver: resolver)
        }
        guard let target = await resolver.target(forNameAt: node.byteRange, expected: expected) else { return nil }
        return (target, node)
    }

    private func definition(
        _ context: NavigationContext, parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> Location? {
        guard let found = await target(parsed: parsed, byte: byte, resolver: resolver) else { return nil }
        switch found.target {
        case .binding(let binding):
            guard !binding.nameBytes.isEmpty else { return nil }
            return SourceLocations.make(
                bytes: binding.nameBytes, text: parsed.text, document: context.document,
                file: context.document.url, name: binding.name, kind: "declaration"
            )
        case .declaration(let url, let declaration, _):
            return await location(of: declaration, in: url, parsed: parsed, document: context.document)
        case .module:
            return nil
        }
    }

    private func references(
        _ context: NavigationContext, parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> [Location] {
        guard let found = await target(parsed: parsed, byte: byte, resolver: resolver) else { return [] }
        let name: String
        switch found.target {
        case .binding(let binding): name = binding.name
        case .declaration(_, let declaration, _): name = declaration.kind == .initializer ? "init" : declaration.name
        case .module(let module): name = module
        }
        let finder = SwiftReferenceFinder(index: index)
        let files = await finder.find(found.target, name: name, current: parsed, currentURL: context.document.url)
        var locations: [Location] = []
        for file in files {
            for range in file.ranges {
                let isDeclaration = isDeclarationName(range, file: file, parsed: parsed, url: context.document.url, target: found.target)
                locations.append(SourceLocations.make(
                    bytes: range, text: file.text, document: context.document, file: file.url,
                    name: name, kind: isDeclaration ? "declaration" : "reference"
                ))
            }
        }
        return locations
    }

    private func isDeclarationName(
        _ range: Range<Int>, file: SwiftReferenceFinder.FileReferences, parsed: SwiftParsed, url: URL?,
        target: SwiftResolver.Target
    ) -> Bool {
        switch target {
        case .binding(let binding):
            return file.url == url && binding.nameBytes == range
        case .declaration(let declarationURL, let declaration, _):
            return declarationURL?.standardizedFileURL == file.url?.standardizedFileURL && declaration.nameBytes == range
        case .module:
            return false
        }
    }

    private func implementations(
        _ context: NavigationContext, parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> [Location] {
        var focus: SwiftResolver.Target?
        if let found = await target(parsed: parsed, byte: byte, resolver: resolver) {
            focus = found.target
        } else if let member = parsed.model.enclosingMember(at: byte) {
            let owner = parsed.model.enclosingTypes(at: byte).last?.name
            focus = .declaration(url: context.document.url, declaration: member, owner: owner)
        }
        guard case .declaration(_, let declaration, let owner)? = focus else { return [] }
        var locations: [Location] = []
        let file = context.document.url
        if declaration.kind.isNominalType {
            for ref in await index.subtypes(of: declaration.name, visibleFrom: file) {
                if ref.declaration.kind == .extension {
                    // A conformance added by an extension: the extension names the implementing type.
                    for type in await index.types(named: ref.declaration.name, visibleFrom: file) {
                        if let found = await location(of: type.declaration, in: type.url, parsed: parsed, document: context.document) {
                            locations.append(found)
                        }
                    }
                } else if let found = await location(of: ref.declaration, in: ref.url, parsed: parsed, document: context.document) {
                    locations.append(found)
                }
            }
            return dedupe(locations)
        }
        guard let owner, !owner.isEmpty, declaration.kind.isFunctionLike || declaration.kind == .property else { return [] }
        // A member of a protocol or class: the same member in each type below it.
        var queue = [owner]
        var seen: Set<String> = [owner]
        while !queue.isEmpty, seen.count < 200 {
            let current = queue.removeFirst()
            for ref in await index.subtypes(of: current, visibleFrom: file) {
                let typeName = ref.declaration.name
                guard seen.insert(typeName).inserted else { continue }
                queue.append(typeName)
                let members = await index.members(ofType: typeName, visibleFrom: file)
                for member in members where member.declaration.name == declaration.name
                    && sameLabels(member.declaration, declaration) && member.owner == typeName {
                    if let found = await location(of: member.declaration, in: member.url, parsed: parsed, document: context.document) {
                        locations.append(found)
                    }
                }
            }
        }
        return dedupe(locations)
    }

    private func superMethod(
        _ context: NavigationContext, parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> Location? {
        var member: SwiftFileModel.Declaration?
        var owner: String?
        if let found = await target(parsed: parsed, byte: byte, resolver: resolver),
           case .declaration(_, let declaration, let type) = found.target {
            member = declaration
            owner = type
        }
        if member == nil || owner == nil || !(member?.kind.isFunctionLike ?? false) && member?.kind != .property {
            member = parsed.model.enclosingMember(at: byte)
            owner = parsed.model.enclosingTypes(at: byte).last?.name
        }
        guard let member, let owner, !owner.isEmpty else { return nil }
        let file = context.document.url
        var queue = await index.supertypes(of: owner, visibleFrom: file)
        var seen: Set<String> = [owner]
        while !queue.isEmpty, seen.count < 64 {
            let current = queue.removeFirst()
            guard seen.insert(current).inserted else { continue }
            for ref in await index.members(ofType: current, visibleFrom: file)
            where ref.declaration.name == member.name && ref.owner == current && sameLabels(ref.declaration, member) {
                return await location(of: ref.declaration, in: ref.url, parsed: parsed, document: context.document)
            }
            queue.append(contentsOf: await index.supertypes(of: current, visibleFrom: file))
        }
        return nil
    }

    private func typeDefinition(
        _ context: NavigationContext, parsed: SwiftParsed, byte: Int, resolver: SwiftResolver
    ) async -> Location? {
        guard let found = await target(parsed: parsed, byte: byte, resolver: resolver) else { return nil }
        var typeName: String?
        switch found.target {
        case .binding(let binding):
            typeName = binding.typeName
            if typeName == nil {
                let chain = SwiftChain(base: .name(binding.name, at: binding.scopeStart), steps: [])
                typeName = await resolver.typeName(of: chain, at: binding.scopeStart)
            }
        case .declaration(_, let declaration, let owner):
            typeName = declaration.typeName.map { SwiftResolver.replacingSelf($0, with: owner) }
            if typeName == nil, declaration.kind == .property, let chain = declaration.valueChain {
                typeName = await resolver.typeName(of: chain, at: declaration.fullBytes.lowerBound)
            }
            if declaration.kind.isTypeLike { typeName = declaration.name }
        case .module:
            return nil
        }
        guard let typeName else { return nil }
        let stripped = SwiftTypeNames.unwrappedOptional(SwiftTypeNames.elementType(of: typeName) ?? typeName)
        guard let ref = await index.types(named: stripped, visibleFrom: context.document.url).first else { return nil }
        return await location(of: ref.declaration, in: ref.url, parsed: parsed, document: context.document)
    }

    // MARK: Locations

    private func sameLabels(_ lhs: SwiftFileModel.Declaration, _ rhs: SwiftFileModel.Declaration) -> Bool {
        lhs.parameters.map { $0.label ?? "_" } == rhs.parameters.map { $0.label ?? "_" }
    }

    private func dedupe(_ locations: [Location]) -> [Location] {
        var seen = Set<String>()
        return locations.filter { location in
            seen.insert("\(location.url?.path ?? ""):\(location.range.start.utf16Offset)").inserted
        }
    }

    private func location(
        of declaration: SwiftFileModel.Declaration, in url: URL?, parsed: SwiftParsed, document: Document
    ) async -> Location? {
        guard !declaration.nameBytes.isEmpty else { return nil }
        let isCurrent = url == nil || url?.standardizedFileURL == document.url?.standardizedFileURL
        if isCurrent {
            return SourceLocations.make(
                bytes: declaration.nameBytes, text: parsed.text, document: document, file: document.url,
                name: declaration.name, kind: "declaration"
            )
        }
        guard let url, let source = await index.source(for: url) else { return nil }
        return SourceLocations.make(
            bytes: declaration.nameBytes, text: SourceTextMap(source), document: document, file: url,
            name: declaration.name, kind: "declaration"
        )
    }
}
