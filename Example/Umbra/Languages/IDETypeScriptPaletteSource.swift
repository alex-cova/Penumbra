import EditorIntelligence
import Foundation
import Penumbra

/// TypeScript types and their members for the Symbols tab, read from the in-memory index.
/// Java's members are listed first; this source is appended and does not walk the disk.
final class IDETypeScriptPaletteSource: SearchEverywhereProvider, @unchecked Sendable {
    let sectionTitle = "Symbols"
    let index: TypeScriptIndex
    let onOpen: @MainActor @Sendable (URL, Range<Int>, Bool) -> Void

    init(index: TypeScriptIndex, onOpen: @escaping @MainActor @Sendable (URL, Range<Int>, Bool) -> Void) {
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
                id: "ts:\(symbol.url.path)#\(symbol.nameBytes.lowerBound)",
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

    private static func presentation(of kind: TypeScriptFileModel.Kind) -> (title: String, symbol: String, tint: PaletteIcon.Tint) {
        switch kind {
        case .class: ("Class", "c.square.fill", .purple)
        case .interface: ("Interface", "i.square.fill", .blue)
        case .enum: ("Enum", "e.square.fill", .orange)
        case .typeAlias: ("Type", "t.square.fill", .purple)
        case .namespace: ("Namespace", "n.square.fill", .secondary)
        case .method: ("Method", "m.square.fill", .purple)
        case .field: ("Field", "f.square.fill", .blue)
        case .enumMember: ("Enum Member", "e.square.fill", .orange)
        case .function: ("Function", "f.square.fill", .secondary)
        case .variable: ("Variable", "v.square.fill", .secondary)
        }
    }
}
