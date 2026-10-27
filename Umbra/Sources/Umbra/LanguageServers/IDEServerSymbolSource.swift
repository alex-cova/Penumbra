import EditorIntelligence
import EditorIntelligenceLSP
import Foundation
import Penumbra

/// One symbol a language server reported for `workspace/symbol`, as a palette row needs it.
struct IDEServerSymbol: Equatable, Sendable {
    var name: String
    /// The LSP `SymbolKind` case name: `struct`, `method`, `function`, `enumMember`.
    var kind: String
    var url: URL
    /// As the server sent them: a zero-based line and a UTF-16 offset in it.
    var line: Int
    var character: Int
    var container: String?
}

/// Search Everywhere's Symbols section and Go to Symbol (`@`) from a connected language server's
/// `workspace/symbol`, which knows the project's index and not just the files the native index read.
///
/// While the server is connected and has an answer, that answer is the section. Otherwise the native
/// source answers: the server is not connected or trusted, has not finished indexing (it answers
/// nothing until it has), does not support the request, or the query is empty (an empty query asks
/// the server for everything, and it returns nothing for it).
final class IDEServerSymbolSource: SearchEverywhereProvider, @unchecked Sendable {
    let sectionTitle = "Symbols"
    private let connection: any LSPConnectionProviding
    private let fallback: any SearchEverywhereProvider
    private let onOpen: @MainActor @Sendable (_ url: URL, _ line: Int, _ character: Int, _ inRightSplit: Bool) -> Void

    init(
        connection: any LSPConnectionProviding,
        fallback: any SearchEverywhereProvider,
        onOpen: @escaping @MainActor @Sendable (_ url: URL, _ line: Int, _ character: Int, _ inRightSplit: Bool) -> Void
    ) {
        self.connection = connection
        self.fallback = fallback
        self.onOpen = onOpen
    }

    func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let client = connection.current as? LanguageServerClient,
           let outline = try? await client.requestWorkspaceSymbols(matching: trimmed) {
            if Task.isCancelled { return [] }
            let symbols = Self.symbols(from: outline, limit: limit)
            if !symbols.isEmpty { return rows(for: symbols, query: trimmed, limit: limit) }
        }
        if Task.isCancelled { return [] }
        return await fallback.items(matching: query, limit: limit)
    }

    private func rows(for symbols: [IDEServerSymbol], query: String, limit: Int) -> [PaletteItem] {
        let onOpen = self.onOpen
        return symbols.enumerated().map { rank, symbol in
            let presentation = Self.presentation(ofKind: symbol.kind)
            return PaletteItem(
                id: "lsp:\(symbol.url.path)#\(symbol.line):\(symbol.character):\(symbol.name)",
                title: symbol.name,
                sectionTitle: sectionTitle,
                matchedIndices: CompletionMatcher.match(query, in: symbol.name)?.matchedOffsets ?? [],
                // The server's order is its ranking; the rows keep it.
                score: limit - rank,
                action: { onOpen(symbol.url, symbol.line, symbol.character, false) },
                icon: PaletteIcon(systemName: presentation.symbol, tint: presentation.tint),
                location: symbol.container.flatMap { $0.isEmpty ? nil : $0 } ?? symbol.url.lastPathComponent,
                trailing: presentation.title,
                footer: symbol.url.path,
                alternateAction: { onOpen(symbol.url, symbol.line, symbol.character, true) }
            )
        }
    }

    /// The server's symbols that name a place in a file, in the server's order, at most `limit`.
    static func symbols(from outline: [LSPOutlineSymbol], limit: Int) -> [IDEServerSymbol] {
        let symbols: [IDEServerSymbol] = outline.compactMap { symbol in
            guard let uri = symbol.uri, let url = URL(string: uri), url.isFileURL else { return nil }
            return IDEServerSymbol(
                name: symbol.name, kind: symbol.kind, url: url,
                line: symbol.range.start.line, character: symbol.range.start.character, container: symbol.detail
            )
        }
        return Array(symbols.prefix(max(limit, 0)))
    }

    static func presentation(ofKind kind: String) -> (title: String, symbol: String, tint: PaletteIcon.Tint) {
        switch kind {
        case "class": ("Class", "c.square.fill", .purple)
        case "struct": ("Struct", "s.square.fill", .purple)
        case "interface": ("Protocol", "p.square.fill", .blue)
        case "enum": ("Enum", "e.square.fill", .orange)
        case "enumMember": ("Case", "e.square.fill", .orange)
        case "typeParameter": ("Type", "t.square.fill", .purple)
        case "function": ("Function", "f.square.fill", .secondary)
        case "method", "constructor", "operator": ("Member", "m.square.fill", .secondary)
        case "property", "field", "variable", "constant": ("Property", "v.square.fill", .blue)
        case "module", "namespace", "package", "file": ("Module", "shippingbox.fill", .secondary)
        default: ("Symbol", "number.square.fill", .secondary)
        }
    }
}
