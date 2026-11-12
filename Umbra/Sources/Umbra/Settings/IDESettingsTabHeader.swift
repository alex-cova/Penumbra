import Penumbra
import SwiftUI

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
                            in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.selection, style: .continuous)
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
