import Foundation

public extension LanguageDefinition {
    /// The languages Penumbra knows without a host registering anything. Identity only: the grammars of
    /// the bundled ones come from `PenumbraLanguages`, which installs them on first use, so this
    /// table works for a host that links `Penumbra` alone.
    ///
    /// Entries marked "identity only" have no grammar and are not selectable; they exist so the
    /// identifier, its fence tags or its configuration resolve.
    static let builtIns: [LanguageDefinition] = [
        LanguageDefinition(id: "plain", displayName: "Plain Text",
                           fileExtensions: ["txt", ""], fenceAliases: ["text", "plaintext", "txt"]),
        LanguageDefinition(id: "markdown", displayName: "Markdown", fileExtensions: ["md", "markdown", "mdown"],
                           fenceAliases: ["md"], isSelectable: true),
        LanguageDefinition(id: "json", displayName: "JSON", fileExtensions: ["json", "jsonc"],
                           fenceAliases: ["jsonc"], isSelectable: true),
        LanguageDefinition(id: "csv", displayName: "CSV", fileExtensions: ["csv"]),
        LanguageDefinition(id: "tsv", displayName: "TSV", fileExtensions: ["tsv", "tab"]),
        LanguageDefinition(id: "xml", displayName: "XML", fileExtensions: ["xml", "plist", "xsd", "xsl", "xslt"],
                           isSelectable: true),
        LanguageDefinition(id: "yaml", displayName: "YAML", fileExtensions: ["yaml", "yml"],
                           fenceAliases: ["yml"], isSelectable: true),
        LanguageDefinition(id: "toml", displayName: "TOML", fileExtensions: ["toml"], isSelectable: true),
        LanguageDefinition(id: "swift", displayName: "Swift", fileExtensions: ["swift"],
                           configuration: .swift, isSelectable: true),
        LanguageDefinition(id: "java", displayName: "Java", fileExtensions: ["java"],
                           configuration: .java, isSelectable: true),
        LanguageDefinition(id: "kotlin", displayName: "Kotlin", fileExtensions: ["kt", "kts"],
                           fenceAliases: ["kt", "kts"], isSelectable: true),
        LanguageDefinition(id: "groovy", displayName: "Groovy", fileExtensions: ["gradle"]),
        LanguageDefinition(id: "javascript", displayName: "JavaScript", fileExtensions: ["js", "jsx", "mjs", "cjs"],
                           fenceAliases: ["js", "jsx", "mjs", "cjs", "node"],
                           configuration: .javaScript, isSelectable: true),
        LanguageDefinition(id: "typescript", displayName: "TypeScript", fileExtensions: ["ts", "tsx", "mts", "cts"],
                           fenceAliases: ["ts", "tsx"], configuration: .typeScript, isSelectable: true),
        // Identity only: JSX and TSX are identifiers hosts pass for the configuration, not file types.
        LanguageDefinition(id: "jsx", displayName: "JSX", configuration: .javaScript),
        LanguageDefinition(id: "tsx", displayName: "TSX", configuration: .typeScript),
        LanguageDefinition(id: "html", displayName: "HTML", fileExtensions: ["html", "htm"],
                           fenceAliases: ["htm"], isSelectable: true),
        LanguageDefinition(id: "css", displayName: "CSS", fileExtensions: ["css"], isSelectable: true),
        LanguageDefinition(id: "scss", displayName: "SCSS", fileExtensions: ["scss", "sass"], isSelectable: true),
        LanguageDefinition(id: "python", displayName: "Python", fileExtensions: ["py", "pyw"],
                           fenceAliases: ["py"], isSelectable: true),
        LanguageDefinition(id: "rust", displayName: "Rust", fileExtensions: ["rs"],
                           fenceAliases: ["rs"], isSelectable: true),
        LanguageDefinition(id: "go", displayName: "Go", fileExtensions: ["go"],
                           fenceAliases: ["golang"], isSelectable: true),
        // "h" is ambiguous between C and C++ headers; resolved to C.
        LanguageDefinition(id: "c", displayName: "C", fileExtensions: ["c", "m", "h"], isSelectable: true),
        LanguageDefinition(id: "cpp", displayName: "C++",
                           fileExtensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "mm"],
                           fenceAliases: ["c++", "cc", "cxx", "hpp"], isSelectable: true),
        // Identity only: no grammar, so Markdown passes the fence name on unchanged.
        LanguageDefinition(id: "csharp", displayName: "C#", fenceAliases: ["cs"]),
        // The fence name stays "bash" (what the fence aliases always produced); the file identifier is "shell".
        LanguageDefinition(id: "shell", displayName: "Shell Script",
                           fileExtensions: ["sh", "bash", "zsh", "command"],
                           fileNames: [".bashrc", ".bash_profile", ".bash_aliases", ".bash_logout",
                                       ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".profile"],
                           aliases: ["bash", "sh", "zsh"],
                           fenceAliases: ["sh", "shell", "zsh", "console", "terminal"], fenceName: "bash",
                           isSelectable: true),
        LanguageDefinition(id: "sql", displayName: "SQL", fileExtensions: ["sql"], isSelectable: true),
        LanguageDefinition(id: "graphql", displayName: "GraphQL", fileExtensions: ["graphql", "gql"],
                           fenceAliases: ["gql"], isSelectable: true),
        LanguageDefinition(id: "http", displayName: "HTTP", fileExtensions: ["http", "rest"], isSelectable: true),
        LanguageDefinition(id: "mermaid", displayName: "Mermaid", fileExtensions: ["mmd", "mermaid"], isSelectable: true),
        LanguageDefinition(id: "diff", displayName: "Diff", fileExtensions: ["diff", "patch"],
                           aliases: ["patch"], isSelectable: true)
    ]
}
