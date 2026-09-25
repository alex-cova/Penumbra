import Penumbra
import SwiftUI

public struct IDEPreferencesView: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @State private var selectedDomain: IDEPreferencesDomain? = .editor

    public init(preferences: IDEPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        NavigationSplitView {
            List(IDEPreferencesDomain.allCases, selection: $selectedDomain) { domain in
                Label(domain.title, systemImage: domain.symbol)
                    .tag(domain)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailContent
        }
        .frame(
            minWidth: IDEAppearance.Spacing.settingsWidth,
            idealWidth: IDEAppearance.Spacing.settingsIdealWidth,
            minHeight: IDEAppearance.Spacing.settingsMinHeight
        )
        .background(IDEAppearance.ColorToken.workbench)
        .preferredColorScheme(.dark)
        .tint(IDEAppearance.ColorToken.accent)
        .modifier(IDEPreferencesLiveUpdateModifier(preferences: preferences, workspace: workspace))
    }

    @ViewBuilder
    private var detailContent: some View {
        let domain = selectedDomain ?? .editor

        VStack(spacing: 0) {
            domainPane(for: domain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(IDEAppearance.Spacing.lg)

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
        .navigationTitle(domain.title)
    }

    @ViewBuilder
    private func domainPane(for domain: IDEPreferencesDomain) -> some View {
        switch domain {
        case .editor:
            IDEPreferencesEditorPane(preferences: preferences)
        case .appearance:
            IDEPreferencesAppearancePane(preferences: preferences)
        case .focus:
            IDEPreferencesFocusPane(preferences: preferences)
        case .project:
            IDEPreferencesProjectPane(preferences: preferences)
        case .java:
            IDEPreferencesJavaPane(preferences: preferences)
        }
    }
}

#Preview {
    IDEPreferencesView(preferences: IDEPreferences.shared)
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
}
