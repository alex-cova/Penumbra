import SwiftUI

/// The History tab of the left sidebar: the active file's earlier revisions, or the recent changes of
/// every file grouped by what caused them. Compare opens the diff viewer; revert goes through the editor.
struct IDELocalHistoryPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var events: [IDELocalHistoryEvent] = []
    @State private var selection: UUID?
    @State private var agentOnly = false
    @State private var isLoaded = false

    private var recorder: IDELocalHistoryRecorder { workspace.localHistory }
    private var showsProject: Bool { workspace.localHistoryShowsProject }

    private var activeURL: URL? { workspace.workbench.activePane.selectedDocument?.url }
    private var activePath: String? { activeURL.flatMap(recorder.relativePath(of:)) }

    private struct ReloadKey: Equatable {
        var revision: Int
        var path: String?
        var project: Bool
        var hasStore: Bool
    }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            header
            Divider().overlay(IDEAppearance.ColorToken.border)
            content
            if let selected = selectedEvent, !showsProject {
                Divider().overlay(IDEAppearance.ColorToken.border)
                actions(for: selected)
            }
        }
        .task(id: ReloadKey(revision: recorder.revision, path: activePath, project: showsProject, hasStore: recorder.store != nil)) {
            await reload()
        }
    }

    private var visibleEvents: [IDELocalHistoryEvent] {
        agentOnly ? events.filter(IDELocalHistoryPresentation.isAgent) : events
    }

    private var selectedEvent: IDELocalHistoryEvent? { events.first { $0.id == selection } }

    // MARK: - Header

    private var header: some View {
        @Bindable var workspace = workspace
        return VStack(spacing: IDEAppearance.Spacing.xs) {
            Picker("", selection: $workspace.localHistoryShowsProject) {
                Text("This File").tag(false)
                Text("Recent Changes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Toggle("Agent changes only", isOn: $agentOnly)
                    .toggleStyle(.checkbox)
                    .font(IDEAppearance.Typography.caption)
                Spacer()
                Button {
                    workspace.putLocalHistoryLabel()
                } label: {
                    Image(systemName: "tag")
                }
                .buttonStyle(.borderless)
                .help("Put Label on This Version…")
                .accessibilityLabel("Put Label")
                .disabled(activePath == nil)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !workspace.hasOpenProject {
            message("Open a folder to keep a history of its files.")
        } else if recorder.store == nil {
            message("Local History is off for this window.")
        } else if !showsProject, activePath == nil {
            message("Open a file in the project to see its earlier versions.")
        } else if isLoaded, visibleEvents.isEmpty {
            message(agentOnly ? "No changes by the agent." : showsProject ? "Nothing has changed yet." : "No earlier versions yet. One is added each time you save.")
        } else if showsProject {
            projectList
        } else {
            fileList
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .multilineTextAlignment(.center)
            .padding(IDEAppearance.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(IDELocalHistoryPresentation.byDay(visibleEvents, time: \.time), id: \.heading) { section in
                    Text(section.heading)
                        .font(IDEAppearance.Typography.sectionHeader)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.top, IDEAppearance.Spacing.sm)
                    ForEach(section.items) { event in
                        row(event, showsPath: false)
                    }
                }
            }
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(IDELocalHistoryPresentation.byDay(IDELocalHistoryPresentation.groups(visibleEvents), time: \.time), id: \.heading) { section in
                    Text(section.heading)
                        .font(IDEAppearance.Typography.sectionHeader)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.top, IDEAppearance.Spacing.sm)
                    ForEach(section.items) { group in
                        groupRow(group)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func row(_ event: IDELocalHistoryEvent, showsPath: Bool) -> some View {
        let isSelected = event.id == selection
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: IDELocalHistoryPresentation.symbol(for: event.source, label: event.label))
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph))
                .foregroundStyle(event.source.isAgent ? Color.teal : IDEAppearance.ColorToken.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(IDELocalHistoryPresentation.title(for: event.source, label: event.label))
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(showsPath ? event.path : IDELocalHistoryPresentation.time(event.time))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if showsPath {
                Text(IDELocalHistoryPresentation.time(event.time))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 4)
        .background(isSelected ? IDEAppearance.ColorToken.controlHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.localHistoryOpenDiff(event, against: .current) }
        .onTapGesture { selection = event.id }
        .contextMenu { menu(for: event) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func groupRow(_ group: IDELocalHistoryPresentation.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: IDELocalHistoryPresentation.symbol(for: group.source, label: group.events[0].label))
                    .font(.system(size: IDEAppearance.IconSize.toolbarGlyph))
                    .foregroundStyle(group.source.isAgent ? Color.teal : IDEAppearance.ColorToken.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(IDELocalHistoryPresentation.title(for: group.source, label: group.events[0].label))
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                    Text(IDELocalHistoryPresentation.summary(of: group))
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(IDELocalHistoryPresentation.time(group.time))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Undo This Action (\(group.events.count) \(group.events.count == 1 ? "change" : "changes"))") {
                    Task { await workspace.localHistoryUndo(group: group) }
                }
            }
            if group.events.count > 1 || !group.paths.isEmpty {
                ForEach(group.events) { event in
                    row(event, showsPath: true)
                        .padding(.leading, IDEAppearance.Spacing.md)
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder private func menu(for event: IDELocalHistoryEvent) -> some View {
        Button("Compare with Current") { workspace.localHistoryOpenDiff(event, against: .current) }
        Button("Show This Change") { workspace.localHistoryOpenDiff(event, against: .previous) }
        Divider()
        Button("Revert to This Revision") { Task { await workspace.localHistoryRevert(toRevision: event) } }
        Button("Undo This Change") { Task { await workspace.localHistoryUndo(event) } }
            .disabled(event.source == .baseline)
    }

    private func actions(for event: IDELocalHistoryEvent) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button("Compare") { workspace.localHistoryOpenDiff(event, against: .current) }
            Button("Revert") { Task { await workspace.localHistoryRevert(toRevision: event) } }
                .help("Put the file back to how it was after this revision")
            Spacer()
        }
        .controlSize(.small)
        .padding(IDEAppearance.Spacing.sm)
    }

    // MARK: - Loading

    private func reload() async {
        guard let store = recorder.store else {
            events = []
            isLoaded = true
            return
        }
        if showsProject {
            events = await store.recentEvents(limit: 300)
        } else if let path = activePath {
            events = await store.events(forPath: path)
        } else {
            events = []
        }
        if let selection, !events.contains(where: { $0.id == selection }) { self.selection = nil }
        isLoaded = true
    }
}
