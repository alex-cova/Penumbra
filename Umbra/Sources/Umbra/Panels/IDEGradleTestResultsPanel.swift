import AppKit
import JavaIntelligence
import SwiftUI

struct IDEGradleTestResultsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable var store: IDEGradleTestPresentation
    @State private var log: GradleSessionLog?
    @State private var showsLog = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showsLog, let log {
                IDEGradleLogView(log: log, notes: [], fontName: workspace.preferences.fontName,
                                 fontSize: workspace.preferences.fontSize)
                    .id(ObjectIdentifier(log))
            } else if store.rows.isEmpty {
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    if store.isRestoring { ProgressView().controlSize(.small) }
                    Text(store.status ?? "No Gradle test results")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.testResults.split") {
                    outline
                } secondary: {
                    details
                } divider: {
                    Splitter.rule()
                }
            }
        }
        .task(id: workspace.gradle.rootURL) {
            guard let root = workspace.gradle.rootURL else { return }
            await store.refreshHistory(root: root)
            if store.summary == nil, let latest = store.history.first { await store.restore(latest) }
        }
        .onChange(of: store.summary?.id) { _, _ in
            showsLog = false
            log = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEIconButton(systemImage: "arrow.clockwise", help: "Rerun Gradle Tests") {
                workspace.javaRun.retryGradleTests(.complete)
            }
            .disabled(store.summary == nil || store.isRunning)
            IDEIconButton(systemImage: "arrow.clockwise.circle", help: "Rerun Failed Gradle Tests") {
                workspace.javaRun.retryGradleTests(.failed)
            }
            .disabled(store.counts[.failed, default: 0] == 0 || store.isRunning)
            IDEIconButton(systemImage: "stop.fill", help: "Stop Gradle Tests", action: workspace.gradle.cancelTasks)
                .disabled(!store.isRunning)
            Divider().frame(height: 14)
            IDEIconButton(systemImage: "chevron.up", help: "Previous Failure") { store.selectFailure(increment: -1) }
                .disabled(store.failureRows.isEmpty)
            IDEIconButton(systemImage: "chevron.down", help: "Next Failure") { store.selectFailure(increment: 1) }
                .disabled(store.failureRows.isEmpty)
            IDEIconMenu(systemImage: "line.3.horizontal.decrease", help: "Filter and Expand") {
                Toggle("Failed Only", isOn: $store.failedOnly)
                Toggle("Hide Passed", isOn: $store.hidePassed)
                Toggle("Show Gradle Workers and Suites", isOn: $store.includesWorkers)
                Divider()
                Button("Expand All") { store.collapsed = [] }
                Button("Collapse All") { store.collapsed = Set(store.rows.filter(\.hasChildren).map(\.id)) }
            }
            IDEIconMenu(systemImage: "clock.arrow.circlepath", help: "Gradle Test History") {
                historyMenu
            }
            IDEIconMenu(systemImage: "doc.text", help: "Gradle Logs and Reports") {
                Button(showsLog ? "Show Test Results" : "Show Session Log", action: toggleLog)
                    .disabled(store.summary == nil)
                ForEach(store.reports.html) { report in
                    Button("Open \(report.task) HTML Report") { openReport(report) }
                }
            }
            TextField("Search tests", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 80, maxWidth: 160)
            if store.isRunning {
                ProgressView().controlSize(.mini)
            }
            Text(counterText)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .help(store.status ?? counterText)
            if let summary = store.summary {
                if store.isRunning {
                    TimelineView(.periodic(from: summary.started, by: 1)) { context in
                        Text(IDEProjectConsoleControls.formattedElapsed(context.date.timeIntervalSince(summary.started)))
                    }
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityLabel("Elapsed time")
                } else if let finished = summary.finishedAt {
                    Text(IDEProjectConsoleControls.formattedElapsed(finished.timeIntervalSince(summary.started)))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .ideIconButtonSize(.compact)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)

    }

    @ViewBuilder private var historyMenu: some View {
        if store.history.isEmpty {
            Text("No Saved Gradle Runs")
        }
        ForEach(store.history) { session in
            let time = session.started.formatted(date: .abbreviated, time: .shortened)
            let attempt = session.original == nil ? "" : " · Retry"
            Button("\(session.tasks.filter { !$0.hasPrefix("-") }.joined(separator: " ")) · \(time) · \(session.state.rawValue)\(attempt)") {
                Task { await store.restore(session) }
            }
            .disabled(store.isRunning || session.state == .running)
        }
    }

    private var counterText: String {
        let counts = store.counts
        let reportCounts = store.reportCounts
        let running = counts[.running, default: 0]
        let passed = counts[.passed, default: 0] + reportCounts[.passed, default: 0]
        let failed = counts[.failed, default: 0] + reportCounts[.failed, default: 0]
        let skipped = counts[.skipped, default: 0] + reportCounts[.skipped, default: 0]
        let totals = "\(passed) passed · \(failed) failed · \(skipped) skipped"
        return store.isRunning ? "\(running) running · " + totals : totals
    }

    private var outline: some View {
        ScrollViewReader { proxy in
            List(selection: $store.selected) {
                ForEach(store.rows) { row in
                    HStack(spacing: 5) {
                        if row.hasChildren {
                            Button {
                                if store.collapsed.contains(row.id) { store.collapsed.remove(row.id) }
                                else { store.collapsed.insert(row.id) }
                            } label: {
                                Image(systemName: store.collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(store.collapsed.contains(row.id) ? "Expand" : "Collapse")
                        } else {
                            Spacer().frame(width: 9)
                        }
                        if let state = row.outcome {
                            Image(systemName: Self.icon(state))
                                .foregroundStyle(Self.color(state))
                                .accessibilityLabel(state.rawValue.capitalized)
                        }
                        Text(row.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if let duration = row.duration, duration > 0 {
                            Text(Duration.milliseconds(duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 13)
                    .contentShape(Rectangle())
                    .tag(row.id)
                    .id(row.id)
                    .contextMenu {
                        Button("Jump to Source") { jumpToSource(row.id) }
                            .disabled(store.detail(for: row.id)?.event.className == nil)
                        Button("Retry Selection") {
                            if !store.selected.contains(row.id) { store.selected = [row.id] }
                            workspace.javaRun.retryGradleTests(.selection)
                        }
                        .disabled(store.isRunning)
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: store.primarySelection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
            .onChange(of: store.rows.count) { _, _ in
                if let selection = store.primarySelection { proxy.scrollTo(selection) }
            }
            .onKeyPress(.return) {
                guard let selection = store.primarySelection else { return .ignored }
                jumpToSource(selection)
                return .handled
            }
        }
    }

    private var details: some View {
        IDEGradleTestDetails(
            node: store.primarySelection.flatMap { store.detail(for: $0) },
            report: store.primarySelection.flatMap { store.reportRow(for: $0) },
            directory: store.sessionDirectory,
            status: store.status,
            issues: store.issues,
            isRetry: store.summary?.original != nil
        )
    }

    private func jumpToSource(_ id: String) {
        guard let node = store.detail(for: id) else { return }
        workspace.openGradleTestSource(node.event)
    }

    private func openReport(_ report: GradleTestReports.HTMLReport) {
        guard report.isCurrent else {
            store.showActionMessage("The Gradle HTML report has moved or changed since this run.")
            return
        }
        NSWorkspace.shared.open(report.url)
    }

    private func toggleLog() {
        if showsLog {
            showsLog = false
            return
        }
        if store.isRunning, let current = workspace.gradle.console.sessionLog, current.directory == store.sessionDirectory {
            log = current
            showsLog = true
        } else if let directory = store.sessionDirectory {
            do {
                log = try GradleSessionLog(reading: directory)
                showsLog = true
            } catch {
                store.showActionMessage("The session log is unavailable. \(error.localizedDescription)")
            }
        }
    }

    private static func icon(_ state: GradleTestEvent.Outcome) -> String {
        switch state {
        case .running: "hourglass"
        case .passed: "checkmark.circle.fill"
        case .failed, .aborted: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .skipped: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private static func color(_ state: GradleTestEvent.Outcome) -> Color {
        switch state {
        case .passed: .green
        case .failed, .aborted: IDEAppearance.ColorToken.error
        case .running: IDEAppearance.ColorToken.accent
        case .cancelled, .skipped, .unknown: IDEAppearance.ColorToken.muted
        }
    }
}
