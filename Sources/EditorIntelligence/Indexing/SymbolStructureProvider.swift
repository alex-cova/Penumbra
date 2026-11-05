import Foundation

/// An outline built from the workspace symbol index for languages with no dedicated
/// ``StructureProviding``.
///
/// This is the structure half of the F-16 fan-out: the index already holds every declaration the
/// tree-sitter parse extracted (the same symbols completion and the ⌘F12 file-structure popup
/// read), so a language without a hand-written provider gets an outline with no new parse. The
/// trade is staleness — the index refreshes on the workspace settle, so this outline can lag the
/// live text by one index cycle — which beats the "No outline for this file" it replaces.
///
/// The text-only protocol requirements (no `document`) return nil: without a document identity
/// there is no index shard to read and nothing to parse.
public struct SymbolStructureProvider: StructureProviding, Sendable {
    /// Declaration kinds worth outlining; bare words, imports and file names stay out, matching
    /// the File Structure popup's fallback.
    static let declarationKinds: Set<SymbolKind> = [.function, .type, .variable, .property]

    private let index: SymbolIndex
    /// The shared workbench parser (the same per-language actors the indexer reads through) for
    /// the read-through below. Nil keeps the provider a pure index read.
    private let parser: (any LanguageParser)?

    public init(index: SymbolIndex, parser: (any LanguageParser)? = nil) {
        self.index = index
        self.parser = parser
    }

    public func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
        nil
    }

    public func allStructure(forSource source: String) async -> [StructureNode]? {
        nil
    }

    public func structure(
        forSource source: String, document: Document?, atUTF16Offset utf16Offset: Int
    ) async -> StructureNode? {
        guard let roots = await allStructure(forSource: source, document: document), !roots.isEmpty else {
            return nil
        }
        for root in roots {
            if root.bodyRange.contains(utf16Offset) || root.bodyRange.upperBound == utf16Offset {
                return root.deepestNode(containing: utf16Offset)
            }
        }
        // Outside every body the first top-level type answers, per the protocol contract.
        return roots[0]
    }

    public func allStructure(forSource source: String, document: Document?) async -> [StructureNode]? {
        guard let document else { return nil }
        // Fast path: the indexer already parsed this snapshot. Zero parses, by construction.
        // A nil here also covers a stale words-only shard: the live text may declare since.
        let indexed = await index.symbols(in: document.id)
        if let nodes = Self.nodes(from: indexed) {
            return nodes
        }
        // Read-through: the tab opened before the index landed (open-then-show races the
        // workspace event), or the bridged document is still elided (file-backed snapshots carry
        // no text until the buffer loads). Parse `source` — the live settle text — under the
        // document's stable id through the shared parser the indexer reads, so the snapshot is
        // still parsed once: whoever runs first warms the per-snapshot cache and the other hits
        // `entry.text == text`. Without a parser there is nothing to read through.
        guard let parser else { return nil }
        let live = Document(
            id: document.id,
            url: document.url,
            displayName: document.displayName,
            contentSnapshot: TextSnapshot(version: document.version, text: source),
            selection: document.selection,
            cursor: document.cursor,
            viewport: document.viewport,
            languageIdentifier: document.languageIdentifier
        )
        let tree = await parser.parse(document: live)
        return Self.nodes(from: tree.symbols)
    }

    /// Declaration symbols of `symbols` in source order, nested, or nil when there are none.
    static func nodes(from symbols: [Symbol]) -> [StructureNode]? {
        let declarations = symbols
            .filter { Self.declarationKinds.contains($0.kind) }
            .sorted { $0.range.start.utf16Offset < $1.range.start.utf16Offset }
        guard !declarations.isEmpty else { return nil }
        return Self.roots(from: declarations)
    }

    /// Nest `symbols` (in source order) into a forest via `containerRange` containment: each symbol
    /// joins the smallest body that holds its name. A function nested under a type is a method.
    /// Same-span declarations (a module root and its only child) contain each other, so parent
    /// links that close a cycle are dropped, earliest in source order first: every symbol still
    /// shows, and the forest always has a root.
    static func roots(from symbols: [Symbol]) -> [StructureNode] {
        var nodesByID: [UUID: NodeBuilder] = [:]
        for symbol in symbols {
            nodesByID[symbol.id] = NodeBuilder(symbol: symbol)
        }
        var parent: [UUID: UUID] = [:]
        for symbol in symbols {
            if let container = smallestContainer(of: symbol, in: symbols) {
                parent[symbol.id] = container.id
            }
        }
        for symbol in symbols {
            var seen = Set<UUID>()
            var current: UUID? = symbol.id
            while let id = current, let next = parent[id] {
                if next == symbol.id || seen.contains(next) {
                    parent[symbol.id] = nil
                    break
                }
                seen.insert(id)
                current = next
            }
        }
        var childIDs = Set<UUID>()
        for symbol in symbols {
            if let parentID = parent[symbol.id] {
                nodesByID[parentID]?.children.append(symbol.id)
                childIDs.insert(symbol.id)
            }
        }
        // Children keep first-nested order, which is source order: parents are assigned in the
        // same pass that visits symbols sorted by name offset.
        return symbols
            .filter { !childIDs.contains($0.id) }
            .compactMap { nodesByID[$0.id]?.build(parentKind: nil, builders: nodesByID) }
    }

    /// The symbol with the smallest body that holds `symbol`'s name and is not `symbol` itself.
    private static func smallestContainer(of symbol: Symbol, in symbols: [Symbol]) -> Symbol? {
        let nameOffset = symbol.range.start.utf16Offset
        var best: Symbol?
        var bestWidth = Int.max
        for candidate in symbols {
            guard candidate.id != symbol.id else { continue }
            guard let body = candidate.containerRange else { continue }
            let bodyRange = body.start.utf16Offset..<body.end.utf16Offset
            guard bodyRange.contains(nameOffset) else { continue }
            let width = bodyRange.count
            if width < bestWidth {
                bestWidth = width
                best = candidate
            }
        }
        return best
    }

    private final class NodeBuilder {
        let symbol: Symbol
        var children: [UUID] = []

        init(symbol: Symbol) {
            self.symbol = symbol
        }

        func build(parentKind: SymbolKind?, builders: [UUID: NodeBuilder]) -> StructureNode {
            let kind = Self.structureKind(for: symbol.kind, parentKind: parentKind)
            let nameRange = symbol.range.start.utf16Offset..<symbol.range.end.utf16Offset
            let body: Range<Int>
            if let container = symbol.containerRange {
                body = container.start.utf16Offset..<container.end.utf16Offset
            } else {
                body = nameRange
            }
            let builtChildren = children.compactMap { builders[$0]?.build(parentKind: symbol.kind, builders: builders) }
            return StructureNode(
                id: "symbol:\(symbol.id.uuidString)",
                title: symbol.name,
                kind: kind,
                nameRange: nameRange,
                bodyRange: body,
                children: builtChildren
            )
        }

        private static func structureKind(for kind: SymbolKind, parentKind: SymbolKind?) -> StructureKind {
            switch kind {
            case .type:
                return .type
            case .function:
                // A free tree-sitter function declared inside a type is a method of that type.
                return parentKind == .type ? .method : .function
            case .property:
                return .field
            case .variable:
                return .variable
            case .importStatement, .fileName, .word, .unknown:
                return .variable
            }
        }
    }
}
