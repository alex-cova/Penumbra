import SwiftUI

/// Settings ▸ LSP: Python's and TypeScript's server settings, then every catalog server with its state, an executable override,
/// an on/off switch, Restart, and install guidance. Reads the window's host; stores only UserDefaults keys.
struct IDELanguageServersSettings: View {
    let workspace: IDEWorkspace

    var body: some View {
        IDEPythonServerSettings()
        IDETypeScriptServerSettings()
        IDESettingsSection(
            "Language Servers",
            footer: "Umbra never installs a server for you: it shows the command. A server starts only after you trust the folder, and only for folders that look like the language (a manifest, or source files)."
        ) {
            ForEach(IDELanguageServerCatalog.all) { spec in
                IDELanguageServerRow(spec: spec, workspace: workspace)
            }
        }
    }
}
