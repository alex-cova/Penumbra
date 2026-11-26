import SwiftUI

/// The strip above a text tab whose language has a server the project wants but this Mac does not
/// have installed (e.g. a shell file while `bash-language-server` is missing). The status bar no
/// longer lists missing servers, so this is where that state surfaces: only on a matching file,
/// with the install hint and a way to the LSP settings or to dismiss it for the pane.
struct IDEMissingLanguageServerBanner: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID
    @State private var dismissed: Set<String> = []

    var body: some View {
        // Reading the tab rows re-renders this when the pane's selection changes.
        let selectedID = workspace.tabsByPane[paneID]?.first(where: \.isSelected)?.id
        let document = workspace.workbench.layout.findPane(id: paneID)?.documents.first { $0.id == selectedID }
        if let notice = IDEMissingLanguageServerNotice.forDocument(
            languageIdentifier: document?.languageIdentifier,
            statuses: workspace.languageServerHost.statuses,
            dismissed: dismissed
        ) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                Text(notice.message)
                    .lineLimit(2)
                if !notice.installHint.isEmpty {
                    Text(notice.installHint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                Button("Settings…") {
                    workspace.requestedSettingsDomain = .languageServers
                    workspace.showSettings()
                }
                .help("Open the language server settings")
                Button("Dismiss") { dismissed.insert(notice.serverID) }
                    .help("Hide this notice while the pane stays open")
            }
            .font(.caption)
            .padding(IDEAppearance.Spacing.snug)
            .background(IDEAppearance.ColorToken.gitModified.opacity(0.25))
        }
    }
}

/// The testable mapping behind ``IDEMissingLanguageServerBanner``: which missing server, if any, a
/// file's language calls for. Pure so the unit tests cover it without a window.
enum IDEMissingLanguageServerNotice {
    struct Notice: Equatable {
        var serverID: String
        var message: String
        var installHint: String
    }

    @MainActor
    static func forDocument(
        languageIdentifier: String?,
        statuses: [IDELanguageServerHost.ServerStatus],
        dismissed: Set<String> = []
    ) -> Notice? {
        guard let language = languageIdentifier, !language.isEmpty else { return nil }
        let definitions = IDELanguageModules.all.flatMap(\.languageServers)
        guard let definition = definitions.first(where: { $0.configuration.languageIdentifiers.contains(language) })
        else { return nil }
        guard !dismissed.contains(definition.id) else { return nil }
        guard statuses.contains(where: { $0.id == definition.id && $0.phase == .missing }) else { return nil }
        if let spec = IDELanguageServerCatalog.spec(id: definition.id), !IDECatalogServer.isEnabled(spec) {
            return nil
        }
        let spec = IDELanguageServerCatalog.spec(id: definition.id)
        return Notice(
            serverID: definition.id,
            message: "\(definition.configuration.name) language server not found",
            installHint: spec?.installInstructions.first ?? ""
        )
    }
}
