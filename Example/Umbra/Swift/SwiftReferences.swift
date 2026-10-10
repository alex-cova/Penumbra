import EditorIntelligence
import Foundation

/// Every place a name refers to one symbol, for Find Usages and Rename.
///
/// A use counts only when it resolves to the symbol: a member whose receiver cannot be typed is
/// left out, so a rename touches less than a text search would, never something else.
struct SwiftReferenceFinder: Sendable {
    struct FileReferences: Sendable {
        var url: URL?
        var text: SourceTextMap
        var ranges: [Range<Int>]
    }

    let index: SwiftIndex
    /// The most files a search reads. A name that appears in more than this is too common to follow.
    private let maximumFiles = 600

    init(index: SwiftIndex) {
        self.index = index
    }

    /// - Parameters:
    ///   - target: what to find.
    ///   - name: the symbol's name as written.
    ///   - current: the parsed file the request came from and where it lives.
    func find(
        _ target: SwiftResolver.Target, name: String, current: SwiftParsed, currentURL: URL?
    ) async -> [FileReferences] {
        guard let identity = target.identity else { return [] }
        var results: [FileReferences] = []

        let currentRanges = await ranges(
            in: current, url: currentURL, name: name, identity: identity, includeDeclaration: true
        )
        if !currentRanges.isEmpty {
            results.append(FileReferences(url: currentURL, text: current.text, ranges: currentRanges))
        }
        guard reachesOtherFiles(target) else { return results }

        var candidates = await index.candidateFiles(mentioning: name)
        candidates.remove(currentURL?.standardizedFileURL ?? URL(fileURLWithPath: "/"))
        for url in candidates.sorted(by: { $0.path < $1.path }).prefix(maximumFiles) {
            if Task.isCancelled { break }
            guard let source = await index.source(for: url), let parsed = SwiftAnalysis.parse(source) else { continue }
            let found = await ranges(in: parsed, url: url, name: name, identity: identity, includeDeclaration: true)
            if !found.isEmpty { results.append(FileReferences(url: url, text: parsed.text, ranges: found)) }
        }
        return results
    }

    /// A local, or a private declaration, cannot be named from another file.
    private func reachesOtherFiles(_ target: SwiftResolver.Target) -> Bool {
        switch target {
        case .binding:
            return false
        case .module:
            return true
        case .declaration(_, let declaration, _):
            return declaration.access > .fileprivate
        }
    }

    private func ranges(
        in parsed: SwiftParsed, url: URL?, name: String, identity: String, includeDeclaration: Bool
    ) async -> [Range<Int>] {
        let resolver = SwiftResolver(index: index, model: parsed.model, url: url)
        var found: [Range<Int>] = []
        var seen = Set<Int>()
        func add(_ bytes: Range<Int>) {
            if seen.insert(bytes.lowerBound).inserted { found.append(bytes) }
        }
        if includeDeclaration {
            for binding in parsed.model.bindings where binding.name == name && !binding.nameBytes.isEmpty {
                if SwiftResolver.Target.binding(binding).identity == identity { add(binding.nameBytes) }
            }
            func visit(_ declarations: [SwiftFileModel.Declaration], owner: String?) {
                for declaration in declarations {
                    if declaration.name == name, !declaration.nameBytes.isEmpty {
                        let target = SwiftResolver.Target.declaration(
                            url: url, declaration: declaration, owner: declaration.isTopLevel ? nil : owner
                        )
                        if target.identity == identity { add(declaration.nameBytes) }
                    }
                    if declaration.kind.isNominalType || declaration.kind == .extension {
                        visit(declaration.members, owner: declaration.name)
                    }
                }
            }
            visit(parsed.model.declarations, owner: nil)
        }
        for use in parsed.model.uses where use.name == name {
            if Task.isCancelled { break }
            var expected: String?
            if case .implicitMember = use.role {
                expected = await SwiftExpectedType.find(at: use.bytes.lowerBound, parsed: parsed, resolver: resolver)
            }
            guard let target = await resolver.target(forNameAt: use.bytes, expected: expected) else { continue }
            if target.identity == identity { add(use.bytes) }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }
}
