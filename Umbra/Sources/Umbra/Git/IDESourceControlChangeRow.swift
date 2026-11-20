import SwiftUI

struct IDESourceControlChangeRow: View {
    let change: IDEGitChange
    let section: IDEGitChangeSection
    let isSelected: Bool
    var showsFocus = false
    let showsStage: Bool
    let onSelect: () -> Void
    /// Double-click: the change in a diff tab.
    let onOpen: () -> Void
    let onOpenFile: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onRevert: () -> Void

    @State private var isHovering = false

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDESourceControlChangeRow")
        HStack(spacing: IDEAppearance.Spacing.snug) {
            Image(systemName: IDEFileIcon.systemName(forFilename: change.relativePath))
                .font(.system(size: IDEAppearance.IconSize.rowGlyph))
                .foregroundStyle(letterColor)
                .frame(width: IDEAppearance.IconSize.titlebarGlyph)
                .accessibilityHidden(true)

            fileLabel

            Text(presentation.letter)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(letterColor)
                .fixedSize()
                .accessibilityHidden(true)

            IDEIconButton(
                systemImage: showsStage ? "plus" : "minus",
                help: showsStage ? "Stage File" : "Unstage File",
                action: showsStage ? onStage : onUnstage
            )
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .background(rowBackground, in: .rect(cornerRadius: IDEAppearance.Radius.selection))
        .overlay {
            if showsFocus {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.selection)
                    .strokeBorder(IDEAppearance.ColorToken.accent)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // Double-tap first: the earlier modifier wins, so a single tap declared before it would
        // consume the click and the double never fired.
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel(path: change.relativePath, section: section))
        .accessibilityAddTraits(.isButton)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            if showsStage {
                Button("Stage", action: onStage)
            } else {
                Button("Unstage", action: onUnstage)
            }
            Button("Show Diff", action: onOpen)
            Button("Open File", action: onOpenFile)
            Divider()
            Button("Discard Changes…", action: onRevert)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
    }

    private var fileLabel: some View {
        let path = change.relativePath as NSString
        let detail = presentation.fromPath == nil
            ? path.deletingLastPathComponent
            : presentation.title(path: change.relativePath)
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.hairline) {
            Text(path.lastPathComponent)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if !detail.isEmpty {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(presentation.title(path: change.relativePath))
        .accessibilityHidden(true)
    }

    private var presentation: IDEGitChangePresentation {
        change.presentation(in: section)
    }

    private var rowBackground: Color {
        if isSelected {
            return IDEAppearance.ColorToken.selection
        }
        if isHovering {
            return IDEAppearance.ColorToken.controlHover
        }
        return .clear
    }

    private var letterColor: Color {
        switch IDEGitLetterTint.tint(forLetter: presentation.letter) {
        case .added: IDEAppearance.ColorToken.gitAdded
        case .modified: IDEAppearance.ColorToken.gitModified
        case .deleted: IDEAppearance.ColorToken.error
        case .conflict: IDEAppearance.ColorToken.gitConflict
        case .ignored: IDEAppearance.ColorToken.gitIgnored
        case .muted: IDEAppearance.ColorToken.muted
        }
    }
}
