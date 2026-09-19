import Foundation

/// Normalizes a fenced-code info string (` ```js `, ` ```Swift `, ` ```python {highlight=1} `) to a
/// ``LanguageIdentifier``-style name.
///
/// Markdown authors write whatever tag they like after the fence, so injected language names arrive
/// raw. This is the single alias table shared by the markdown editor injection
/// (`BundledLanguageProvider`) and the markdown preview, so both agree on what ` ```yml ` means.
///
/// Unknown tags pass through lowercased so a caller with its own grammar table can still resolve
/// them; `nil` means "no language".
public enum FenceLanguageName {
    private static let aliases: [String: String] = [
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "node": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "py": "python",
        "sh": "bash",
        "shell": "bash",
        "zsh": "bash",
        "console": "bash",
        "terminal": "bash",
        "yml": "yaml",
        "md": "markdown",
        "gql": "graphql",
        "c++": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
        "rs": "rust",
        "kt": "kotlin",
        "kts": "kotlin",
        "golang": "go",
        "htm": "html",
        "jsonc": "json",
        "text": "plain",
        "plaintext": "plain",
        "txt": "plain"
    ]

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
        return aliases[token] ?? token
    }
}
