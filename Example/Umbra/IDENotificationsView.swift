import SwiftUI

extension IDENotificationSeverity {
    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: IDEAppearance.ColorToken.accent
        case .success: IDEAppearance.ColorToken.gitAdded
        case .warning: IDEAppearance.ColorToken.gitModified
        case .error: IDEAppearance.ColorToken.error
        }
    }
}

/// The bell's dropdown: a card under the titlebar, top-right, listing what is waiting.
struct IDENotificationPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    private var center: IDENotificationCenter { workspace.notifications }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
            if center.items.isEmpty {
                Text("You don't have any unread notifications")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .padding(.horizontal, IDEAppearance.Spacing.md)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.items) { item in
                            IDENotificationRow(item: item) {
                                workspace.activate(item)
                            } dismiss: {
                                center.remove(item.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
        .idePanel(fill: IDEAppearance.ColorToken.card)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }

    private var header: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text("Notifications")
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            IDENotificationHeaderButton(
                systemName: center.isMuted ? "bell.slash.fill" : "bell.slash",
                isActive: center.isMuted,
                help: center.isMuted ? "Turn Do Not Disturb Off" : "Do Not Disturb"
            ) {
                center.isMuted.toggle()
            }
            categoryMenu
            IDENotificationHeaderButton(systemName: "trash", isActive: false, help: "Clear All") {
                center.clear()
            }
            .disabled(center.items.isEmpty)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 40)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(IDENotificationCategory.allCases) { category in
                Toggle(category.displayName, isOn: Binding(
                    get: { center.isEnabled(category) },
                    set: { center.setCategory(category, enabled: $0) }
                ))
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: IDEAppearance.IconSize.titlebarGlyph))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notification Sources")
        .accessibilityLabel("Notification Sources")
    }
}

private struct IDENotificationHeaderButton: View {
    let systemName: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: IDEAppearance.IconSize.titlebarGlyph))
                .foregroundStyle(isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: 26, height: 26)
                .background(isHovering && isEnabled ? IDEAppearance.ColorToken.controlHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .focusable(false)
    }
}

private struct IDENotificationRow: View {
    let item: IDENotification
    let open: () -> Void
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
            Button(action: open) {
                HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: item.severity.symbolName)
                        .foregroundStyle(item.severity.tint)
                        .font(.system(size: 13))
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(IDEAppearance.Typography.tabLabel.weight(.medium))
                            .foregroundStyle(IDEAppearance.ColorToken.foreground)
                            .lineLimit(2)
                        if let detail = item.detail {
                            Text(detail)
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(2)
                        }
                        Text(item.date, style: .relative)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted.opacity(0.7))
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.action == nil)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .background(isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear)
        .onHover { isHovering = $0 }
        .focusable(false)
    }
}
