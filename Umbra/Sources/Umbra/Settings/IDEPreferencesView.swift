import Penumbra
import SwiftUI

public struct IDEPreferencesView: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedDomain: IDEPreferencesDomain = .editor
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var sidebarFocused: Bool

    public init(preferences: IDEPreferences) {
        self.preferences = preferences
    }

    /// Opens the pane something asked for (`/permissions`), once.
    private func takeRequestedDomain() {
        guard let requested = workspace.requestedSettingsDomain else { return }
        workspace.requestedSettingsDomain = nil
        query = ""
        selectedDomain = requested
    }

    private var visibleDomains: [IDEPreferencesDomain] {
        IDEPreferencesDomain.ordered(with: IDELanguageModules.preferencePanes.map(\.domain)).filter { $0.matches(query) }
    }

    /// The selected domain, or the first match when a search has filtered it out of the sidebar.
    private var shownDomain: IDEPreferencesDomain {
        visibleDomains.contains(selectedDomain) ? selectedDomain : (visibleDomains.first ?? selectedDomain)
    }

    public var body: some View {
        VStack(spacing: 0) {
            IDEPreferencesSearchField(
                query: $query, visibleDomains: visibleDomains, selectedDomain: $selectedDomain,
                searchFocused: $searchFocused, sidebarFocused: $sidebarFocused)
            HStack(spacing: 0) {
                IDEPreferencesSidebar(
                    visibleDomains: visibleDomains, shownDomain: shownDomain, selectedDomain: $selectedDomain,
                    searchFocused: $searchFocused, sidebarFocused: $sidebarFocused)
                    .frame(width: 190)
                Rectangle()
                    .fill(IDEAppearance.ColorToken.border)
                    .frame(width: 1)
                IDEPreferencesDetail(domain: shownDomain, preferences: preferences)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IDEAppearance.ColorToken.workbench)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.workbench)
        .id(preferences.uiColorSchemeID)
        .onAppear { takeRequestedDomain() }
        .onChange(of: workspace.requestedSettingsDomain) { takeRequestedDomain() }
        .focusSection()
        .task {
            await Task.yield()
            searchFocused = true
        }
        .onExitCommand(perform: handleEscape)
        .environment(\.colorScheme, IDEAppearance.preferredColorScheme)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
        .tint(IDEAppearance.ColorToken.accent)
        .modifier(IDEPreferencesLiveUpdateModifier(preferences: preferences, workspace: workspace))
    }

    /// Search with text clears first; an empty search or the sidebar returns to the field; empty
    /// field closes Settings.
    private func handleEscape() {
        if sidebarFocused {
            searchFocused = true
            return
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            query = ""
            searchFocused = true
            return
        }
        dismissWindow(id: "settings")
    }

}

#Preview {
    IDEPreferencesView(preferences: IDEPreferences.shared)
        .environment(IDEWorkspace())
        .frame(width: 880, height: 600)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
