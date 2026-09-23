import Penumbra
import PenumbraLanguages

enum IDELanguageSupport {
    /// One entry in the user-facing "Set Syntax" picker (status bar menu, View > Syntax).
    struct SyntaxOption: Identifiable {
        /// `nil` means plain text — no `TreeSitterLanguage`, no highlighting.
        let id: String?
        let displayName: String
    }

    /// Every syntax the user can pick from ``IDEWorkspace/setLanguage(identifier:in:)``, in the
    /// order Sublime Text-style syntax menus list them: Plain Text first, then alphabetical.
    /// Mirrors the identifiers ``TreeSitterLanguage/bundled(forIdentifier:)`` resolves to a
    /// grammar for, so every option here actually highlights something.
    static let selectableSyntaxes: [SyntaxOption] = [
        SyntaxOption(id: nil, displayName: "Plain Text"),
        SyntaxOption(id: "c", displayName: "C"),
        SyntaxOption(id: "cpp", displayName: "C++"),
        SyntaxOption(id: "css", displayName: "CSS"),
        SyntaxOption(id: "diff", displayName: "Diff"),
        SyntaxOption(id: "go", displayName: "Go"),
        SyntaxOption(id: "graphql", displayName: "GraphQL"),
        SyntaxOption(id: "html", displayName: "HTML"),
        SyntaxOption(id: "http", displayName: "HTTP"),
        SyntaxOption(id: "java", displayName: "Java"),
        SyntaxOption(id: "javascript", displayName: "JavaScript"),
        SyntaxOption(id: "json", displayName: "JSON"),
        SyntaxOption(id: "kotlin", displayName: "Kotlin"),
        SyntaxOption(id: "markdown", displayName: "Markdown"),
        SyntaxOption(id: "mermaid", displayName: "Mermaid"),
        SyntaxOption(id: "python", displayName: "Python"),
        SyntaxOption(id: "rust", displayName: "Rust"),
        SyntaxOption(id: "scss", displayName: "SCSS"),
        SyntaxOption(id: "shell", displayName: "Shell Script"),
        SyntaxOption(id: "sql", displayName: "SQL"),
        SyntaxOption(id: "swift", displayName: "Swift"),
        SyntaxOption(id: "toml", displayName: "TOML"),
        SyntaxOption(id: "typescript", displayName: "TypeScript"),
        SyntaxOption(id: "xml", displayName: "XML"),
        SyntaxOption(id: "yaml", displayName: "YAML")
    ]

    /// Display name for `identifier`, falling back to a capitalized identifier for one this table
    /// doesn't know about (e.g. a language a host app registered on its own).
    static func displayName(forIdentifier identifier: String?) -> String {
        selectableSyntaxes.first { $0.id == identifier }?.displayName
            ?? identifier?.capitalized
            ?? "Plain Text"
    }

    /// True when the document's language is inferred from its path and must not be overridden
    /// (e.g. a `.java` file). Untitled buffers and files with unrecognized extensions stay editable.
    static func isLanguageLocked(for document: WorkbenchDocument) -> Bool {
        guard document.contentKind == .text, let url = document.url else { return false }
        return LanguageIdentifier.identifier(for: url) != nil
    }

    static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        BundledLanguages.language(forIdentifier: identifier)
    }

    static func languageResolver(snapshot: WorkbenchDocumentSnapshot) -> TreeSitterLanguage? {
        language(forIdentifier: snapshot.languageIdentifier)
    }

    static func fileBackedLanguageResolver(document: WorkbenchDocument) -> TreeSitterLanguage? {
        language(forIdentifier: document.languageIdentifier)
    }
}
