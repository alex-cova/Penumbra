import SwiftUI

/// The row above one file's results in a list (Usages, Problems, the edit preview): chevron, file
/// name, its folder, and how many rows follow. Collapsible when given `onToggle`.
struct IDEFileGroupHeader: View {
    let name: String
    let directory: String
    let count: Int
    /// What the count counts, for VoiceOver: "usages" reads "Calc.java, 3 usages".
    let noun: String
    /// Nil for a header that cannot be collapsed; otherwise whether the group is collapsed.
    var isCollapsed: Bool?
    var onToggle: (() -> Void)?

    var body: some View {
        if let onToggle {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name), \(count) \(noun)")
                .accessibilityHint(isCollapsed == true ? "Expand" : "Collapse")
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let isCollapsed {
                IDEDisclosureChevron(isExpanded: !isCollapsed)
            }
            Text(name)
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(directory)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// The small chevron that shows a group open or closed. Fixed width so titles line up either way.
///
/// `size`/`width` cover the real variation across call sites (8–10pt glyphs, 10–14pt columns).
/// Pass `width: nil` where the call site never constrained the width, so adopting this changes
/// no pixels. Deliberately not used where the size is inherited (call hierarchy rows) or scaled
/// (local-model cards), or where the API takes a symbol name instead of a view (settings panes).
struct IDEDisclosureChevron: View {
    let isExpanded: Bool
    var size: CGFloat = 9
    var width: CGFloat? = 10

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .frame(width: width)
            .accessibilityHidden(true)
    }
}
