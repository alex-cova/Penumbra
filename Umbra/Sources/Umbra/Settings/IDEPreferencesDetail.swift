import Penumbra
import SwiftUI

/// The settings detail column: the selected domain's page plus the theme preview.
/// Extracted from `IDEPreferencesView`.
struct IDEPreferencesDetail: View {
    let domain: IDEPreferencesDomain
    @Bindable var preferences: IDEPreferences

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            if domain == .agent {
                IDEPreferencesAgentPane(agent: workspace.agent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                IDESettingsPage(title: domain.title) {
                    domainPane(for: domain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if domain.showsTypePreview {
                IDEPreferencesTypePreview(
                    themeID: preferences.themeID,
                    fontName: preferences.fontName,
                    fontSize: preferences.fontSize,
                    tabWidth: preferences.tabWidth,
                    useSpacesForTab: preferences.useSpacesForTab
                )
            }
        }
    }

    @ViewBuilder
    private func domainPane(for domain: IDEPreferencesDomain) -> some View {
        switch domain {
        case .general:
            IDEPreferencesGeneralPane(preferences: preferences)
        case .editor:
            IDEPreferencesEditorPane(preferences: preferences)
        case .saving:
            IDEPreferencesSavingPane(preferences: preferences)
        case .appearance:
            IDEPreferencesAppearancePane(preferences: preferences)
        case .terminal:
            IDEPreferencesTerminalPane(preferences: preferences)
        case .focus:
            IDEPreferencesFocusPane(preferences: preferences)
        case .project:
            IDEPreferencesProjectPane(preferences: preferences)
        case .agent:
            IDEPreferencesAgentPane(agent: workspace.agent)
        default:
            // A language module's page.
            if let pane = IDELanguageModules.preferencePanes.first(where: { $0.domain == domain }) {
                pane.content(preferences, workspace)
            }
        }
    }
}
