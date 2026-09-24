import JavaIntelligence
import Observation
import SwiftUI

/// One row in the Test Results tree.
struct IDETestResultRow: Identifiable {
    let result: JavaTestCaseResult
    let depth: Int

    var id: String { result.id }
}

/// What the Test Results tab shows after a Gradle test run.
@MainActor
@Observable
final class IDETestResultsStore {
    private(set) var rows: [IDETestResultRow] = []
    private(set) var passedCount = 0
    private(set) var failedCount = 0
    private(set) var skippedCount = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var hasContent = false
    private(set) var summaryMessage: String?
    var selectedID: String?

    func beginRun(label: String) {
        isRunning = true
        hasContent = true
        summaryMessage = label
        rows = []
        passedCount = 0
        failedCount = 0
        skippedCount = 0
        duration = 0
    }

    func finishRun(_ result: JavaTestRunResult) {
        isRunning = false
        passedCount = result.passedCount
        failedCount = result.failedCount
        skippedCount = result.skippedCount
        duration = result.duration
        var grouped: [String: [JavaTestCaseResult]] = [:]
        var order: [String] = []
        for testCase in result.cases {
            if grouped[testCase.className] == nil { order.append(testCase.className) }
            grouped[testCase.className, default: []].append(testCase)
        }
        rows = order.flatMap { className -> [IDETestResultRow] in
            let cases = grouped[className] ?? []
            return cases.enumerated().map { index, testCase in
                IDETestResultRow(result: testCase, depth: index == 0 ? 0 : 1)
            }
        }
        summaryMessage = "\(passedCount) passed, \(failedCount) failed, \(skippedCount) skipped"
        hasContent = true
    }

    func clear() {
        rows = []
        passedCount = 0
        failedCount = 0
        skippedCount = 0
        duration = 0
        isRunning = false
        hasContent = false
        summaryMessage = nil
        selectedID = nil
    }
}

/// The bottom panel's Test Results tab.
struct IDETestResultsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let store = workspace.testResults
        Group {
            if store.rows.isEmpty {
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    if store.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.isRunning ? (store.summaryMessage ?? "Running tests…") : "No test results")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let summary = store.summaryMessage {
                        Text(summary)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, IDEAppearance.Spacing.sm)
                            .padding(.vertical, IDEAppearance.Spacing.xs)
                    }
                    List(selection: Binding(
                        get: { store.selectedID },
                        set: { store.selectedID = $0 }
                    )) {
                        ForEach(store.rows) { row in
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Image(systemName: icon(for: row.result.status))
                                    .foregroundStyle(color(for: row.result.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.depth == 0 ? row.result.className : row.result.name)
                                        .font(IDEAppearance.Typography.body)
                                    if row.depth == 1, let message = row.result.message, !message.isEmpty {
                                        Text(message)
                                            .font(IDEAppearance.Typography.monoSmall)
                                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * IDEAppearance.Spacing.md)
                            .tag(row.id as String?)
                            .onTapGesture(count: 2) {
                                workspace.openTestResult(row.result)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private func icon(for status: JavaTestCaseResult.Status) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed, .aborted: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: JavaTestCaseResult.Status) -> Color {
        switch status {
        case .passed: return .green
        case .failed, .aborted: return .red
        case .skipped: return IDEAppearance.ColorToken.muted
        }
    }
}

/// Tab-strip item for the Test Results tab.
struct IDETestResultsTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flask")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text(title)
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}
