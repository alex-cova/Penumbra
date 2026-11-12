import Penumbra
import SwiftUI

struct IDEPreferencesSidebarRow: View {
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
        .accessibilityIdentifier(IDEACPAccessibility.settingsDomain(domain.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
