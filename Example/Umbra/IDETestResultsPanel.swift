import JavaIntelligence
import Observation
import SwiftUI

/// One class of the Test Results tree, with its test cases.
struct IDETestResultGroup: Identifiable {
    let className: String
    let cases: [JavaTestCaseResult]

    var id: String { className }

    /// Failed if any case failed, else skipped if all were, else passed.
    var status: JavaTestCaseResult.Status {
        if cases.contains(where: { $0.status == .failed || $0.status == .aborted }) { return .failed }
        if !cases.isEmpty, cases.allSatisfy({ $0.status == .skipped }) { return .skipped }
        return .passed
    }

    var duration: TimeInterval { cases.reduce(0) { $0 + $1.duration } }
}

/// What the Test Results tab shows after a Gradle test run, and what is needed to run it again.
@MainActor
@Observable
final class IDETestResultsStore {
    enum Sort: String, CaseIterable {
        case name = "Name"
        case duration = "Duration"
    }

    private(set) var cases: [JavaTestCaseResult] = []
    private(set) var passedCount = 0
    private(set) var failedCount = 0
    private(set) var skippedCount = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var hasContent = false
    private(set) var summaryMessage: String?
    /// What ran last, for Rerun; and whether it ran under the debugger.
    private(set) var lastScope: JavaTestRunScope?
    private(set) var lastRunWasDebug = false
    var selectedID: String?
    var showsPassed = true
    var showsSkipped = true
    var sort: Sort = .name
    var collapsedClasses: Set<String> = []

    func beginRun(label: String, scope: JavaTestRunScope? = nil, debug: Bool = false) {
        isRunning = true
        hasContent = true
        summaryMessage = label
        if let scope {
            lastScope = scope
            lastRunWasDebug = debug
        }
        // The last results stay readable until the new ones arrive.
    }

    func finishRun(_ result: JavaTestRunResult) {
        isRunning = false
        cases = result.cases
        passedCount = result.passedCount
        failedCount = result.failedCount
        skippedCount = result.skippedCount
        duration = result.duration
        summaryMessage = "\(passedCount) passed, \(failedCount) failed, \(skippedCount) skipped"
            + (duration > 0 ? String(format: " · %.2f s", duration) : "")
        hasContent = true
        if let selectedID, !cases.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if selectedID == nil { selectedID = cases.first { $0.status == .failed || $0.status == .aborted }?.id }
    }

    func clear() {
        cases = []
        passedCount = 0
        failedCount = 0
        skippedCount = 0
        duration = 0
        isRunning = false
        hasContent = false
        summaryMessage = nil
        selectedID = nil
    }

    /// The classes and cases the filters let through, sorted.
    var groups: [IDETestResultGroup] {
        var grouped: [String: [JavaTestCaseResult]] = [:]
        var order: [String] = []
        for testCase in cases where isShown(testCase) {
            if grouped[testCase.className] == nil { order.append(testCase.className) }
            grouped[testCase.className, default: []].append(testCase)
        }
        let groups = order.map { IDETestResultGroup(className: $0, cases: sorted(grouped[$0] ?? [])) }
        switch sort {
        case .name: return groups.sorted { $0.className < $1.className }
        case .duration: return groups.sorted { $0.duration > $1.duration }
        }
    }

    private func isShown(_ testCase: JavaTestCaseResult) -> Bool {
        switch testCase.status {
        case .passed: return showsPassed
        case .skipped: return showsSkipped
        case .failed, .aborted: return true
        }
    }

    private func sorted(_ cases: [JavaTestCaseResult]) -> [JavaTestCaseResult] {
        switch sort {
        case .name: return cases.sorted { $0.name < $1.name }
        case .duration: return cases.sorted { $0.duration > $1.duration }
        }
    }

    var selectedCase: JavaTestCaseResult? {
        cases.first { $0.id == selectedID }
    }

