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
    private var scope: IDELocalHistoryScope { workspace.localHistoryScope }

    private var activeURL: URL? { workspace.workbench.activePane.selectedDocument?.url }
    private var activePath: String? { activeURL.flatMap(recorder.relativePath(of:)) }

    /// The file the file view lists: a pin, or the active editor.
    private var shownFilePath: String? {
        if case .file = scope { return workspace.localHistoryFile ?? activePath }
        return nil
    }

    private struct ReloadKey: Equatable {
        var revision: Int
        var path: String?
        var scope: IDELocalHistoryScope
        var hasStore: Bool
    }

    private enum Segment: Hashable {
        case file, folder, project
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(IDEAppearance.ColorToken.border)
            content
            if let selected = selectedEvent, case .file = scope {
                Divider().overlay(IDEAppearance.ColorToken.border)
                actions(for: selected)
            }
        }
        .task(id: ReloadKey(revision: recorder.revision, path: trackedPath, scope: scope, hasStore: recorder.store != nil)) {
            await reload()
        }
    }

    /// What a reload should follow. A pinned file ignores whichever editor is active.
    private var trackedPath: String? {
        switch scope {
        case .file: shownFilePath
        case .folder(let path): path
        case .project: nil
        }
    }

    private var visibleEvents: [IDELocalHistoryEvent] {
        agentOnly ? events.filter(IDELocalHistoryPresentation.isAgent) : events
    }

    private var selectedEvent: IDELocalHistoryEvent? { events.first { $0.id == selection } }

    // MARK: - Header

    private var segment: Binding<Segment> {
        Binding(
            get: {
                switch workspace.localHistoryScope {
                case .file: .file
                case .folder: .folder
                case .project: .project
                }
            },
            set: { next in
                switch next {
                case .file:
                    workspace.localHistoryFile = nil
                    workspace.localHistoryScope = .file
                case .folder:
                    break
                case .project:
                    workspace.localHistoryFile = nil
                    workspace.localHistoryScope = .project
                }
            }
        )
    }

    private var scopeCaption: String? {
        switch scope {
        case .folder(let path): path
        case .file: workspace.localHistoryFile
        case .project: nil
        }
    }

    private var header: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Picker("", selection: segment) {
                Text("This File").tag(Segment.file)
                if case .folder = scope {
                    Text("This Folder").tag(Segment.folder)
                }
                Text("Recent Changes").tag(Segment.project)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let scopeCaption {
                Text(scopeCaption)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        } else if case .file = scope, shownFilePath == nil {
            message("Open a file in the project to see its earlier versions.")
        } else if isLoaded, visibleEvents.isEmpty {
            message(emptyMessage)
        } else if case .project = scope {
            projectList
        } else if case .folder = scope {
            fileList(showsPath: true)
        } else {
            fileList(showsPath: false)
        }
    }

    private var emptyMessage: String {
        if agentOnly { return "No changes by the agent." }
        switch scope {
        case .project: return "Nothing has changed yet."
        case .folder: return "Nothing in this folder has changed yet."
        case .file: return "No earlier versions yet. One is added each time you save."
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

    private func fileList(showsPath: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(IDELocalHistoryPresentation.byDay(visibleEvents, time: \.time), id: \.heading) { section in
                    Text(section.heading)
                        .font(IDEAppearance.Typography.sectionHeader)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.top, IDEAppearance.Spacing.sm)
                    ForEach(section.items) { event in
                        row(event, showsPath: showsPath)
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
        Button("Copy") { workspace.localHistoryCopy(event) }
            .disabled(event.after == nil)
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
            Button("Copy") { workspace.localHistoryCopy(event) }
                .disabled(event.after == nil)
                .help("Copy this revision's text")
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
        switch scope {
        case .project:
            events = await store.recentEvents(limit: 300)
        case .folder(let folder):
            events = await store.events(under: folder)
        case .file:
            if let path = shownFilePath {
                events = await store.events(forPath: path)
            } else {
                events = []
            }
        }
        if let selection, !events.contains(where: { $0.id == selection }) { self.selection = nil }
        isLoaded = true
    }
}
