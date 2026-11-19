import SwiftUI

extension IDEPreferencesDomain {
    static let languageServers = IDEPreferencesDomain(
        id: "language-servers", title: "LSP", symbol: "server.rack",
        searchTerms: ["lsp", "language servers", "python", "pylsp", "python-lsp-server", "venv", "typescript", "typescript-language-server", "node", "javascript", "tsserver", "rust-analyzer", "gopls", "clangd", "php", "ruby", "lua", "dart", "kotlin", "scala", "zig",
                      "terraform", "bash", "c#", "r", "install", "restart", "language"]
    )
}

/// The catalog servers (PHP, Rust, C#, Kotlin, Scala, Zig, Terraform, Ruby, R, Lua, Go, Dart, C/C++, Bash) as
/// one module: their definitions for the host and the one Settings page that manages them.
/// Java stays native; Swift, TypeScript and Python keep their own modules.
struct IDECatalogServersModule: IDELanguageModule {
    static let id = "language-servers"
    var id: String { Self.id }

    var languageServers: [IDELanguageServerDefinition] {
        IDELanguageServerCatalog.all.map { IDECatalogServer.definition(for: $0) }
    }

    var preferencePanes: [IDEPreferencesPane] {
        [IDEPreferencesPane(domain: .languageServers) { _, workspace in IDELanguageServersSettings(workspace: workspace) }]
    }
}