    /// The failed tests of the last run as one scope (`--tests Class.method` each).
    var failedScope: JavaTestRunScope? {
        guard let taskPath = lastTaskPath else { return nil }
        let filters = cases.filter { $0.status == .failed || $0.status == .aborted }.map { testCase -> String in
            // `add(int)[1]` → `add`: Gradle filters by method name.
            let method = testCase.name.prefix { $0 != "(" && $0 != "[" && $0 != " " }
            return method.isEmpty ? testCase.className : "\(testCase.className).\(method)"
        }
        let unique = Array(NSOrderedSet(array: filters)) as? [String] ?? filters
        return unique.isEmpty ? nil : .tests(taskPath: taskPath, filters: unique)
    }

    private var lastTaskPath: String? {
        switch lastScope {
        case .allInModule(let taskPath)?: return taskPath
        case .testClass(let testClass)?: return testClass.gradleTaskPath
        case .testMethod(_, let taskPath)?: return taskPath
        case .tests(let taskPath, _)?: return taskPath
        case nil: return nil
        }
    }

    func title(for scope: JavaTestRunScope) -> String {
        switch scope {
        case .allInModule(let taskPath): return taskPath
        case .testClass(let testClass): return String(testClass.qualifiedName.split(separator: ".").last ?? "")
        case .testMethod(let method, _): return "\(method.methodName)()"
        case .tests(_, let filters): return filters.count == 1 ? filters[0] : "\(filters.count) failed tests"
        }
    }
}

