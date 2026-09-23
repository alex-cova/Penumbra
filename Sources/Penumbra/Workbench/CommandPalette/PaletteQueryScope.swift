import Foundation

/// Resolves what a command palette's raw query string means: either an explicit sigil prefix
/// overriding the current mode, or the current ``EditorPaletteMode`` when there's no prefix.
public enum PaletteQueryScope: Equatable {
    case commands(String)
    case files(String)
    case symbols(String)
    /// In-buffer text search — Sublime's `#`.
    case text(String)
    /// Go to line — Sublime's `:`.
    case line(String)
    case textActions(String)

    /// `">"` routes to commands, `"@"` to symbols, `"/"` to files, `"#"` to in-buffer text
    /// search, and `":"` to go-to-line — Sublime Text's Goto Anything sigils. Falls back to
    /// `mode` when the query has none of these prefixes. The associated string has its prefix
    /// stripped and is trimmed of whitespace for the prefixed cases; the unprefixed
    /// (mode-routed) case passes `query` through as-is.
    public static func resolve(query: String, mode: EditorPaletteMode) -> PaletteQueryScope {
        if let scope = explicitScope(in: query) { return scope }
        switch mode {
        case .commands: return .commands(query)
        case .quickOpen, .recentFiles: return .files(query)
        case .symbols, .classes: return .symbols(query)
        case .textActions: return .textActions(query)
        case .goToLine: return .line(query)
        // "Search Everywhere" and the fixed-list modes have no single scope; treat a
        // prefix-less query as free text routed to whatever the palette is showing.
        case .searchEverywhere, .locations, .findInFiles: return .textActions(query)
        }
    }

    /// The sigil-scoped reading of `query`, or `nil` when it carries none of the five prefixes.
    /// Unlike ``resolve(query:mode:)``, this never falls back to a mode's own default — it
    /// answers only "does this query explicitly name a scope", which is what a palette needs to
    /// decide whether to override its current mode's provider set for one keystroke.
    public static func explicitScope(in query: String) -> PaletteQueryScope? {
        if let remainder = query.strippingPrefix(">") { return .commands(remainder) }
        if let remainder = query.strippingPrefix("/") { return .files(remainder) }
        if let remainder = query.strippingPrefix("#") { return .text(remainder) }
        if let remainder = query.strippingPrefix(":") { return .line(remainder) }
        if let remainder = query.strippingPrefix("@") { return .symbols(remainder) }
        return nil
    }

    public var query: String {
        switch self {
        case .commands(let query), .files(let query), .symbols(let query),
             .text(let query), .line(let query), .textActions(let query):
            return query
        }
    }
}

private extension String {
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
