import SwiftUI

/// The sidebar's Breakpoints tab: every breakpoint of the project, grouped by file. The dot
/// enables or disables one (a disabled breakpoint stays in the list and shows hollow in the
/// gutter), a click opens its line.
struct IDEBreakpointsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    private struct FileGroup: Identifiable {
        let path: String
        let breakpoints: [JavaBreakpoint]
        var id: String { path }
    }

    private var groups: [FileGroup] {
        Dictionary(grouping: workspace.breakpoints, by: \.filePath)
            .map { FileGroup(path: $0.key, breakpoints: $0.value.sorted { $0.line < $1.line }) }
            .sorted { displayPath($0.path).localizedStandardCompare(displayPath($1.path)) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if workspace.breakpoints.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            fileHeader(group)
                            ForEach(group.breakpoints) { breakpoint in
                                IDEBreakpointRow(
                                    breakpoint: breakpoint,
                                    onOpen: { workspace.openBreakpoint(breakpoint) },
                                    onToggle: {
                                        workspace.setBreakpointEnabled(breakpoint, enabled: !breakpoint.isEnabled)
                                    },
                                    onRemove: { workspace.removeBreakpoint(breakpoint) }
                                )
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(countLabel)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, IDEAppearance.Spacing.xs)
            Spacer(minLength: 0)
            IDEExplorerToolbarButton(systemImage: "trash", help: "Remove All Breakpoints") {
                workspace.removeAllBreakpoints()
            }
            .disabled(workspace.breakpoints.isEmpty)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)
    }

    private var countLabel: String {
        let count = workspace.breakpoints.count
        return count == 1 ? "1 breakpoint" : "\(count) breakpoints"
    }

    private func fileHeader(_ group: FileGroup) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: IDEFileIcon.systemName(forFilename: (group.path as NSString).lastPathComponent))
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text((group.path as NSString).lastPathComponent)
                .font(IDEAppearance.Typography.tabLabel.weight(.medium))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            let folder = (displayPath(group.path) as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.top, IDEAppearance.Spacing.sm)
        .padding(.bottom, 2)
        .help(group.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The path relative to the project folder, or the bare file name for a file outside it.
    private func displayPath(_ path: String) -> String {
        guard let root = workspace.project.rootURL?.standardizedFileURL.path, path.hasPrefix(root + "/") else {
            return (path as NSString).lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    private var emptyState: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("No breakpoints")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("Click the gutter of a Java file to add one.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

private struct IDEBreakpointRow: View {
    let breakpoint: JavaBreakpoint
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button(action: onToggle) {
                Image(systemName: breakpoint.isEnabled ? "circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(breakpoint.isEnabled ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    .frame(width: 14, height: IDEAppearance.Spacing.iconButton - 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(breakpoint.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint")
            .accessibilityLabel(breakpoint.isEnabled ? "Disable breakpoint" : "Enable breakpoint")

            Text("Line \(breakpoint.line)")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(breakpoint.isEnabled ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove Breakpoint")
                .accessibilityLabel("Remove breakpoint")
            }
        }
        .padding(.leading, IDEAppearance.Spacing.sm + IDEAppearance.Spacing.md)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(breakpoint.isEnabled ? "Disable" : "Enable", action: onToggle)
            Button("Remove", action: onRemove)
        }
    }
}