/// The bottom panel's Test Results tab: a toolbar (Rerun, Rerun Failed, Debug Failed, filters,
/// sort), the tests by class, and the selected test's message, stack trace and output.
struct IDETestResultsPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let store = workspace.testResults
        VStack(spacing: 0) {
            toolbar(store)
            Divider()
            if store.cases.isEmpty {
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
                SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.testResults.split") {
                    tree(store)
                } secondary: {
                    detail(store)
                } divider: {
                    Splitter.rule()
                }
            }
        }
    }

    private func toolbar(_ store: IDETestResultsStore) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEExplorerToolbarButton(systemImage: "arrow.clockwise", help: "Rerun") {
                workspace.rerunTests(failedOnly: false)
            }
            .disabled(store.lastScope == nil || store.isRunning)
            IDEExplorerToolbarButton(systemImage: "arrow.clockwise.circle", help: "Rerun Failed Tests") {
                workspace.rerunTests(failedOnly: true, debug: false)
            }
            .disabled(store.failedScope == nil || store.isRunning)
            IDEExplorerToolbarButton(systemImage: "ladybug", help: "Debug Failed Tests") {
                workspace.rerunTests(failedOnly: true, debug: true)
            }
            .disabled(store.failedScope == nil || store.isRunning)
            Divider().frame(height: 14)
            IDEExplorerToolbarButton(systemImage: store.showsPassed ? "checkmark.circle.fill" : "checkmark.circle",
                                     help: store.showsPassed ? "Hide Passed" : "Show Passed") {
                store.showsPassed.toggle()
            }
            IDEExplorerToolbarButton(systemImage: store.showsSkipped ? "minus.circle.fill" : "minus.circle",
                                     help: store.showsSkipped ? "Hide Ignored" : "Show Ignored") {
                store.showsSkipped.toggle()
            }
            Menu {
                Picker("Sort", selection: Binding(get: { store.sort }, set: { store.sort = $0 })) {
                    ForEach(IDETestResultsStore.Sort.allCases, id: \.self) { Text("By \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Expand All") { store.collapsedClasses = [] }
                Button("Collapse All") { store.collapsedClasses = Set(store.groups.map(\.className)) }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort and Expand")
            if store.isRunning {
                ProgressView().controlSize(.mini)
            }
            if let summary = store.summaryMessage {
                Text(summary)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEAppearance.Spacing.iconButton + 4)
    }

    private func tree(_ store: IDETestResultsStore) -> some View {
        List(selection: Binding(get: { store.selectedID }, set: { store.selectedID = $0 })) {
            ForEach(store.groups) { group in
                let collapsed = store.collapsedClasses.contains(group.className)
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 10)
                    statusIcon(group.status)
                    Text(group.className.split(separator: ".").last.map(String.init) ?? group.className)
                        .font(IDEAppearance.Typography.body.weight(.medium))
                        .help(group.className)
                    Spacer(minLength: 0)
                    durationText(group.duration)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if collapsed { store.collapsedClasses.remove(group.className) } else { store.collapsedClasses.insert(group.className) }
                }
                .tag(nil as String?)
                if !collapsed {
                    ForEach(group.cases) { testCase in
                        HStack(spacing: IDEAppearance.Spacing.xs) {
                            statusIcon(testCase.status)
                            Text(testCase.name)
                                .font(IDEAppearance.Typography.body)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            durationText(testCase.duration)
                        }
                        .padding(.leading, IDEAppearance.Spacing.md + 4)
                        .tag(testCase.id as String?)
                        .onTapGesture(count: 2) { workspace.openTestSource(testCase) }
                        .contextMenu {
                            Button("Jump to Source") { workspace.openTestSource(testCase) }
                            Button("Run ‘\(testCase.name)’") { workspace.runTestCase(testCase, debug: false) }
                            Button("Debug ‘\(testCase.name)’") { workspace.runTestCase(testCase, debug: true) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func detail(_ store: IDETestResultsStore) -> some View {
        if let testCase = store.selectedCase {
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        statusIcon(testCase.status)
                        Text("\(testCase.className).\(testCase.name)")
                            .font(IDEAppearance.Typography.body.weight(.medium))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        durationText(testCase.duration)
                    }
                    if let message = testCase.message, !message.isEmpty {
                        Text(message)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.error)
                            .textSelection(.enabled)
                    }
                    if let stack = testCase.stackTrace, !stack.isEmpty {
                        IDEStackTraceText(text: stack) { frame in workspace.openStackFrame(frame) }
                    }
                    if let output = testCase.output, !output.isEmpty {
                        Text("Output")
                            .font(IDEAppearance.Typography.caption.weight(.semibold))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(output)
                            .font(IDEAppearance.Typography.monoSmall)
                            .textSelection(.enabled)
                    }
                    if testCase.status == .passed && (testCase.output ?? "").isEmpty {
                        Text("Passed with no output.")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                .padding(IDEAppearance.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a test to see its output.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusIcon(_ status: JavaTestCaseResult.Status) -> some View {
        Image(systemName: icon(for: status))
            .font(.system(size: 11))
            .foregroundStyle(color(for: status))
    }

    @ViewBuilder
    private func durationText(_ duration: TimeInterval) -> some View {
        if duration > 0 {
            Text(duration >= 1 ? String(format: "%.2f s", duration) : "\(Int((duration * 1000).rounded())) ms")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
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

/// A frame of a Java stack trace: `at pkg.Cls.method(File.java:12)`.
struct IDEStackFrameReference: Equatable {
    let className: String
    let fileName: String
    let line: Int

    /// The frame on one line of a trace, if it is one with a file and line.
    static func parse(_ line: String) -> IDEStackFrameReference? {
        guard let match = line.firstMatch(of: /at\s+(?:[\w.$\/@]+\/)?([\w.$]+)\.[\w$<>]+\(([\w$]+\.(?:java|kt|groovy)):(\d+)\)/),
              let number = Int(match.3) else { return nil }
        return IDEStackFrameReference(className: String(match.1), fileName: String(match.2), line: number)
    }
}

/// A stack trace whose `at …(File.java:N)` lines open their source when clicked.
struct IDEStackTraceText: View {
    let text: String
    let onOpen: (IDEStackFrameReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).enumerated()), id: \.offset) { _, line in
                let string = String(line)
                if let frame = IDEStackFrameReference.parse(string) {
                    Button { onOpen(frame) } label: {
                        Text(string)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.accent)
                            .underline()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(frame.fileName):\(frame.line)")
                } else {
                    Text(string)
                        .font(IDEAppearance.Typography.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
