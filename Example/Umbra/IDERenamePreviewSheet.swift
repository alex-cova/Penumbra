import EditorIntelligence
import SwiftUI

/// State behind the rename preview sheet.
@MainActor
@Observable
final class IDERenamePreviewModel: Identifiable {
    let id = UUID()
    let plan: RenamePlan
    var selection: Set<RenamePlanEntry.ID>
    private(set) var isApplying = false
    private(set) var errorSummary: String?
    private let applyHandler: (WorkspaceEdit) async -> WorkspaceEditApplyResult

    init(plan: RenamePlan, apply: @escaping (WorkspaceEdit) async -> WorkspaceEditApplyResult) {
        self.plan = plan
        self.selection = Set(plan.entries.filter(\.isSelectedByDefault).map(\.id))
        self.applyHandler = apply
    }

    var groups: [(url: URL, entries: [RenamePlanEntry])] {
        Dictionary(grouping: plan.entries, by: \.url)
            .map { (url: $0.key, entries: $0.value.sorted { ($0.range.start.line, $0.range.start.column) < ($1.range.start.line, $1.range.start.column) }) }
            .sorted { $0.url.path < $1.url.path }
    }

    var canApply: Bool {
        !isApplying && (!selection.isEmpty || !plan.fileRenames.isEmpty)
    }

    func toggle(_ entry: RenamePlanEntry) {
        guard !entry.isReadOnly else { return }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

    /// Applies the checked entries. Returns `true` when everything succeeded and the sheet can
    /// close; otherwise the failures are listed in ``errorSummary``.
    func apply() async -> Bool {
        isApplying = true
        errorSummary = nil
        let result = await applyHandler(plan.workspaceEdit(including: selection))
        isApplying = false
        guard !result.isSuccess else { return true }
        errorSummary = result.failures
            .sorted { $0.key.path < $1.key.path }
            .map { "\($0.key.lastPathComponent): \($0.value)" }
            .joined(separator: "\n")
        return false
    }
}

/// Lists what a rename would change, grouped by file, before anything is edited. Ambiguous
/// occurrences start unchecked, read-only ones can't be checked.
struct IDERenamePreviewSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let model: IDERenamePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            header
            if !model.plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.gitModified)
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.plan.fileRenames.indices, id: \.self) { index in
                        let rename = model.plan.fileRenames[index]
                        Label("Rename file \(rename.from.lastPathComponent) to \(rename.to.lastPathComponent)", systemImage: "doc.badge.gearshape")
                            .font(IDEAppearance.Typography.body)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.vertical, 4)
                    }
                    ForEach(model.groups, id: \.url) { group in
                        fileHeader(group.url, count: group.entries.count)
                        ForEach(group.entries) { entry in
                            IDERenamePreviewRow(entry: entry, isOn: model.selection.contains(entry.id)) {
                                model.toggle(entry)
                            }
                        }
                    }
                }
            }
            .background(IDEAppearance.ColorToken.workbench, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
            .frame(minHeight: 200)
            if let errorSummary = model.errorSummary {
                Text(errorSummary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
            }
            HStack {
                Text(summary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
                Button("Cancel", role: .cancel) { workspace.dismissRenamePreview() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        if await model.apply() { workspace.dismissRenamePreview() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 640, height: 480)
    }

    private var header: some View {
        Text("Rename Preview")
            .font(IDEAppearance.Typography.sectionHeader)
            .foregroundStyle(IDEAppearance.ColorToken.foreground)
    }

    private var summary: String {
        let files = Set(model.plan.entries.filter { model.selection.contains($0.id) }.map(\.url)).count
        return "\(model.selection.count) change\(model.selection.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }

    private func fileHeader(_ url: URL, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(url.lastPathComponent)
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(workspace.displayDirectory(of: url))
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
        .accessibilityElement(children: .combine)
    }
}

private struct IDERenamePreviewRow: View {
    let entry: RenamePlanEntry
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.isReadOnly)
            Text("\(entry.range.start.line + 1)")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(minWidth: 32, alignment: .trailing)
            Text(highlightedLine)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.isAmbiguous {
                Text("ambiguous")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.gitModified)
            }
            if entry.isReadOnly {
                Text("read-only")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.leading, IDEAppearance.Spacing.xl)
        .padding(.trailing, IDEAppearance.Spacing.md)
        .padding(.vertical, 2)
        .opacity(entry.isReadOnly ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line \(entry.range.start.line + 1): \(entry.lineText.trimmingCharacters(in: .whitespaces))")
    }

    /// The line with the old text bolded at the match.
    private var highlightedLine: AttributedString {
        let line = entry.lineText.replacingOccurrences(of: "\t", with: "    ")
        var text = AttributedString(line)
        if let range = text.range(of: entry.oldText) {
            text[range].font = IDEAppearance.Typography.monoSmall.bold()
            text[range].foregroundColor = IDEAppearance.ColorToken.accent
        }
        return text
    }
}
