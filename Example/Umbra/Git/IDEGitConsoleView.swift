import GitIntelligence
import SwiftUI

/// The Git console: every command that changed something, or failed, with git's own report. It is
/// how a user (and a bug report) sees what a button actually ran, as IntelliJ's Version Control ▸
/// Console does.
struct IDEGitConsoleView: View {
    let repositoryRoot: String?
    private let store = IDEGitCommandStore.shared

    var body: some View {
        let records = store.records(under: repositoryRoot)
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(records.isEmpty ? "No commands yet" : "\(records.count) commands")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                Button("Clear") { store.clear(under: repositoryRoot) }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .disabled(records.isEmpty)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                        ForEach(records) { record in
                            IDEGitConsoleRow(record: record).id(record.id)
                        }
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: records.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct IDEGitConsoleRow: View {
    let record: GitCommandRecord

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
                Text(record.date.formatted(Self.timeFormat))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(record.commandLine)
                    .foregroundStyle(record.succeeded ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
            }
            if let report = report, !report.isEmpty {
                Text(report)
                    .foregroundStyle(record.succeeded ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
                    .padding(.leading, IDEAppearance.Spacing.md)
            }
            if !record.succeeded {
                Text("exit \(record.exitStatus) · \(String(format: "%.2f", record.duration)) s")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.leading, IDEAppearance.Spacing.md)
            }
        }
        .font(IDEAppearance.Typography.monoSmall)
    }

    /// What git printed, stderr first (that is where fetch, push and errors write), trimmed.
    private var report: String? {
        let text = [record.stderr, record.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
