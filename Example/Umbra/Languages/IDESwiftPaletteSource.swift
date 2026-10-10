import EditorIntelligence
import Foundation
import Penumbra

/// Swift types and their members for the Symbols tab, read from the in-memory index. It is
/// appended after Java's members and does not walk the disk.
final class IDESwiftPaletteSource: SearchEverywhereProvider, @unchecked Sendable {
    let sectionTitle = "Symbols"
    let index: SwiftIndex
    let onOpen: @MainActor @Sendable (URL, Range<Int>, Bool) -> Void

    init(index: SwiftIndex, onOpen: @escaping @MainActor @Sendable (URL, Range<Int>, Bool) -> Void) {
        self.index = index
        self.onOpen = onOpen
    }

    func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let matches = await index.symbols(matching: query, limit: limit)
        guard !matches.isEmpty else { return [] }
        let onOpen = self.onOpen
        return matches.enumerated().map { rank, symbol in
            let kind = Self.presentation(of: symbol.kind)
            return PaletteItem(
                id: "swift:\(symbol.url.path)#\(symbol.nameBytes.lowerBound)",
                title: symbol.name,
                sectionTitle: sectionTitle,
                matchedIndices: CompletionMatcher.match(query, in: symbol.name)?.matchedOffsets ?? [],
                score: limit - rank,
                action: { onOpen(symbol.url, symbol.nameBytes, false) },
                icon: PaletteIcon(systemName: kind.symbol, tint: kind.tint),
                location: symbol.container.isEmpty ? symbol.url.lastPathComponent : symbol.container,
                trailing: kind.title,
                footer: symbol.url.path,
                alternateAction: { onOpen(symbol.url, symbol.nameBytes, true) }
            )
        }
    }

    private static func presentation(of kind: SwiftFileModel.Kind) -> (title: String, symbol: String, tint: PaletteIcon.Tint) {
        switch kind {
        case .class, .actor: ("Class", "c.square.fill", .purple)
        case .struct: ("Struct", "s.square.fill", .purple)
        case .protocol: ("Protocol", "p.square.fill", .blue)
        case .enum: ("Enum", "e.square.fill", .orange)
        case .typeAlias, .associatedType: ("Type", "t.square.fill", .purple)
        case .function: ("Function", "f.square.fill", .secondary)
        case .property: ("Property", "v.square.fill", .blue)
        case .enumCase: ("Case", "e.square.fill", .orange)
        case .extension, .initializer, .deinitializer, .subscript: ("Member", "m.square.fill", .secondary)
        }
    }
}
