import SwiftUI

/// One tab of a horizontal strip in the app's chrome: a leading icon or status, a title, an optional
/// trailing control, an accent bar when selected, and a hover fill. The terminal tabs and the agent's
/// chat tabs share it so they look and behave alike.
struct IDEChromeTabItem<Leading: View, Trailing: View>: View {
    let title: String
    let isSelected: Bool
    /// Not selected, but showing alongside the selected one (a pane of a split terminal).
    var isShown = false
    var accessibilityLabel: String?
    let onSelect: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                leading()
                    .frame(width: 12)

                Text(title)
                    .foregroundStyle(isSelected || isShown ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))

                trailing()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .overlay(alignment: .top) {
                if isSelected {
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.indicator)
                        .fill(IDEAppearance.ColorToken.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    .stroke(IDEAppearance.ColorToken.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isShown { return IDEAppearance.ColorToken.tabActive.opacity(0.5) }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}

/// The × at the end of a closable tab.
struct IDEChromeTabCloseButton: View {
    let side: CGFloat
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close Tab")
        .accessibilityAddTraits(.isButton)
    }
}
