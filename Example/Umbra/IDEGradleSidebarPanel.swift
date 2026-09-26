import AppKit
import JavaIntelligence
import SwiftUI

/// IntelliJ-style Gradle tool window: one tree (project → Tasks / Dependencies / Source Sets →
/// nested modules), a compact icon toolbar, one-line rows, keyboard navigation, and
/// double-click to run.
struct IDEGradleSidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var isFilterPresented = false
    @State private var filterQuery = ""
    @State private var isRunFieldPresented = false
    @State private var runText = ""
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isRunFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var collapsedWhileFiltering: Set<String> = []
    @State private var selectedID: String?
    @State private var didSeedExpansion = false

    private var java: IDEJavaSupport { workspace.javaSupport }

    private var root: IDEGradleTreeNode? {
        java.gradleModel.flatMap { IDEGradleTree.build(from: $0) }
    }

    private var filterNeedle: String {
        filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isFilterPresented {
                IDEGradleInlineField(
                    icon: "magnifyingglass",
                    prompt: "Filter tasks and dependencies",
                    text: $filterQuery,
                    isFocused: $isFilterFocused,
                    onSubmit: {},
                    onDismiss: dismissFilter
                )
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }

            if isRunFieldPresented {
                IDEGradleInlineField(
                    icon: "play.fill",
                    prompt: "Run tasks, e.g. clean :app:build",
                    text: $runText,
                    isFocused: $isRunFocused,
                    onSubmit: runTypedTasks,
                    onDismiss: dismissRunField
                )
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }

            if java.gradleSync.isSyncing, java.gradleModel != nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
        .onChange(of: root?.id, initial: true) { _, id in
            guard let root, id != nil else {
                expanded.removeAll()
                collapsedWhileFiltering.removeAll()
                selectedID = nil
                didSeedExpansion = false
                return
            }
            guard !didSeedExpansion else { return }
            didSeedExpansion = true
            expanded = [root.id]
            if let tasks = root.children.first(where: { if case .tasks = $0.kind { true } else { false } }) {
                expanded.insert(tasks.id)
            }
        }
        .onChange(of: filterNeedle) { _, _ in
            collapsedWhileFiltering.removeAll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Text("Gradle")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if java.isGradleBusy {
                IDEGradleToolbarButton(
                    systemImage: "stop.fill",
                    help: "Stop",
                    tint: IDEAppearance.ColorToken.error,
                    action: workspace.cancelGradleOperation
                )
            } else {
                IDEGradleToolbarButton(
                    systemImage: "arrow.clockwise",
                    help: "Reload All Gradle Projects",
                    action: workspace.reloadGradleProject
                )
            }

            if root != nil {
                IDEGradleToolbarButton(
                    systemImage: "rectangle.expand.vertical",
                    help: "Expand All",
                    action: expandAll
                )
                IDEGradleToolbarButton(
                    systemImage: "rectangle.compress.vertical",
                    help: "Collapse All",
                    action: collapseAll
                )
                IDEGradleToolbarButton(
                    systemImage: "play",
                    help: "Run Gradle Task…",
                    isActive: isRunFieldPresented,
                    isDisabled: java.isGradleBusy,
                    action: toggleRunField
                )
                IDEGradleToolbarButton(
                    systemImage: "magnifyingglass",
                    help: isFilterPresented ? "Hide Filter" : "Filter",
                    isActive: isFilterPresented,
                    action: toggleFilter
                )
            }

            IDEGradleToolbarButton(
                systemImage: "text.alignleft",
                help: "Show Gradle Output",
                action: workspace.showGradleOutput
            )
        }
        .padding(.leading, IDEAppearance.Spacing.lg)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch java.gradleSync {
        case .awaitingTrust:
            IDEGradleSidebarPlaceholder(
                systemImage: "lock.shield",
                title: "Trust Required",
                message: "Trust this project to resolve Gradle modules and dependencies.",
                actionTitle: "Trust & Sync…",
                action: workspace.reloadGradleProject
            )
        case .untrusted:
            IDEGradleSidebarPlaceholder(
                systemImage: "lock.slash",
                title: "Project Untrusted",
                message: "Gradle build scripts were not approved for this project.",
                actionTitle: "Reload…",
                action: workspace.reloadGradleProject
            )
        case .failed(let summary):
            IDEGradleSidebarPlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Sync Failed",
                message: summary,
                actionTitle: "Retry",
                action: workspace.reloadGradleProject,
                secondaryTitle: "Show Output",
                secondaryAction: workspace.showGradleOutput
            )
        case .notGradle:
            IDEGradleSidebarPlaceholder(
                systemImage: "shippingbox",
                title: "Not a Gradle Project",
                message: "Open a folder containing Gradle build files."
            )
        case .syncing, .synced:
            if let root {
                IDEGradleTreeView(
                    root: root,
                    expanded: $expanded,
                    collapsedWhileFiltering: $collapsedWhileFiltering,
                    selectedID: $selectedID,
                    filter: filterNeedle,
                    isBusy: java.isGradleBusy,
                    runningTaskPaths: Set(java.runningGradleTaskPaths),
                    actions: treeActions
                )
            } else {
                IDEGradleSidebarPlaceholder(
                    systemImage: nil,
                    title: "Syncing…",
                    message: java.statusMessage ?? "Resolving Gradle project model.",
                    showsSpinner: true
                )
            }
        }
    }

    private var treeActions: IDEGradleTreeActions {
        IDEGradleTreeActions(
            runTask: { workspace.runGradleTask($0) },
            reveal: { workspace.revealInExplorer($0) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            copy: { string in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            },
            reload: workspace.reloadGradleProject,
            module: { path in
                java.gradleModel?.subprojects.first { $0.path == path }?.directory
            },
            prefillRun: { task in
                runText = task
                isRunFieldPresented = true
                isRunFocused = true
            }
        )
    }

    // MARK: Toolbar actions

    private func expandAll() {
        guard let root else { return }
        expanded = IDEGradleTree.containerIDs(in: root)
        collapsedWhileFiltering.removeAll()
    }

    private func collapseAll() {
        guard let root else { return }
        expanded = [root.id]
        collapsedWhileFiltering = filterNeedle.isEmpty ? [] : IDEGradleTree.containerIDs(in: root)
    }

    private func toggleFilter() {
        if isFilterPresented {
            dismissFilter()
        } else {
            withAnimation(.easeOut(duration: 0.16)) { isFilterPresented = true }
        }
    }

    private func dismissFilter() {
        guard isFilterPresented else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            isFilterPresented = false
            filterQuery.removeAll()
        }
        isFilterFocused = false
    }

    private func toggleRunField() {
        if isRunFieldPresented {
            dismissRunField()
        } else {
            if runText.isEmpty,
               let root, let selectedID,
               let node = IDEGradleTree.find(selectedID, in: root),
               case .task(let task) = node.kind {
                runText = task.path
            }
            withAnimation(.easeOut(duration: 0.16)) { isRunFieldPresented = true }
        }
    }

    private func dismissRunField() {
        guard isRunFieldPresented else { return }
        withAnimation(.easeOut(duration: 0.16)) { isRunFieldPresented = false }
        isRunFocused = false
    }

    private func runTypedTasks() {
        let tasks = runText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tasks.isEmpty, !java.isGradleBusy else { return }
        workspace.showGradleOutput()
        java.runGradleTasks(tasks)
        dismissRunField()
    }
}

