import EditorIntelligence
import Foundation
import JavaIntelligence

/// Renames a local, a parameter, or a project declaration with every use that resolves to it.
/// Nothing the project does not declare is renamed, and a member use whose receiver cannot be
/// typed is left alone (the preview lists what was changed).
struct SwiftRenameProvider: RenameProviding {
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
        guard let target = await target(for: context) else { return nil }
        return RenameTarget(
            range: target.range, currentName: target.name, kindDescription: target.kind,
            validate: Self.validate
        )
    }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        guard let target = await target(for: context) else {
            return RenamePlan(blockingError: "Nothing to rename")
        }
        if let problem = Self.validate(newName) { return RenamePlan(blockingError: problem) }
        let finder = SwiftReferenceFinder(index: index)
        var entries: [WorkspaceEditPlanEntry] = []
        var seen = Set<String>()
        // The member and every override, implementation and sibling of it: renaming one of them
        // alone would leave a build that does not compile.
        let symbols = [target.symbol] + (await family(of: target.symbol, file: context.document.url))
        for symbol in symbols {
            if Task.isCancelled { break }
            let files = await finder.find(symbol, name: target.name, current: target.parsed, currentURL: context.document.url)
            for file in files {
                guard let url = file.url else { continue }
                for range in file.ranges {
                    let key = url.standardizedFileURL.path + ":\(range.lowerBound)"
                    guard seen.insert(key).inserted else { continue }
                    entries.append(SourceLocations.edit(
                        bytes: range, text: file.text, url: url, oldName: target.name, newName: newName
                    ))
                }
            }
        }
        if entries.isEmpty { return RenamePlan(blockingError: "No occurrences were found to rename") }
        return RenamePlan(entries: entries)
    }

    /// The same member declared by the types above and below the one it was found on: an overridden
    /// method, a protocol requirement and its implementations, and what the siblings implement.
    private func family(of symbol: SwiftResolver.Target, file: URL?) async -> [SwiftResolver.Target] {
        guard case .declaration(_, let declaration, let owner?) = symbol, !owner.isEmpty,
              declaration.kind == .function || declaration.kind == .property else { return [] }
        let labels = declaration.parameters.map { $0.label ?? "_" }
        func matches(_ member: SwiftFileModel.Declaration) -> Bool {
            member.kind == declaration.kind && member.name == declaration.name
                && member.parameters.map { $0.label ?? "_" } == labels
        }
        // Every type above the owner.
        var above: [String] = []
        var queue = await index.supertypes(of: owner, visibleFrom: file)
        var seen: Set<String> = [owner]
        while !queue.isEmpty, seen.count < 64 {
            let name = queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            above.append(name)
            queue.append(contentsOf: await index.supertypes(of: name, visibleFrom: file))
        }
        // Those, the owner, and everything below any of them.
        var typeNames = [owner] + above
        for name in [owner] + above {
            for descendant in await index.descendants(of: name, visibleFrom: file) {
                typeNames.append(descendant.declaration.name)
            }
        }
        var found: [SwiftResolver.Target] = []
        var identities: Set<String> = [symbol.identity ?? ""]
        for name in Set(typeNames) {
            for ref in await index.declaredMembers(ofType: name, visibleFrom: file) where matches(ref.declaration) {
                let target = SwiftResolver.Target.declaration(url: ref.url, declaration: ref.declaration, owner: name)
                if let identity = target.identity, identities.insert(identity).inserted { found.append(target) }
            }
        }
        return found
    }

    private struct RenameSymbol {
        var parsed: SwiftParsed
        var symbol: SwiftResolver.Target
        var range: EditorIntelligence.TextRange
        var name: String
        var kind: String
    }

    private func target(for context: NavigationContext) async -> RenameSymbol? {
        guard context.document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return nil }
        guard let parsed = SwiftAnalysis.parse(document: context.document) else { return nil }
        if let url = context.document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let node = SwiftNames.name(atByte: byte, in: parsed.tree), !SwiftNames.inCommentOrString(node) else { return nil }
        let resolver = SwiftResolver(index: index, model: parsed.model, url: context.document.url)
        var expected: String?
        if let use = parsed.model.use(at: node.byteRange), case .implicitMember = use.role {
            expected = await SwiftExpectedType.find(at: node.startByte, parsed: parsed, resolver: resolver)
        }
        guard let symbol = await resolver.target(forNameAt: node.byteRange, expected: expected) else { return nil }
        let kind: String
        switch symbol {
        case .module:
            return nil
        case .binding(let binding):
            guard !binding.nameBytes.isEmpty else { return nil }
            switch binding.symbolKind {
            case .parameter: kind = "parameter"
            case .local: kind = "variable"
            case .function: kind = "function"
            case .type: kind = "type"
            }
        case .declaration(let url, let declaration, _):
            // Only what the project declares: a symbol found through an unindexed file has no url.
            guard url != nil || declaration.isTopLevel || !declaration.nameBytes.isEmpty else { return nil }
            switch declaration.kind {
            case .initializer, .deinitializer, .subscript, .extension: return nil
            case .function: kind = declaration.isTopLevel ? "function" : "method"
            case .property: kind = "property"
            case .enumCase: kind = "enum case"
            case .class: kind = "class"
            case .struct: kind = "struct"
            case .enum: kind = "enum"
            case .actor: kind = "actor"
            case .protocol: kind = "protocol"
            case .typeAlias: kind = "type alias"
            case .associatedType: kind = "associated type"
            }
        }
        let name: String
        switch symbol {
        case .binding(let binding): name = binding.name
        case .declaration(_, let declaration, _): name = declaration.name
        case .module(let module): name = module
        }
        if name.hasPrefix("$") { return nil }
        return RenameSymbol(
            parsed: parsed, symbol: symbol, range: parsed.text.range(bytes: node.byteRange), name: name, kind: kind
        )
    }

    private static let reserved: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "init", "deinit", "subscript",
        "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "return", "break", "continue",
        "import", "in", "is", "as", "try", "throw", "throws", "self", "super", "nil", "true", "false", "typealias",
        "associatedtype", "operator", "where", "do", "catch", "defer", "static", "public", "private", "internal",
        "fileprivate", "open", "inout"
    ]

    @Sendable
    static func validate(_ name: String) -> String? {
        if let problem = RenameTarget.validateIdentifier(name) { return problem }
        if name.hasPrefix("$") { return "A name cannot start with $" }
        if reserved.contains(name) { return "“\(name)” is a Swift keyword" }
        return nil
    }
}
