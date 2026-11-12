import Penumbra
import SwiftUI

/// The settings domain list with arrow-key navigation. Extracted from `IDEPreferencesView`.
struct IDEPreferencesSidebar: View {
    let visibleDomains: [IDEPreferencesDomain]
    let shownDomain: IDEPreferencesDomain
    @Binding var selectedDomain: IDEPreferencesDomain
    @FocusState.Binding var searchFocused: Bool
    @FocusState.Binding var sidebarFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
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
        .focusable()
        .focused($sidebarFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            selectedDomain = IDEPreferencesDomain.moving(from: shownDomain, in: visibleDomains, by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedDomain = IDEPreferencesDomain.moving(from: shownDomain, in: visibleDomains, by: 1)
            return .handled
        }
        .onKeyPress(.tab) {
            searchFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            searchFocused = true
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDEACPAccessibility.settingsSidebar)
        .ideSettingsScrollSurface()
    }
}