// MARK: - Tree

struct IDEGradleTreeActions {
    var runTask: (String) -> Void = { _ in }
    var reveal: (URL) -> Void = { _ in }
    var revealInFinder: (URL) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    var reload: () -> Void = {}
    var module: (String) -> URL? = { _ in nil }
    var prefillRun: (String) -> Void = { _ in }
}

struct IDEGradleTreeView: View {
    let root: IDEGradleTreeNode
    @Binding var expanded: Set<String>
    @Binding var collapsedWhileFiltering: Set<String>
    @Binding var selectedID: String?
    var filter = ""
    var isBusy = false
    var runningTaskPaths: Set<String> = []
    var actions = IDEGradleTreeActions()

    var body: some View {
        let rows = IDEGradleTree.flatten(
            root, expanded: expanded, filter: filter, collapsedWhileFiltering: collapsedWhileFiltering
        )
        if rows.isEmpty {
            Text("No matches")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.lg)
                .padding(.top, IDEAppearance.Spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                IDEGradleTreeRowView(
                                    row: row,
                                    isSelected: selectedID == row.id,
                                    isRunning: runningPath(of: row.node).map(runningTaskPaths.contains) ?? false,
                                    isRunDisabled: isBusy,
                                    onToggle: { toggle(row) },
                                    onSelect: {
                                        selectedID = row.id
                                        if row.canDisclose { toggle(row) }
                                    },
                                    onActivate: { activate(row.node) },
                                    menu: { menu(for: row) }
                                )
                                .id(row.id)
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, rows: rows, scroller: scroller)
                    }
                }
            }
        }
    }

    private func runningPath(of node: IDEGradleTreeNode) -> String? {
        if case .task(let task) = node.kind { return task.path }
        return nil
    }

    // MARK: Expansion

    private func toggle(_ row: IDEGradleTree.Row) {
        if filter.isEmpty {
            expanded.formSymmetricDifference([row.id])
        } else {
            collapsedWhileFiltering.formSymmetricDifference([row.id])
        }
    }

    private func setSubtree(_ node: IDEGradleTreeNode, open: Bool) {
        let ids = IDEGradleTree.containerIDs(in: node)
        if filter.isEmpty {
            if open { expanded.formUnion(ids) } else { expanded.subtract(ids) }
        } else if open {
            collapsedWhileFiltering.subtract(ids)
        } else {
            collapsedWhileFiltering.formUnion(ids)
        }
    }

    // MARK: Activation

    private func activate(_ node: IDEGradleTreeNode) {
        switch node.kind {
        case .task(let task):
            guard !isBusy else { return }
            actions.runTask(task.path)
        case .project(let subproject):
            actions.reveal(subproject.directory)
        case .sourceDirectory(let url, _):
            actions.reveal(url)
        case .jar(let url):
            actions.revealInFinder(url)
        case .projectDependency(let dependency):
            if let directory = actions.module(dependency.projectPath) { actions.reveal(directory) }
        default:
            break
        }
    }

    // MARK: Keyboard

    private func handleKey(
        _ press: KeyPress,
        rows: [IDEGradleTree.Row],
        scroller: ScrollViewProxy
    ) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == selectedID }
        let current = index.map { rows[$0] }

        func select(_ target: Int) {
            let id = rows[target].id
            selectedID = id
            scroller.scrollTo(id)
        }

        switch press.key {
        case .upArrow:
            select(index.map { max($0 - 1, 0) } ?? 0)
            return .handled
        case .downArrow:
            select(index.map { min($0 + 1, rows.count - 1) } ?? 0)
            return .handled
        case .rightArrow:
            guard let current, current.canDisclose, !current.isExpanded else { return .ignored }
            toggle(current)
            return .handled
        case .leftArrow:
            guard let current, let index else { return .ignored }
            if current.canDisclose, current.isExpanded {
                toggle(current)
            } else if let parent = rows[..<index].lastIndex(where: { $0.depth < current.depth }) {
                select(parent)
            }
            return .handled
        case .return:
            guard let current else { return .ignored }
            if case .task = current.node.kind {
                activate(current.node)
            } else if current.canDisclose {
                toggle(current)
            } else {
                activate(current.node)
            }
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for row: IDEGradleTree.Row) -> some View {
        let node = row.node
        switch node.kind {
        case .task(let task):
            Button("Run '\(task.name)'") { actions.runTask(task.path) }
                .disabled(isBusy)
            Button("Run Gradle Task…") { actions.prefillRun(task.path) }
                .disabled(isBusy)
            Divider()
            Button("Copy Task Path") { actions.copy(task.path) }
        case .project(let subproject):
            Button("Reveal in Explorer") { actions.reveal(subproject.directory) }
            Button("Reload Gradle Project") { actions.reload() }
            Divider()
            subtreeItems(node)
        case .jar(let url):
            Button("Reveal in Finder") { actions.revealInFinder(url) }
            Button("Copy Path") { actions.copy(url.path) }
            if let coordinate = IDEGradleTree.mavenCoordinate(for: url) {
                Button("Copy Coordinates") { actions.copy(coordinate) }
            }
        case .sourceDirectory(let url, _):
            Button("Reveal in Explorer") { actions.reveal(url) }
            Button("Copy Path") { actions.copy(url.path) }
        case .projectDependency(let dependency):
            Button("Reveal Module in Explorer") {
                if let directory = actions.module(dependency.projectPath) { actions.reveal(directory) }
            }
        case .unresolved:
            Button("Copy") { actions.copy(node.title) }
        default:
            if node.isContainer { subtreeItems(node) }
        }
    }

    @ViewBuilder
    private func subtreeItems(_ node: IDEGradleTreeNode) -> some View {
        Button("Expand Subtree") { setSubtree(node, open: true) }
        Button("Collapse Subtree") { setSubtree(node, open: false) }
    }
}

