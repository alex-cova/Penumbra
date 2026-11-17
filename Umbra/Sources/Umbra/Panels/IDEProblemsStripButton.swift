import SwiftUI

/// One tab-strip button of the Problems panel: File, Project Errors, or an Inspect Code run title.
struct IDEProblemsStripButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.tight)
                .background(isSelected ? IDEAppearance.ColorToken.tabActive : .clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
