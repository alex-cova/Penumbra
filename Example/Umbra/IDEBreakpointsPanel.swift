import SwiftUI

/// The sidebar's Breakpoints tab (View Breakpoints, ⇧⌘F8): every breakpoint of the project —
/// line breakpoints by file, then exception, method and field breakpoints — above the selected
/// one's properties. The dot enables or disables one, a double click opens its line.
struct IDEBreakpointsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var newBreakpointKind: IDENewBreakpointKind?

    private struct Group: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let breakpoints: [JavaBreakpoint]
    }

    private var groups: [Group] {
        var result: [Group] = []
        let lines = workspace.breakpoints.filter(\.isLineBreakpoint)
        for (path, entries) in Dictionary(grouping: lines, by: \.filePath)
            .sorted(by: { displayPath($0.key).localizedStandardCompare(displayPath($1.key)) == .orderedAscending }) {
            let folder = (displayPath(path) as NSString).deletingLastPathComponent
            result.append(Group(
                id: path,
                title: (path as NSString).lastPathComponent,
                subtitle: folder.isEmpty ? nil : folder,
                systemImage: IDEFileIcon.systemName(forFilename: (path as NSString).lastPathComponent),
                breakpoints: entries.sorted { $0.line < $1.line }
            ))
        }
        func kindGroup(_ id: String, _ title: String, _ image: String, _ matches: @Sendable (JavaBreakpointKind) -> Bool) {
            let entries = workspace.breakpoints.filter { matches($0.kind) }
            if !entries.isEmpty {
                result.append(Group(id: id, title: title, subtitle: nil, systemImage: image, breakpoints: entries.sorted { $0.title < $1.title }))
            }
        }
        kindGroup("exception", "Java Exception Breakpoints", "bolt.fill") { if case .exception = $0 { return true } else { return false } }
        kindGroup("method", "Java Method Breakpoints", "m.square") { if case .method = $0 { return true } else { return false } }
        kindGroup("field", "Java Field Watchpoints", "eye") { if case .field = $0 { return true } else { return false } }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if workspace.breakpoints.isEmpty {
                emptyState
            } else {
                SplitPanes(axis: .vertical, minPrimary: 120, minSecondary: 160, storageKey: "umbra.breakpoints.detailSplit") {
                    list
                } secondary: {
                    detail
                } divider: {
                    Splitter.rule()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
        .sheet(item: $newBreakpointKind) { kind in
            IDENewBreakpointSheet(kind: kind) { breakpoint in
                workspace.addBreakpoint(breakpoint)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(countLabel)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, IDEAppearance.Spacing.xs)
            Spacer(minLength: 0)
            Menu {
                Button("Java Exception Breakpoint…") { newBreakpointKind = .exception }
                Button("Java Method Breakpoint…") { newBreakpointKind = .method }
                Button("Java Field Watchpoint…") { newBreakpointKind = .field }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Breakpoint")
            IDEExplorerToolbarButton(
                systemImage: workspace.breakpointsMuted ? "circle.slash.fill" : "circle.slash",
                help: workspace.breakpointsMuted ? "Unmute Breakpoints" : "Mute Breakpoints"
            ) {
                workspace.toggleBreakpointsMuted()
            }
            IDEExplorerToolbarButton(systemImage: "trash", help: "Remove All Breakpoints") {
                workspace.removeAllBreakpoints()
            }
            .disabled(workspace.breakpoints.isEmpty)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    header(group)
                    ForEach(group.breakpoints) { breakpoint in
                        IDEBreakpointRow(
                            breakpoint: breakpoint,
                            isSelected: workspace.selectedBreakpointID == breakpoint.id,
                            isMuted: workspace.breakpointsMuted,
                            onSelect: { workspace.selectedBreakpointID = breakpoint.id },
                            onOpen: { workspace.openBreakpoint(breakpoint) },
                            onToggle: { workspace.setBreakpointEnabled(breakpoint, enabled: !breakpoint.isEnabled) },
                            onRemove: { workspace.removeBreakpoint(breakpoint) }
                        )
                    }
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = workspace.selectedBreakpointID, let breakpoint = workspace.breakpoints.first(where: { $0.id == id }) {
            ScrollView {
                IDEBreakpointDetail(breakpoint: breakpoint)
                    .id(breakpoint.id)
                    .padding(IDEAppearance.Spacing.sm)
            }
        } else {
            Text("Select a breakpoint to edit it.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var countLabel: String {
        let count = workspace.breakpoints.count
        let text = count == 1 ? "1 breakpoint" : "\(count) breakpoints"
        return workspace.breakpointsMuted ? text + " (muted)" : text
    }

    private func header(_ group: Group) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: group.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(group.title)
                .font(IDEAppearance.Typography.tabLabel.weight(.medium))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            if let subtitle = group.subtitle {
                Text(subtitle)
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
        .help(group.id)
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
            Text("Click a line number of a Java file, or press F3, to add one.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

/// The detail pane's editor for one breakpoint; a new one per selection.
private struct IDEBreakpointDetail: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var editor: IDEBreakpointEditor?
    let breakpoint: JavaBreakpoint

    var body: some View {
        Group {
            if let editor {
                IDEBreakpointPropertiesForm(editor: editor)
            }
        }
        .onAppear {
            let workspace = workspace
            editor = IDEBreakpointEditor(breakpoint: breakpoint) { updated in
                workspace.updateBreakpoint(updated)
            }
        }
        .onDisappear { editor?.commitDrafts() }
    }
}

private struct IDEBreakpointRow: View {
    let breakpoint: JavaBreakpoint
    let isSelected: Bool
    let isMuted: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(breakpoint.isEnabled && !isMuted ? color : IDEAppearance.ColorToken.muted)
                    .frame(width: 14, height: IDEAppearance.Spacing.iconButton - 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(breakpoint.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint")
            .accessibilityLabel(breakpoint.isEnabled ? "Disable breakpoint" : "Enable breakpoint")

            Text(breakpoint.isLineBreakpoint ? "Line \(breakpoint.line)" : breakpoint.title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(breakpoint.isEnabled ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
            if let condition = breakpoint.activeCondition {
                Text(condition)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

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
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(breakpoint.isEnabled ? "Disable" : "Enable", action: onToggle)
            if breakpoint.isLineBreakpoint {
                Button("Go to Source", action: onOpen)
            }
            Button("Remove", action: onRemove)
        }
    }

    private var symbol: String {
        if breakpoint.suspendPolicy == .none { return breakpoint.isEnabled ? "diamond.fill" : "diamond" }
        return breakpoint.isEnabled ? "circle.fill" : "circle"
    }

    private var color: Color {
        breakpoint.suspendPolicy == .none ? .orange : IDEAppearance.ColorToken.error
    }
}

enum IDENewBreakpointKind: String, Identifiable {
    case exception, method, field
    var id: String { rawValue }
}

/// Asks for the class (and method or field) of a new exception, method or field breakpoint.
private struct IDENewBreakpointSheet: View {
    let kind: IDENewBreakpointKind
    let onAdd: (JavaBreakpoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var className = ""
    @State private var memberName = ""
    @State private var anyException = false

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(title).font(IDEAppearance.Typography.body.weight(.semibold))
            if kind == .exception {
                Toggle("Any exception", isOn: $anyException)
            }
            TextField(kind == .exception ? "Exception class, e.g. java.lang.IllegalStateException" : "Class, e.g. com.acme.Service",
                      text: $className)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .disabled(kind == .exception && anyException)
            if kind != .exception {
                TextField(kind == .method ? "Method name" : "Field name", text: $memberName)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }
            Text("Binary names for nested classes: com.acme.Outer$Inner.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(breakpoint)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 420)
    }

    private var title: String {
        switch kind {
        case .exception: return "New Java Exception Breakpoint"
        case .method: return "New Java Method Breakpoint"
        case .field: return "New Java Field Watchpoint"
        }
    }

    private var trimmedClass: String { className.trimmingCharacters(in: .whitespaces) }
    private var trimmedMember: String { memberName.trimmingCharacters(in: .whitespaces) }

    private var isComplete: Bool {
        switch kind {
        case .exception: return anyException || !trimmedClass.isEmpty
        case .method, .field: return !trimmedClass.isEmpty && !trimmedMember.isEmpty
        }
    }

    private var breakpoint: JavaBreakpoint {
        let breakpointKind: JavaBreakpointKind = switch kind {
        case .exception: .exception(className: anyException ? "" : trimmedClass, caught: true, uncaught: true)
        case .method: .method(className: trimmedClass, methodName: trimmedMember)
        case .field: .field(className: trimmedClass, fieldName: trimmedMember, access: false, modification: true)
        }
        return JavaBreakpoint(filePath: "", line: 0, kind: breakpointKind)
    }
}
