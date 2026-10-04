import Penumbra
import SwiftUI

public struct IDEPreferencesView: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @State private var selectedDomain: IDEPreferencesDomain = .editor
    @State private var query = ""
    @FocusState private var searchFocused: Bool

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
        IDEPreferencesDomain.allCases.filter { $0.matches(query) }
    }

    /// The selected domain, or the first match when a search has filtered it out of the sidebar.
    private var shownDomain: IDEPreferencesDomain {
        visibleDomains.contains(selectedDomain) ? selectedDomain : (visibleDomains.first ?? selectedDomain)
    }

    public var body: some View {
        let _ = preferences.uiColorSchemeID
        VStack(spacing: 0) {
            IDESettingsTabHeader(onClose: workspace.hideSettings)
                .onAppear { takeRequestedDomain() }
                .onChange(of: workspace.requestedSettingsDomain) { takeRequestedDomain() }
            searchField
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 190)
                Rectangle()
                    .fill(IDEAppearance.ColorToken.border)
                    .frame(width: 1)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IDEAppearance.ColorToken.workbench)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.workbench)
        .id(preferences.uiColorSchemeID)
        .onExitCommand(perform: workspace.hideSettings)
        .environment(\.colorScheme, IDEAppearance.preferredColorScheme)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
        .tint(IDEAppearance.ColorToken.accent)
        .modifier(IDEPreferencesLiveUpdateModifier(preferences: preferences, workspace: workspace))
    }

    private var searchField: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .focused($searchFocused)
                .onSubmit {
                    if let first = visibleDomains.first { selectedDomain = first }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .font(IDEAppearance.Typography.body)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(width: 240, height: 32)
        .background(
            IDEAppearance.ColorToken.panel,
            in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .strokeBorder(
                    searchFocused ? IDEAppearance.ColorToken.accent.opacity(0.7) : IDEAppearance.ColorToken.border,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .padding(.horizontal, IDEAppearance.Spacing.lg)
        .padding(.vertical, IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleDomains) { domain in
                    IDEPreferencesSidebarRow(domain: domain, isSelected: domain == shownDomain) {
                        selectedDomain = domain
                    }
                }
                if visibleDomains.isEmpty {
                    Text("No matching settings")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(IDEAppearance.Spacing.sm)
                }
            }
            .padding(IDEAppearance.Spacing.sm)
        }
        .ideSettingsScrollSurface()
    }

    @ViewBuilder
    private var detail: some View {
        let domain = shownDomain

        VStack(spacing: 0) {
            IDESettingsPage(title: domain.title) {
                domainPane(for: domain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

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
        case .inspections:
            IDEPreferencesInspectionsPane(preferences: preferences)
        case .agent:
            IDEPreferencesAgentPane(agent: workspace.agent)
        }
    }
}

/// The strip above the settings, in the place of the editor's tab bar: one tab that closes them.
struct IDESettingsTabHeader: View {
    var title = "Settings"
    var systemImage = "gearshape"
    let onClose: () -> Void
    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 16, height: 16)
                        .background(
                            isHoveringClose ? IDEAppearance.ColorToken.controlHover : .clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .help("Close \(title)")
                .accessibilityLabel("Close \(title)")
            }
            .font(IDEAppearance.Typography.tabLabel)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .frame(maxHeight: .infinity)
            .background(IDEAppearance.ColorToken.tabActive)
            Spacer(minLength: 0)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .background(IDEAppearance.ColorToken.tabBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
    }
}

private struct IDEPreferencesSidebarRow: View {
    let domain: IDEPreferencesDomain
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: domain.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
                Text(domain.title)
                    .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
            }
            .font(IDEAppearance.Typography.body)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .frame(height: 30)
            .background(
                isSelected ? IDEAppearance.ColorToken.tabActive : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear),
                in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    IDEPreferencesView(preferences: IDEPreferences.shared)
        .environment(IDEWorkspace())
        .frame(width: 880, height: 600)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}

/// Settings ▸ Agent: the same form as the agent panel's popover, plus the limits and protected files.
private struct IDEPreferencesAgentPane: View {
    let agent: IDEAgentController
    @State private var isModelsPresented = false

    var body: some View {
        IDEAgentSettingsView(
            settings: agent.settings, agent: agent, isFullPane: true, width: nil,
            manageModels: { isModelsPresented = true })
            .sheet(isPresented: $isModelsPresented) { IDELocalModelsView(store: .shared, settings: agent.settings) }
    }
}