// MARK: - Row

private struct IDEGradleTreeRowView<Menu: View>: View {
    let row: IDEGradleTree.Row
    let isSelected: Bool
    let isRunning: Bool
    let isRunDisabled: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    private var node: IDEGradleTreeNode { row.node }

    private var isTask: Bool {
        if case .task = node.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if row.canDisclose {
                Button(action: onToggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
            } else {
                Spacer().frame(width: 12)
            }

            icon
                .frame(width: 14)

            Text(node.title)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let detail = node.detail, !detail.isEmpty {
                Text(detail)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)

            if isTask, isHovering, !isRunning, !isRunDisabled {
                Button(action: onActivate) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(IDEAppearance.ColorToken.run)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Run \(node.title)")
                .accessibilityLabel("Run \(node.title)")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 4)
        .background(background)
        .contentShape(Rectangle())
        .opacity(isTask && isRunDisabled && !isRunning ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .help(node.help ?? node.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { menu() }
    }

    private var background: Color {
        if isSelected { return IDEAppearance.ColorToken.selection }
        return isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear
    }

    private var titleColor: Color {
        switch node.kind {
        case .unresolved, .unresolvedGroup: IDEAppearance.ColorToken.error
        default: IDEAppearance.ColorToken.foreground
        }
    }

    @ViewBuilder
    private var icon: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .tint(IDEAppearance.ColorToken.accent)
        } else {
            Image(systemName: symbol.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(symbol.tint)
        }
    }

    private var symbol: (name: String, tint: Color) {
        let muted = IDEAppearance.ColorToken.muted
        switch node.kind {
        case .project: return ("shippingbox.fill", IDEAppearance.ColorToken.accent)
        case .tasks: return ("gearshape.2", muted)
        case .taskGroup: return ("folder", muted)
        case .task: return ("gearshape", IDEAppearance.ColorToken.run)
        case .dependencies: return ("books.vertical", muted)
        case .configuration(let sourceSet): return ("list.bullet.indent", Self.tint(for: sourceSet))
        case .projectDependency: return ("shippingbox", muted)
        case .jar: return ("archivebox", muted)
        case .unresolvedGroup: return ("exclamationmark.triangle.fill", IDEAppearance.ColorToken.error)
        case .unresolved: return ("xmark.octagon", IDEAppearance.ColorToken.error)
        case .sourceSets: return ("folder.badge.gearshape", muted)
        case .sourceSet(let name): return (Self.isTest(name) ? "flask" : "folder", Self.tint(for: name))
        case .sourceDirectory(_, let sourceSet): return ("folder", Self.tint(for: sourceSet))
        }
    }

    private static func isTest(_ name: String) -> Bool {
        name.lowercased().contains("test")
    }

    private static func tint(for sourceSet: String) -> Color {
        isTest(sourceSet) ? IDEAppearance.ColorToken.testSourceRoot : IDEAppearance.ColorToken.sourceRoot
    }
}

// MARK: - Chrome

private struct IDEGradleToolbarButton: View {
    let systemImage: String
    let help: String
    var tint: Color?
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: IDEAppearance.Spacing.iconButton - 2, height: IDEAppearance.Spacing.iconButton)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .focusable(false)
    }

