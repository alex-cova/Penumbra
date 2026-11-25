import AgentKit
import SwiftUI

/// `/schedule`: the project's schedules, with Run Now, Pause and Delete (`IDEAgentScheduler`).
struct IDEAgentSchedulesSheet: View {
    let agent: IDEAgentController
    let dismiss: () -> Void

    private var scheduler: IDEAgentScheduler { agent.scheduler }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Schedules")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("Prompts this project runs on a cadence while a window has it open, each run in a chat of its own. A run that falls due while the project is closed is offered in a chat, never run on its own.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            if scheduler.schedules.isEmpty {
                Text("No schedules yet. Add one from the message field: /schedule 1h check the build.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    VStack(spacing: IDEAppearance.Spacing.sm) {
                        ForEach(scheduler.schedules) { row($0) }
                    }
                }
                .frame(minHeight: 140, idealHeight: 320, maxHeight: 460)
            }

            if !scheduler.runs.isEmpty { runsSection }

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 560)
    }

    private func row(_ schedule: IDEAgentSchedule) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedule.name)
                    .font(IDEAppearance.Typography.body.weight(.semibold))
                    .lineLimit(1)
                if schedule.isPaused {
                    Text("Paused")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                Text(schedule.mode.title)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(schedule.mode == .auto ? Color.orange : IDEAppearance.ColorToken.muted)
            }
            Text(timing(schedule))
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let note = schedule.lastNote {
                Text(note)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if schedule.prompt != schedule.name {
                Text(schedule.prompt)
                    .font(IDEAppearance.Typography.caption)
                    .lineLimit(3)
                    .help(schedule.prompt)
            }
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Button("Run Now") { scheduler.runNow(schedule.id) }
                Button(schedule.isPaused ? "Resume" : "Pause") { scheduler.setPaused(!schedule.isPaused, id: schedule.id) }
                if let chat = schedule.lastChatID {
                    Button("Open Last Run") {
                        agent.resume(chat)
                        dismiss()
                    }
                }
                Spacer()
                Button("Delete", role: .destructive) { scheduler.remove(schedule.id) }
            }
            .controlSize(.small)
        }
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }

    // MARK: - Runs

    /// What the schedules' runs did, newest first: the last 50 of the log.
    private var runsSection: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Runs")
                .font(IDEAppearance.Typography.sectionHeader)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scheduler.runs.prefix(50)) { run in
                        runRow(run)
                        Divider().overlay(IDEAppearance.ColorToken.border.opacity(0.5))
                    }
                }
            }
            .frame(minHeight: 80, idealHeight: 200, maxHeight: 240)
            .background(IDEAppearance.ColorToken.editor)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
    }

    private func runRow(_ run: IDEAgentScheduleRun) -> some View {
        let state = IDEAgentScheduleRunRow.describe(
            run, isRunning: agent.conversations.contains { $0.conversationID == run.conversationID && $0.isRunning })
        return HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.isError ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.scheduleName)
                    .font(IDEAppearance.Typography.body)
                    .lineLimit(1)
                Text(state.detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(state.isError ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    .lineLimit(2)
                    .help(state.detail)
            }
            Spacer(minLength: 0)
            Button("Open") {
                agent.resume(run.conversationID)
                dismiss()
            }
            .controlSize(.small)
            .help("Open this run's chat")
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func timing(_ schedule: IDEAgentSchedule) -> String {
        var parts = [IDEAgentScheduler.describe(interval: schedule.interval).capitalizedFirst]
        if !schedule.isPaused { parts.append("next \(IDEAgentScheduler.describe(schedule.nextDue))") }
        if let last = schedule.lastRunAt { parts.append("last \(IDEAgentScheduler.describe(last))") }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String { return prefix(1).uppercased() + dropFirst() }
}

/// What a run's row says. Pure, for tests.
enum IDEAgentScheduleRunRow {
    struct State: Equatable {
        var symbol: String
        var detail: String
        var isError: Bool
    }

    static func describe(_ run: IDEAgentScheduleRun, isRunning: Bool) -> State {
        var parts = [IDEAgentScheduler.describe(run.startedAt)]
        guard let end = run.endedAt, let outcome = run.outcome else {
            parts.append(isRunning ? "Running" : "No ending recorded (Umbra closed, or the chat was closed)")
            return State(symbol: isRunning ? "clock" : "questionmark.circle", detail: parts.joined(separator: " · "), isError: false)
        }
        parts.append(IDEAgentScheduleRunLog.duration(from: run.startedAt, to: end))
        parts.append(outcome)
        if run.filesChanged > 0 { parts.append("\(run.filesChanged) \(run.filesChanged == 1 ? "file" : "files") changed") }
        if let cost = run.cost, cost > 0 { parts.append("~" + IDEAgentPrices.format(cost)) }
        let symbol = run.isError ? "xmark.circle" : (outcome == "Completed" ? "checkmark.circle" : "pause.circle")
        return State(symbol: symbol, detail: parts.joined(separator: " · "), isError: run.isError)
    }
}
