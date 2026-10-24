import EditorIntelligence
import SwiftUI

/// A hierarchy kept as it was when it was pinned: a copy of the tab's content that stays while the
/// next hierarchy opens in the live view (IntelliJ's Pin Tab).
struct IDEPinnedHierarchy<Store: AnyObject>: Identifiable {
    let id = UUID()
    let title: String
    let store: Store
}

/// The strip above a hierarchy once something is pinned: "Current" for the live view, one chip per
/// pinned hierarchy with a button that unpins it.
struct IDEHierarchyPinStrip: View {
    let pins: [(id: UUID, title: String)]
    /// The selected pin, nil for the live view.
    let selected: UUID?
    let onSelect: (UUID?) -> Void
    let onUnpin: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                chip("Current", isSelected: selected == nil) { onSelect(nil) }
                ForEach(pins, id: \.id) { pin in
                    HStack(spacing: 4) {
                        chip(pin.title, isSelected: selected == pin.id, systemImage: "pin.fill") { onSelect(pin.id) }
                        Button {
                            onUnpin(pin.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin")
                        .accessibilityLabel("Unpin \(pin.title)")
                    }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 3)
        }
    }

    private func chip(_ title: String, isSelected: Bool, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 8))
                }
                Text(title).lineLimit(1)
            }
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isSelected ? IDEAppearance.ColorToken.tabActive : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Which sources a hierarchy search covers.
struct IDEHierarchyScopeMenu: View {
    let scope: HierarchyScope
    let isEnabled: Bool
    let onChange: (HierarchyScope) -> Void

    var body: some View {
        Menu {
            ForEach(HierarchyScope.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    if option == scope {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Text("Scope: \(scope.title)")
                .font(IDEAppearance.Typography.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!isEnabled)
        .help(isEnabled ? "Which sources the search covers" : "The scope applies to subtypes and callers")
    }
}
