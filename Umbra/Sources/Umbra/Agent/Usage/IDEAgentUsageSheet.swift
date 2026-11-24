import AgentKit
import Charts
import SwiftUI

/// `/usage`: token use and recorded cost across saved chats, for this project or every project (and AI
/// mode's Chat), over a period. Read from the saved files off the main actor; nothing is re-priced.
struct IDEAgentUsageSheet: View {
    enum Scope: String, CaseIterable, Identifiable {
        case project = "This Project"
        case all = "All Projects"
        var id: Self { self }
    }

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        case all = 0
        var id: Self { self }
        var title: String { self == .all ? "All Time" : "\(rawValue) Days" }
        var days: Int? { self == .all ? nil : rawValue }
    }

    /// Where the chats are: the agent's store with the window's project, and AI mode's Chat store.
    struct Sources: Sendable {
        var agentStore: SessionStore?
        var projectRoot: String?
        var chatStore: SessionStore?
    }

    let sources: Sources
    let dismiss: () -> Void

    @State private var scope: Scope = .project
    @State private var period: Period = .month
    @State private var report: IDEAgentUsageReport?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Usage")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("Tokens and the cost each chat recorded when it ran, from the price table of the time. An estimate, not a bill.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(sources.projectRoot == nil)
                .fixedSize()
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let report {
                content(report)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 620)
        .task(id: "\(scope.rawValue)|\(period.rawValue)") { await load() }
    }

    @ViewBuilder private func content(_ report: IDEAgentUsageReport) -> some View {
        if report.chats == 0 {
            Text("No chat used any tokens in this period.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    tiles(report)
                    chart(report)
                    table("By model", rows: report.byModel)
                    if scope == .all || sources.projectRoot == nil { table("By project", rows: report.byProject) }
                    notes(report)
                }
            }
            // A sheet sizes to its content's ideal size, and a ScrollView's is next to nothing.
            .frame(minHeight: 320, idealHeight: 520, maxHeight: 620)
        }
    }

    private func tiles(_ report: IDEAgentUsageReport) -> some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            tile("Cost", report.cost > 0 ? IDEAgentPrices.format(report.cost) : "—")
            tile("Input", Self.tokens(report.total.inputTokens),
                 detail: report.cachedShare.map { "\(Self.percent($0)) cached" })
            tile("Output", Self.tokens(report.total.outputTokens))
            tile("Chats", "\(report.chats)")
        }
    }

    private func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(value)
                .font(IDEAppearance.Typography.body.weight(.semibold))
                .monospacedDigit()
            Text(detail ?? " ")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }

    /// Cost per day when any cost is known, else tokens (a period of local models only).
    private func chart(_ report: IDEAgentUsageReport) -> some View {
        let byCost = report.byDay.contains { $0.cost > 0 }
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(byCost ? "Cost per day" : "Tokens per day")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Chart(report.byDay) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value(byCost ? "Cost" : "Tokens", byCost ? day.cost : Double(day.tokens)))
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number == 0 ? (byCost ? "$0" : "0") : byCost ? IDEAgentPrices.format(number) : Self.tokens(Int(number)))
                        }
                    }
                }
            }
            .frame(height: 120)
        }
    }

    private func table(_ title: String, rows: [IDEAgentUsageReport.Row]) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Grid(alignment: .trailing, horizontalSpacing: IDEAppearance.Spacing.md, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Chats")
                    Text("Input")
                    Text("Cached")
                    Text("Output")
                    Text("Cost")
                }
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(row.id)
                        Text("\(row.chats)")
                        Text(Self.tokens(row.usage.inputTokens))
                        Text(row.cachedShare.map(Self.percent) ?? "—")
                        Text(Self.tokens(row.usage.outputTokens))
                        Text(row.cost.map(IDEAgentPrices.format) ?? "—")
                    }
                    .font(IDEAppearance.Typography.caption)
                    .monospacedDigit()
                }
            }
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.editor)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
    }

    private func notes(_ report: IDEAgentUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if report.unpricedChats > 0 {
                Text("\(report.unpricedChats) \(report.unpricedChats == 1 ? "chat has" : "chats have") no cost: a local model, or a model missing from the price table (Settings ▸ Agent).")
            }
            Text("A chat counts on the day it was last used. A chat's cost is shown on the model that did most of its work. External agents' tokens appear only when the agent reports them.")
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        report = nil
        let sources = sources
        let projectOnly = scope == .project ? sources.projectRoot : nil
        let period = period
        let since = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Calendar.current.startOfDay(for: Date())) }
        let records = await Task.detached(priority: .userInitiated) { () -> [IDEAgentUsageRecord] in
            var records: [IDEAgentUsageRecord] = []
            // No project means every project's chats.
            if let store = sources.agentStore {
                records += IDEAgentUsageLoader.records(in: store, projectRoot: projectOnly, since: since)
            }
            // AI mode's Chat belongs to no project, so it counts only in All Projects.
            if projectOnly == nil, let chats = sources.chatStore {
                records += IDEAgentUsageLoader.records(in: chats, projectRoot: IDEAIChatConversation.storeRoot, since: since)
            }
            return records
        }.value
        guard !Task.isCancelled else { return }
        report = IDEAgentUsageReport.make(records, days: period.days)
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: String(format: "%.1fK", Double(count) / 1_000)
        default: String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}
