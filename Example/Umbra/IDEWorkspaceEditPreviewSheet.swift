import EditorIntelligence
import SwiftUI

/// How the preview sheet draws an entry.
enum IDEWorkspaceEditPreviewStyle {
    /// The line as it is, with the matched text highlighted (Rename).
    case singleLine
    /// The old line and the new line, each with the changed part tinted (Replace in Files).
    case diff
}

/// State behind the workspace edit preview sheet.
@MainActor
@Observable
final class IDEWorkspaceEditPreviewModel: Identifiable {
    let id = UUID()
    let plan: WorkspaceEditPlan
    let style: IDEWorkspaceEditPreviewStyle
    var selection: Set<WorkspaceEditPlanEntry.ID>
    private(set) var isApplying = false
    private(set) var errorSummary: String?
    private let applyHandler: (WorkspaceEdit) async -> WorkspaceEditApplyResult

    init(
        plan: WorkspaceEditPlan,
        style: IDEWorkspaceEditPreviewStyle = .singleLine,
        apply: @escaping (WorkspaceEdit) async -> WorkspaceEditApplyResult
    ) {
        self.plan = plan
        self.style = style
        self.selection = Set(plan.entries.filter(\.isSelectedByDefault).map(\.id))
        self.applyHandler = apply
    }

    var groups: [(url: URL, entries: [WorkspaceEditPlanEntry])] {
        Dictionary(grouping: plan.entries, by: \.url)
            .map { (url: $0.key, entries: $0.value.sorted { ($0.range.start.line, $0.range.start.column) < ($1.range.start.line, $1.range.start.column) }) }
            .sorted { $0.url.path < $1.url.path }
    }

    var canApply: Bool {
        !isApplying && (!selection.isEmpty || !plan.fileRenames.isEmpty || !plan.fileDeletions.isEmpty)
    }

    func toggle(_ entry: WorkspaceEditPlanEntry) {
        guard !entry.isReadOnly else { return }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

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

typealias IDERenamePreviewModel = IDEWorkspaceEditPreviewModel

/// Lists what a workspace edit would change, grouped by file, before anything is edited.
struct IDEWorkspaceEditPreviewSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let model: IDEWorkspaceEditPreviewModel

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
                        Label("Move file \(rename.from.lastPathComponent) to \(rename.to.path)", systemImage: "doc.badge.gearshape")
                            .font(IDEAppearance.Typography.body)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.vertical, 4)
                    }
                    ForEach(model.plan.fileDeletions, id: \.path) { url in
                        Label("Delete file \(url.lastPathComponent)", systemImage: "trash")
                            .font(IDEAppearance.Typography.body)
                            .foregroundStyle(IDEAppearance.ColorToken.error)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.vertical, 4)
                    }
                    ForEach(model.groups, id: \.url) { group in
                        fileHeader(group.url, count: group.entries.count)
                        ForEach(group.entries) { entry in
                            IDEWorkspaceEditPreviewRow(entry: entry, style: model.style, isOn: model.selection.contains(entry.id)) {
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
                Button("Cancel", role: .cancel) { workspace.dismissWorkspaceEditPreview() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        if await model.apply() { workspace.dismissWorkspaceEditPreview() }
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
        Text(model.plan.title ?? "Rename Preview")
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

typealias IDERenamePreviewSheet = IDEWorkspaceEditPreviewSheet

private struct IDEWorkspaceEditPreviewRow: View {
    let entry: WorkspaceEditPlanEntry
    let style: IDEWorkspaceEditPreviewStyle
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        if style == .diff, let preview = entry.previewLine() {
            diffBody(preview)
        } else {
            singleLineBody
        }
    }

    /// Two rows, `−` the old line and `+` the new one, so the result of a replacement is visible
    /// before it is applied. Only shown when the old and new lines differ.
    private func diffBody(_ preview: WorkspaceEditPreviewLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.isReadOnly)
            Text("\(entry.range.start.line + 1)")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(minWidth: 32, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                diffLine(marker: "−", preview.before, preview.removed, preview.after, tint: IDEAppearance.ColorToken.error)
                diffLine(marker: "+", preview.before, preview.added, preview.after, tint: IDEAppearance.ColorToken.gitAdded)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, IDEAppearance.Spacing.xl)
        .padding(.trailing, IDEAppearance.Spacing.md)
        .padding(.vertical, 2)
        .opacity(isOn ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(entry.range.start.line + 1): replace \(preview.removed) with \(preview.added.isEmpty ? "nothing" : preview.added)")
    }

    private func diffLine(marker: String, _ before: String, _ changed: String, _ after: String, tint: Color) -> some View {
        var text = AttributedString(before)
        var middle = AttributedString(changed)
        if !changed.isEmpty {
            middle.font = IDEAppearance.Typography.monoSmall.bold()
            middle.foregroundColor = tint
            middle.backgroundColor = tint.opacity(0.18)
        }
        text.append(middle)
        text.append(AttributedString(after))
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(tint)
            Text(text)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var singleLineBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.isReadOnly)
            Text("\(entry.range.start.line + 1)")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(minWidth: 32, alignment: .trailing)
            if let description = entry.description {
                Text(description)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 88, alignment: .leading)
            }
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

    private var highlightedLine: AttributedString {
        let line = entry.lineText.replacingOccurrences(of: "\t", with: "    ")
        var text = AttributedString(line)
        if !entry.oldText.isEmpty, let range = text.range(of: entry.oldText) {
            text[range].font = IDEAppearance.Typography.monoSmall.bold()
            text[range].foregroundColor = IDEAppearance.ColorToken.accent
        } else if !entry.newText.isEmpty {
            text.font = IDEAppearance.Typography.monoSmall.bold()
            text.foregroundColor = IDEAppearance.ColorToken.accent
        }
        return text
    }
}
