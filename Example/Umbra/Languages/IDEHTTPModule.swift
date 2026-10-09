import Penumbra
import SwiftUI

/// `.http` files: Send Request / Show Response commands, the HTTP menu and the HTTP Response tool
/// window. Completion and the gutter send buttons are the `umbra.http` language service and
/// `IDEWorkspace.refreshHTTPGutter`.
struct IDEHTTPModule: IDELanguageModule {
    static let id = "http"
    var id: String { Self.id }

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        [
            EditorCommand(id: "app.http.sendRequest", title: "HTTP: Send Request", group: "HTTP",
                          action: { [weak workspace] in workspace?.sendActiveHTTPRequest() }),
            EditorCommand(id: "app.http.showResponse", title: "HTTP: Show Response", group: "HTTP",
                          action: { [weak workspace] in workspace?.showHTTPResponse() })
        ]
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard workspace.statusLanguage == "http", workspace.httpFileCanSend else { return [] }
        return [.button(
            id: "http.send", order: IDEToolbarItem.Order.send, systemImage: "paperplane.fill", help: "Send HTTP Request",
            tint: IDEAppearance.ColorToken.accent, action: { [weak workspace] in workspace?.sendActiveHTTPRequest() }
        )]
    }

    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem] {
        guard workspace.statusLanguage == "http", workspace.httpSupport.isSending else { return [] }
        return [IDEStatusItem(id: "http.sending", placement: .leading, order: 100, content: AnyView(
            Button("Sending HTTP request…") { [weak workspace] in workspace?.showHTTPResponse() }
                .buttonStyle(.borderless)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        ))]
    }

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        guard workspace.showsHTTPTab else { return [] }
        return [workspace.bottomToolWindow(.http, "network", "HTTP Response", nil, .blue, .trailingBottom, order: IDEToolWindow.Order.httpResponse)]
    }

    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard workspace.showsHTTPTab else { return [] }
        return [IDEBottomTabContribution(
            tab: .http, order: IDEBottomPanelTab.Order.http,
            item: { workspace in
                AnyView(IDEHTTPTabItem(
                    isSelected: workspace.isBottomTabSelected(.http),
                    isSending: workspace.httpSupport.isSending,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.http) }
                ))
            },
            content: { workspace in
                AnyView(IDEHTTPResponseView(
                    log: workspace.httpSupport.responseLog,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                ))
            },
            controls: { _ in AnyView(IDEHTTPConsoleControls()) }
        )]
    }

    /// The HTTP menu exists while an `.http` file is the selected tab.
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
        guard workspace.statusLanguage == "http" else { return nil }
        return IDEModuleMenu(title: "HTTP") { ref in AnyView(IDEHTTPCommands(ref: ref)) }
    }
}

private struct IDEHTTPCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Send Request", systemImage: "paperplane.fill", action: { workspace?.sendActiveHTTPRequest() })
            .menuShortcut(.sendHTTPRequest, in: preset)
            .disabled(!(workspace?.httpFileCanSend ?? false))
        Button("Show Response", action: { workspace?.showHTTPResponse() })
            .disabled(workspace?.httpSupport.responseLog.lines.isEmpty ?? true)
    }
}

extension IDEBottomPanelTab {
    /// The response of the last `.http` request.
    static let http = IDEBottomPanelTab("http")
}
