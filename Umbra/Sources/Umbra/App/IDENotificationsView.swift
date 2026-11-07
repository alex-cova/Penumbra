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
    @State private var selectedID: IDENotification.ID?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool

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
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.escape) { closePanel() }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(center.items) { item in
                                IDENotificationRow(
                                    item: item,
                                    isSelected: selectedID == item.id,
                                    onSelect: {
                                        selectedID = item.id
                                        isListFocused = true
                                    },
                                    open: { workspace.activate(item) },
                                    dismiss: { dismiss(item.id) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press)
                    }
                    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                        if let selectedID { dismiss(selectedID) }
                        return .handled
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 340)
        .idePanel(fill: IDEAppearance.ColorToken.card)
        .shadow(color: IDEAppearance.Shadow.cardColor, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
        .onAppear {
            if selectedID == nil { selectedID = center.items.first?.id }
            isListFocused = true
        }
        .onChange(of: center.items.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            self.selectedID = ids.first
        }
    }

    private var header: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text("Notifications")
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            IDEIconButton(
                systemImage: center.isMuted ? "bell.slash.fill" : "bell.slash",
                help: center.isMuted ? "Turn Do Not Disturb Off" : "Do Not Disturb",
                isActive: center.isMuted
            ) {
                center.isMuted.toggle()
            }
            categoryMenu
            IDEIconButton(systemImage: "trash", help: "Clear All") {
                center.clear()
            }
            .disabled(center.items.isEmpty)
        }
        .ideIconButtonSize(.header)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 40)
    }

    private var categoryMenu: some View {
        IDEIconMenu(systemImage: "slider.horizontal.3", help: "Notification Sources") {
            ForEach(IDENotificationCategory.allCases) { category in
                Toggle(category.displayName, isOn: Binding(
                    get: { center.isEnabled(category) },
                    set: { center.setCategory(category, enabled: $0) }
                ))
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = center.items.map(\.id)
        let current = center.items.first { $0.id == selectedID }
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let id = IDEListNeighbor.move(selectedID, in: ids, by: delta) {
                selectedID = id
                isListFocused = true
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current, current.action != nil else { return .ignored }
            workspace.activate(current)
            return .handled
        case .escape:
            typeahead.reset()
            return closePanel()
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let item = IDEListTypeahead.match(
                query: typeahead.typed(character), in: center.items, selected: current, title: \.title
            ) {
                selectedID = item.id
                isListFocused = true
            }
            return .handled
        }
    }

    private func dismiss(_ id: IDENotification.ID) {
        let ids = center.items.map(\.id)
        let fallback: IDENotification.ID?
        if let index = ids.firstIndex(of: id) {
            fallback = index + 1 < ids.count ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
        } else {
            fallback = selectedID
        }
        center.remove(id)
        selectedID = fallback
        isListFocused = true
    }

    private func closePanel() -> KeyPress.Result {
        workspace.notifications.setPanelPresented(false)
        return .handled
    }
}

private struct IDENotificationRow: View {
    let item: IDENotification
    var isSelected = false
    let onSelect: () -> Void
    let open: () -> Void
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
            Button {
                onSelect()
                open()
            } label: {
                HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: item.severity.symbolName)
                        .foregroundStyle(item.severity.tint)
                        .font(.system(size: IDEAppearance.IconSize.bodyGlyph))
                        .padding(.top, IDEAppearance.Spacing.hairline)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
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
                        if let link = item.action?.linkTitle {
                            Text(link)
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.accent)
                                .underline()
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
            .focusable(false)
            .disabled(item.action == nil)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}
