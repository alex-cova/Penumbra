import Foundation

/// Normalizes a fenced-code info string (` ```js `, ` ```Swift `, ` ```python {highlight=1} `) to a
/// ``LanguageIdentifier``-style name.
///
/// Markdown authors write whatever tag they like after the fence, so injected language names arrive
/// raw. The alias table is ``LanguageDefinition/fenceAliases`` in ``LanguageDefinitionRegistry/shared``,
/// shared by the markdown editor injection (`BundledLanguageProvider`) and the markdown preview, so
/// both agree on what ` ```yml ` means.
///
/// Unknown tags pass through lowercased so a caller with its own grammar table can still resolve
/// them; `nil` means "no language".
public enum FenceLanguageName {
    public static func normalize(_ infoString: String?) -> String? {
        guard let infoString else { return nil }
        // Split on whitespace and the `{`/`=` that start attribute blocks (` ```python {highlight=1} `),
        // so only the language token itself is looked up.
        guard let token = infoString
            .split(whereSeparator: { $0.isWhitespace || $0 == "{" || $0 == "=" })
            .first
            .map({ $0.lowercased() })
        else {
            return nil
        }
        return LanguageDefinitionRegistry.shared.fenceName(forTag: token) ?? token
    }
}
