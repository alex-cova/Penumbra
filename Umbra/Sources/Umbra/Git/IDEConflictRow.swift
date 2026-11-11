import SwiftUI

/// A conflicted file in the Changes list: double-click opens the merge tool; the buttons take one
/// side without opening it.
struct IDEConflictRow: View {
    let change: IDEGitChange
    var isSelected = false
    var showsFocus = false
    var onSelect: (() -> Void)?
    let onMerge: () -> Void
    let onTakeYours: () -> Void
    let onTakeTheirs: () -> Void
    let onOpenFile: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                .accessibilityHidden(true)
            Text((change.relativePath as NSString).lastPathComponent)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                .lineLimit(1)
                .accessibilityHidden(true)
            Text((change.relativePath as NSString).deletingLastPathComponent)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Button("Merge…", action: onMerge)
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 3)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .gitRowFocusStroke(isOn: showsFocus)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenLabel)
        .onTapGesture(count: 2, perform: onMerge)
        .onTapGesture { onSelect?() }
        .contextMenu {
            Button("Merge…", action: onMerge)
            Divider()
            Button("Accept Yours", action: onTakeYours)
            Button("Accept Theirs", action: onTakeTheirs)
            Divider()
            Button("Open File", action: onOpenFile)
        }
    }

    private var spokenLabel: String {
        change.presentation(in: .conflict).accessibilityLabel(path: change.relativePath, section: .conflict)
    }
}
