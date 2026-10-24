import SwiftUI

/// The diffs the Changes tab shows, computed off the main actor and kept per path. One per window.
@MainActor @Observable
final class IDEAIChangesModel {
    /// What a row can show: the diff against the file as it is now, or why there is none.
    struct Result: Equatable, Sendable {
        var diff: IDEAIUnifiedDiff?
        var note: String?
    }

    /// Files beyond this many (newest first) are listed without a diff.
    static let maximumFiles = 200
    /// A file larger than this is not diffed inline.
    static let maximumBytes = 1_000_000

    private(set) var results: [String: Result] = [:]

    func reset() { results = [:] }

    var totals: (added: Int, removed: Int) {
        results.values.reduce((0, 0)) { ($0.0 + ($1.diff?.added ?? 0), $0.1 + ($1.diff?.removed ?? 0)) }
    }

    /// Works out each file's diff, "before this chat" against the file now: an open unsaved buffer first,
    /// else the disk. Replaces `results` unless the caller's task was cancelled meanwhile.
    func update(files: [IDEAIChangedFile], root: URL?, unsaved: [String: String]) async {
        guard let root else {
            results = [:]
            return
        }
        let jobs = files.filter { !$0.isReverted }.prefix(Self.maximumFiles).map { (path: $0.path, original: $0.original) }
        let maximumBytes = Self.maximumBytes
        let computed = await Task.detached(priority: .userInitiated) {
            var out: [String: Result] = [:]
            for job in jobs {
                if Task.isCancelled { return out }
                out[job.path] = Self.result(for: job.path, original: job.original, root: root, unsaved: unsaved, maximumBytes: maximumBytes)
            }
            return out
        }.value
        guard !Task.isCancelled else { return }
        results = computed
    }

    nonisolated private static func result(
        for path: String, original: String?, root: URL, unsaved: [String: String], maximumBytes: Int
    ) -> Result {
        let url = root.appendingPathComponent(path).standardizedFileURL
        var current: String?
        if let buffer = unsaved[url.path] {
            current = buffer
        } else if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maximumBytes else { return Result(diff: nil, note: "Too large to show here.") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return Result(diff: nil, note: "Not a text file.")
            }
            current = text
        }
        // `current == nil`: the file is gone now.
        let diff = IDEAIUnifiedDiff.make(original: original, current: current)
        return Result(diff: diff, note: diff.isEmpty ? (current == nil ? "Deleted." : "Same as before this chat.") : nil)
    }
}

/// What the Changes tab's diffs are computed from; a change restarts the work.
private struct IDEAIChangesRefreshKey: Hashable {
    var files: [String]
    var isRunning: Bool
    var root: URL?
}

/// Every file the selected chat's runs changed, with its diff against the file before the chat: expand a
/// row to read it, open it in the diff viewer, or revert all the runs.
struct IDEAIChangesTab: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var expanded: Set<String> = []

    private var conversation: IDEAgentConversation { workspace.agent.selected }

    var body: some View {
        let entries = conversation.entries
        let files = IDEAIChangedFiles.summarize(entries)
        let pending = IDEAIChangedFiles.pendingPaths(in: entries, isRunning: conversation.isRunning)
        let key = IDEAIChangesRefreshKey(
            files: files.map { "\($0.path)|\($0.entryIDs.count)|\($0.isReverted)" },
            isRunning: conversation.isRunning, root: workspace.agentProjectRoot)
        Group {
            if files.isEmpty && pending.isEmpty {
                IDEAIInspectorEmptyState(
                    symbol: "plusminus.circle", title: "No changes yet",
                    message: "Files the agent edits in this chat appear here, with what changed.")
            } else {
                VStack(spacing: 0) {
                    header(files: files)
                    Divider().overlay(IDEAppearance.ColorToken.border)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !pending.isEmpty { pendingSection(pending) }
                            ForEach(files) { file in
                                row(for: file)
                                Divider().overlay(IDEAppearance.ColorToken.border.opacity(0.5))
                            }
                        }
                    }
                }
            }
        }
        .task(id: key) {
            await workspace.aiChanges.update(
                files: files, root: workspace.agentProjectRoot, unsaved: workspace.agentUnsavedBuffers())
        }
    }

    // MARK: - Header

    private func header(files: [IDEAIChangedFile]) -> some View {
        let live = files.filter { !$0.isReverted }
        let totals = workspace.aiChanges.totals
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            Text("\(live.count) \(live.count == 1 ? "file" : "files") changed")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if totals.added + totals.removed > 0 {
                Text("+\(totals.added)")
                    .foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                Text("−\(totals.removed)")
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            Spacer(minLength: 0)
            Button("Revert All") {
                conversation.revertRuns(entryIDs: Array(Set(live.flatMap(\.entryIDs))))
            }
            .controlSize(.small)
            .disabled(conversation.isRunning || live.isEmpty)
            .help(conversation.isRunning
                ? "Wait for the run to finish"
                : "Restore every file the agent changed in this chat; files you edited afterwards are left alone")
        }
        .font(IDEAppearance.Typography.monoSmall)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs + 2)
    }

    private func pendingSection(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Editing now")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ForEach(paths, id: \.self) { path in
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    ProgressView().controlSize(.mini)
                    Text(path)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    private func row(for file: IDEAIChangedFile) -> some View {
        let isExpanded = expanded.contains(file.path)
        let result = workspace.aiChanges.results[file.path]
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expanded.remove(file.path) } else { expanded.insert(file.path) }
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 10)
                    Image(systemName: file.isCreation ? "plus.circle" : "doc.text")
                        .foregroundStyle(file.isCreation ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.gitModified)
                    Text(file.name)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                    if !file.folder.isEmpty {
                        Text(file.folder)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    if file.isReverted {
                        Text("Reverted").foregroundStyle(IDEAppearance.ColorToken.muted)
                    } else if file.hasConflict {
                        Text("changed since").foregroundStyle(IDEAppearance.ColorToken.error)
                    } else if let diff = result?.diff, !diff.isEmpty {
                        Text("+\(diff.added)").foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                        Text("−\(diff.removed)").foregroundStyle(IDEAppearance.ColorToken.error)
                    }
                }
                .font(IDEAppearance.Typography.monoSmall)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(file.isReverted ? 0.55 : 1)
            .contextMenu {
                Button("Open Diff in Editor") { openDiff(file) }
                Button("Open File") { Task { await workspace.openAgentCitedFile(.init(path: file.path)) } }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            .help(file.path)
            .accessibilityLabel("\(file.path), \(file.isCreation ? "created" : "modified")\(file.isReverted ? ", reverted" : "")")
            .accessibilityHint(isExpanded ? "Hide the changes" : "Show the changes")

            if isExpanded { expandedBody(file, result: result) }
        }
    }

    @ViewBuilder
    private func expandedBody(_ file: IDEAIChangedFile, result: IDEAIChangesModel.Result?) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            if file.isReverted {
                Text("Every run that changed this file was reverted.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if let diff = result?.diff, !diff.isEmpty {
                IDEAgentDiffView(diff: diff.text, maxHeight: 360, hasFileHeader: false)
            } else if let note = result?.note {
                Text(note)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Open in Diff Viewer") { openDiff(file) }
                .controlSize(.small)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openDiff(_ file: IDEAIChangedFile) {
        conversation.showDiff(for: IDEAgentFileChange(path: file.path, original: file.original))
    }
}

/// An icon, a line and a hint, for a tab with nothing to show yet.
struct IDEAIInspectorEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(message)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
