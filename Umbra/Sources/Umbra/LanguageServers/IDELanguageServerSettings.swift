import SwiftUI

extension IDEPreferencesDomain {
    static let swift = IDEPreferencesDomain(
        id: "swift", title: "Swift", symbol: "swift",
        searchTerms: ["sourcekit", "sourcekit-lsp", "toolchain", "lsp"]
    )
    static let typescript = IDEPreferencesDomain(
        id: "typescript", title: "TypeScript", symbol: "curlybraces",
        searchTerms: ["typescript-language-server", "node", "javascript", "tsserver", "lsp"]
    )
}

extension IDESwiftModule {
    var preferencePanes: [IDEPreferencesPane] {
        [
            IDEPreferencesPane(domain: .swift) { _, _ in AnyView(IDESwiftServerSettings()) },
            IDEPreferencesPane(domain: .swiftUIPreview) { _, _ in AnyView(IDESwiftUIPreviewSettingsPage()) }
        ]
    }
}

extension IDETypeScriptModule {
    var preferencePanes: [IDEPreferencesPane] {
        [IDEPreferencesPane(domain: .typescript) { _, _ in AnyView(IDETypeScriptServerSettings()) }]
    }
}

private struct IDESwiftServerSettings: View {
    @AppStorage(IDELanguageServerHost.enabledDefaultsKey) private var enabled = true
    @AppStorage(IDESourceKitServer.pathKey) private var path = ""

    var body: some View {
        IDESettingsSection(
            "SourceKit-LSP",
            footer: "Compiler completion, navigation and diagnostics. Leave the path empty to use xcrun, then /usr/bin/sourcekit-lsp. The server starts only after you trust the folder."
        ) {
            IDESettingsToggle("Use SourceKit-LSP", isOn: $enabled)
            IDEServerPathField(title: "sourcekit-lsp", path: $path)
        }
        IDESwiftInspectionsSettings()
    }
}

private struct IDETypeScriptServerSettings: View {
    @AppStorage(IDELanguageServerHost.enabledDefaultsKey) private var enabled = true
    @AppStorage(IDETypeScriptServer.pathKey) private var path = ""

    var body: some View {
        IDESettingsSection(
            "TypeScript Language Server",
            footer: "Uses the project's TypeScript when node_modules has one. Leave the path empty to use node_modules/.bin, then PATH. The server starts only after you trust the folder."
        ) {
            IDESettingsToggle("Use TypeScript Language Server", isOn: $enabled)
            IDEServerPathField(title: "typescript-language-server", path: $path)
        }
    }
}

private struct IDEServerPathField: View {
    let title: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            TextField("Path", text: $path)
                .textFieldStyle(.roundedBorder)
        }
    }
}
