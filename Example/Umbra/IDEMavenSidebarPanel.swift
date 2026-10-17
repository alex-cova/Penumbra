import AppKit
import JavaIntelligence
import SwiftUI

/// The Maven tool window: profiles, a download banner, and the module tree.
struct IDEMavenSidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var expanded: Set<String> = []
    @State private var selectedID: String?
    @State private var filter = ""
    @State private var isFilterPresented = false
    @State private var isGoalPresented = false
    @State private var goalText = ""
    @FocusState private var goalFocused: Bool
    @FocusState private var filterFocused: Bool

    private var maven: IDEMavenProjectSystem { workspace.maven }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isGoalPresented { goalField }
            if isFilterPresented { filterField }
            content
        }
        .background(IDEAppearance.ColorToken.panel)
        .onChange(of: maven.model?.modules.map(\.path) ?? []) { _, paths in
            for path in paths { expanded.insert("module:\(path)") }
            for path in paths { expanded.insert("\(path)/lifecycle") }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            IDEMavenToolbarButton(systemImage: "arrow.clockwise", help: "Reload Maven Project", action: maven.reload)
            IDEMavenToolbarButton(
                systemImage: "arrow.down.circle",
                help: "Download Sources",
                isDisabled: maven.model == nil || maven.isBusy,
                action: downloadSources
            )
            IDEMavenToolbarButton(
                systemImage: "play",
                help: "Run Goal…",
                isActive: isGoalPresented,
                action: { isGoalPresented.toggle() }
            )
            IDEMavenToolbarButton(
                systemImage: "forward.end",
                help: "Skip Tests",
                isActive: maven.skipTests,
                action: { maven.skipTests.toggle() }
            )
            IDEMavenToolbarButton(
                systemImage: "wifi.slash",
                help: "Offline",
                isActive: maven.offline,
                action: { maven.offline.toggle() }
            )
            IDEMavenToolbarButton(
                systemImage: "line.3.horizontal.decrease",
                help: isFilterPresented ? "Hide Filter" : "Filter",
                isActive: isFilterPresented,
                action: { isFilterPresented.toggle() }
            )
            IDEMavenToolbarButton(systemImage: "text.alignleft", help: "Show Maven Output", action: workspace.showMavenOutput)
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }

    private var goalField: some View {
        IDEMavenInlineField(icon: "play", prompt: "Goal, such as compile", text: $goalText, isFocused: $goalFocused) {
            runTypedGoal()
        } onDismiss: {
            isGoalPresented = false
        }
        .onAppear { goalFocused = true }
    }

    private var filterField: some View {
        IDEMavenInlineField(icon: "magnifyingglass", prompt: "Filter", text: $filter, isFocused: $filterFocused) {} onDismiss: {
            filter = ""
            isFilterPresented = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch maven.syncState {
        case .notDetected:
            placeholder(systemImage: "shippingbox", title: "No Maven Project", message: "Open a folder with a pom.xml.")
        case .awaitingTrust where maven.model == nil:
            placeholder(
                systemImage: "arrow.clockwise",
                title: "Maven Project",
                message: "Maven project detected. Reload to read it.",
                actionTitle: "Reload",
                action: maven.reload
            )
        case .syncing where maven.model == nil:
            placeholder(systemImage: "shippingbox", title: "Reading", message: "Reading pom.xml…")
        case .failed(let summary) where maven.model == nil:
            placeholder(systemImage: "exclamationmark.triangle", title: "Couldn't Read", message: summary, actionTitle: "Reload", action: maven.reload)
        default:
            tree
        }
    }

    private var tree: some View {
        let nodes = maven.model.map(IDEMavenTree.build) ?? []
        let rows = IDEMavenTree.flatten(nodes, expanded: expanded, filter: filter)
        return VStack(spacing: 0) {
            profiles
            if let missing = maven.model?.missing, !missing.isEmpty {
                downloadBanner(count: missing.count)
            }
            if rows.isEmpty {
                Text(filter.isEmpty ? "No modules" : "No matches")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(IDEAppearance.Spacing.lg)
            } else {
                GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                IDEMavenTreeRow(
                                    row: row,
                                    isSelected: selectedID == row.id,
                                    onSelect: {
                                        selectedID = row.id
                                        if row.canDisclose { toggle(row.id) }
                                    },
                                    onActivate: { activate(row.node) }
                                )
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var profiles: some View {
        if let profiles = maven.model?.profiles, !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(profiles, id: \.id) { profile in
                    Toggle(isOn: Binding(
                        get: { profile.active },
                        set: { maven.setProfile(id: profile.id, enabled: $0) }
                    )) {
                        Text(profile.id)
                            .font(IDEAppearance.Typography.caption)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func downloadBanner(count: Int) -> some View {
        let noun = count == 1 ? "dependency isn't" : "dependencies aren't"
        return Button(action: downloadMissing) {
            Text("\(count) \(noun) in your local repository — Download")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
        }
        .buttonStyle(.plain)
        .disabled(maven.isBusy)
    }

    private func placeholder(
        systemImage: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(title)
                .font(IDEAppearance.Typography.body.weight(.medium))
            Text(message)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func activate(_ node: IDEMavenTree.Node) {
        guard let goal = node.goal, let selector = node.moduleSelector else { return }
        workspace.showMavenOutput()
        maven.runGoals([goal], module: selector, extraArguments: [])
    }

    private func runTypedGoal() {
        let goals = JavaCommandLine.split(goalText).filter { !$0.isEmpty }
        guard !goals.isEmpty else { return }
        workspace.showMavenOutput()
        maven.runGoals(goals, module: selectedSelector, extraArguments: [])
        isGoalPresented = false
        goalText = ""
    }

    private var selectedSelector: String? {
        guard let model = maven.model else { return nil }
        if let selectedID, let selector = selector(in: IDEMavenTree.build(model), matching: selectedID) {
            return selector
        }
        return model.modules.first?.selector
    }

    private func selector(in nodes: [IDEMavenTree.Node], matching id: String) -> String? {
        for node in nodes {
            if node.id == id { return node.moduleSelector }
            if let found = selector(in: node.children, matching: id) { return found }
        }
        return nil
    }

    private func downloadSources() {
        workspace.showMavenOutput()
        maven.downloadDependencies(sources: true)
    }

    private func downloadMissing() {
        workspace.showMavenOutput()
        maven.downloadDependencies(sources: false)
    }
}

private struct IDEMavenTreeRow: View {
    let row: IDEMavenTree.Row
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.canDisclose ? (row.isExpanded ? "chevron.down" : "chevron.right") : "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(row.canDisclose ? IDEAppearance.ColorToken.muted : Color.clear)
                .frame(width: 10)
            Image(systemName: row.node.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(row.node.title)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(titleColor)
                .lineLimit(1)
            if !row.node.detail.isEmpty {
                Text(row.node.detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onActivate)
        .accessibilityAddTraits(.isButton)
        .onTapGesture(count: 1, perform: onSelect)
    }

    private var titleColor: Color {
        if row.node.missing { return IDEAppearance.ColorToken.error }
        if row.node.omitted { return IDEAppearance.ColorToken.muted }
        return IDEAppearance.ColorToken.foreground
    }

    private var detailColor: Color {
        row.node.missing ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted
    }

    private var iconColor: Color {
        row.node.missing ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted
    }
}

private struct IDEMavenToolbarButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1, weight: .medium))
                .foregroundStyle(isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton - 2, height: IDEAppearance.Spacing.iconButton)
                .background(isActive ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .focusable(false)
    }
}

private struct IDEMavenInlineField: View {
    let icon: String
    let prompt: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.tabLabel)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: 26)
    }
}

struct IDEMavenTabItem: View {
    let isSelected: Bool
    let isSyncing: Bool
    let isFailed: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 12)
            Text("Maven")
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSyncing ? "Maven, reading" : isFailed ? "Maven, read failed" : "Maven")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isSyncing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else {
            Image(systemName: "shippingbox")
                .font(.system(size: 10))
                .foregroundStyle(isFailed ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
        }
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}

struct IDEMavenConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if workspace.maven.isBusy {
                Button("Cancel", action: workspace.cancelGradleOperation)
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Button(action: workspace.maven.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Reload Maven Project")
                .accessibilityLabel("Reload Maven Project")
            }
            Button(action: copyOutput) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Copy Maven Output")
            .accessibilityLabel("Copy Maven Output")
        }
    }

    private func copyOutput() {
        let text = workspace.maven.console.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
