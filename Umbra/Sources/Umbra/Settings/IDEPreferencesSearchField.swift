import Penumbra
import SwiftUI

/// The settings search field, with keyboard navigation down into the sidebar.
/// Extracted from `IDEPreferencesView`.
struct IDEPreferencesSearchField: View {
    @Binding var query: String
    let visibleDomains: [IDEPreferencesDomain]
    @Binding var selectedDomain: IDEPreferencesDomain
    @FocusState.Binding var searchFocused: Bool
    @FocusState.Binding var sidebarFocused: Bool

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .accessibilityLabel("Search settings")
                .accessibilityIdentifier(IDEACPAccessibility.settingsSearch)
                .focused($searchFocused)
                .onSubmit {
                    if let first = visibleDomains.first { selectedDomain = first }
                }
                .onKeyPress(.downArrow) {
                    sidebarFocused = true
                    return .handled
                }
                .onKeyPress(.tab) {
                    sidebarFocused = true
                    return .handled
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
}
