import Foundation

/// Detects a plain-text language identifier from a file's name or extension — the piece needed to
/// populate ``WorkbenchDocument/languageIdentifier`` when opening a file, which nothing in
/// Penumbra does automatically today.
///
/// Identifiers are plain lowercase strings (`"swift"`, `"json"`, `"markdown"`, …) rather than an
/// enum: Penumbra doesn't ship a language enum, and a `String` lets a consumer freely add
/// languages this table doesn't know about. Where Penumbra ships a language package for one of
/// these identifiers, the identifier lines up with its natural name (e.g. `"graphql"`,
/// `"markdown"`), though nothing wires that up automatically — mapping an identifier to a
/// `TreeSitterLanguage` (e.g. via ``TreeSitterLanguageCache``) is left to the consumer.
///
/// Deliberate deviation from a plain extension→language switch: unrecognized extensions return
/// `nil` rather than collapsing to `"plain"`, so a caller can distinguish "this file is explicitly
/// plain text" from "this extension isn't in the table, you decide the fallback."
public enum LanguageIdentifier {
    /// Checks the extensionless-dotfile special case first (`.zshrc`, `.bashrc`, etc. → `"shell"`,
    /// since `URL.pathExtension` can't see them), then falls back to
    /// ``identifier(forFileExtension:)``.
    public static func identifier(for url: URL) -> String? {
        if shellFilenames.contains(url.lastPathComponent.lowercased()) {
            return "shell"
        }
        return identifier(forFileExtension: url.pathExtension)
    }

    /// Extensionless shell config files `URL.pathExtension` can't see.
    private static let shellFilenames: Set<String> = [
        ".bashrc", ".bash_profile", ".bash_aliases", ".bash_logout",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".profile"
    ]

    public static func identifier(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "txt", "":
            return "plain"
        case "md", "markdown", "mdown":
            return "markdown"
        case "json", "jsonc":
            return "json"
        case "xml", "plist", "xsd", "xsl", "xslt":
            return "xml"
        case "yaml", "yml":
            return "yaml"
        case "toml":
            return "toml"
        case "swift":
            return "swift"
        case "java":
            return "java"
        case "kt", "kts":
            return "kotlin"
        case "gradle":
            return "groovy"
        case "js", "jsx", "mjs", "cjs":
            return "javascript"
        case "ts", "tsx", "mts", "cts":
            return "typescript"
        case "html", "htm":
            return "html"
        case "css":
            return "css"
        case "scss", "sass":
            return "scss"
        case "py", "pyw":
            return "python"
        case "rs":
            return "rust"
        case "go":
            return "go"
        case "c", "m", "h":
            // "h" is ambiguous between C and C++ headers; resolved to C.
            return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "mm":
            return "cpp"
        case "sh", "bash", "zsh", "command":
            return "shell"
        case "sql":
            return "sql"
        case "graphql", "gql":
            return "graphql"
        case "http", "rest":
            return "http"
        case "mmd", "mermaid":
            return "mermaid"
        case "diff", "patch":
            return "diff"
        default:
            return nil
        }
    }
}
