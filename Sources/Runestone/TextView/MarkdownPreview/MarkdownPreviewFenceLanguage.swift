import Foundation

/// Normalizes fenced-code info strings (e.g. ` ```js `) to ``LanguageIdentifier``-style names.
enum MarkdownPreviewFenceLanguage {
    private static let aliases: [String: String] = [
        "js": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "py": "python",
        "sh": "bash",
        "shell": "bash",
        "zsh": "bash",
        "yml": "yaml",
        "md": "markdown",
        "gql": "graphql",
        "graphql": "graphql",
        "c++": "cpp",
        "cc": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
    ]

    static func normalize(_ hint: String?) -> String? {
        guard let hint else { return nil }
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "{" || $0 == "=" }).first.map(String.init) ?? trimmed
        let lower = token.lowercased()
        if let mapped = aliases[lower] { return mapped }
        return lower
    }
}