    private var foreground: Color {
        if let tint { return tint }
        return isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted
    }

    private var background: Color {
        if isActive { return IDEAppearance.ColorToken.selection }
        return isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear
    }
}

private struct IDEGradleInlineField: View {
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
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.tabLabel)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: 24)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                .strokeBorder(
                    isFocused.wrappedValue ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border,
                    lineWidth: 1
                )
        }
        .task { isFocused.wrappedValue = true }
        .onExitCommand(perform: onDismiss)
    }
}

private struct IDEGradleSidebarPlaceholder: View {
    var systemImage: String?
    let title: String
    let message: String
    var showsSpinner = false
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Text(title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(message)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.lg)
        .padding(.top, IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preview

#Preview {
    struct Harness: View {
        @State var expanded: Set<String> = []
        @State var collapsed: Set<String> = []
        @State var selected: String?
        let root: IDEGradleTreeNode

        init() {
            let base = URL(fileURLWithPath: "/tmp/demo")
            let guava = URL(fileURLWithPath: "/tmp/g/modules-2/files-2.1/com.google.guava/guava/33.0-jre/h/guava.jar")
            let model = JavaGradleProjectModel(
                formatVersion: 3,
                gradleVersion: "8.10",
                subprojects: [
                    .init(path: ":", directory: base, tasks: [
                        .init(path: ":build", name: "build", group: "build", description: "Assembles and tests."),
                        .init(path: ":clean", name: "clean", group: "build")
                    ]),
                    .init(path: ":app", directory: base.appendingPathComponent("app"), languageLevel: 21,
                          sourceSets: [
                            .init(name: "main", sourceDirs: [base.appendingPathComponent("app/src/main/java")],
                                  compileClasspathJars: [guava],
                                  projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")]),
                            .init(name: "test", sourceDirs: [base.appendingPathComponent("app/src/test/java")])
                          ],
                          tasks: [.init(path: ":app:run", name: "run", group: "application")]),
                    .init(path: ":lib", directory: base.appendingPathComponent("lib"), languageLevel: 21)
                ],
                unresolved: ["org.example:missing:1.0"]
            )
            root = IDEGradleTree.build(from: model)!
            _expanded = State(initialValue: IDEGradleTree.containerIDs(in: root))
        }

        var body: some View {
            IDEGradleTreeView(
                root: root, expanded: $expanded, collapsedWhileFiltering: $collapsed,
                selectedID: $selected, runningTaskPaths: [":build"]
            )
            .background(IDEAppearance.ColorToken.sidebar)
        }
    }
    return Harness()
        .frame(width: 260, height: 520)
        .preferredColorScheme(.dark)
}
