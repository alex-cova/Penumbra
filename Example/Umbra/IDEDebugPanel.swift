import SwiftUI

/// The Debug tool window: a toolbar (IntelliJ's Rerun, Resume, Pause, Stop, stepping, Evaluate,
/// Drop Frame, Trace Stream, View / Mute Breakpoints), then Debugger (frames, variables with
/// watches, evaluate), Console, Memory and Overhead.
struct IDEDebugPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var evaluateFieldFocused: Bool
    @State private var handledFocusRequest = 0
    @State private var pane = Pane.debugger

    private enum Pane: String, CaseIterable, Identifiable {
        case debugger = "Debugger"
        case console = "Console"
        case memory = "Memory"
        case overhead = "Overhead"

        var id: String { rawValue }
    }

    var body: some View {
        let session = workspace.debugSession
        VStack(spacing: 0) {
            toolbar(session)
            if let banner = stopBanner(session) {
                banner
            }
            Divider()
            switch pane {
            case .debugger:
                SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.debug.stackSplit") {
                    frames(session)
                } secondary: {
                    SplitPanes(minPrimary: 200, minSecondary: 220, storageKey: "umbra.debug.evaluateSplit") {
                        variables(session)
                    } secondary: {
                        evaluateSection(session)
                    } divider: {
                        Splitter.rule()
                    }
                } divider: {
                    Splitter.rule()
                }
            case .console:
                consolePane(session)
            case .memory:
                IDEDebugMemoryView(session: session)
            case .overhead:
                IDEDebugOverheadView(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Toolbar

    private func paneSwitcher(_ session: JavaDebugSession) -> some View {
        HStack(spacing: 2) {
            ForEach(Pane.allCases) { candidate in
                Button {
                    pane = candidate
                } label: {
                    HStack(spacing: 4) {
                        Text(candidate.rawValue)
                        if candidate == .console, pane != .console, session.console.hasUnread {
                            Circle()
                                .fill(IDEAppearance.ColorToken.accent)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel("New output")
                        }
                    }
                    .font(IDEAppearance.Typography.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(pane == candidate ? IDEAppearance.ColorToken.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toolbar(_ session: JavaDebugSession) -> some View {
        let stopped = session.isStopped
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            paneSwitcher(session)
            Divider().frame(height: 14)
            tool("arrow.clockwise", "Rerun", enabled: true) { workspace.rerunDebugSession() }
            tool("play.fill", "Resume", enabled: stopped, color: .green) { session.resume() }
            tool("pause.fill", "Pause", enabled: session.state == .running) { session.pause() }
            tool("stop.fill", "Stop", enabled: session.isActive, color: .red) { workspace.stopDebugging() }
            Divider().frame(height: 14)
            tool("arrow.turn.down.right", "Step Over", enabled: stopped) { session.stepOver() }
            tool("arrow.down.to.line", "Step Into", enabled: stopped) { session.stepInto() }
            tool("arrow.down.to.line.compact", "Force Step Into", enabled: stopped, color: .red) { session.forceStepInto() }
            tool("arrow.down.right.and.arrow.up.left", "Smart Step Into", enabled: stopped) { workspace.debugSmartStepInto() }
            tool("arrow.up.to.line", "Step Out", enabled: stopped) { session.stepOut() }
            tool("arrow.right.to.line", "Run to Cursor", enabled: stopped) { workspace.debugRunToCursor(force: false) }
            Divider().frame(height: 14)
            tool("function", "Evaluate Expression", enabled: stopped) { workspace.showEvaluateExpression(prefill: nil) }
            tool("arrow.uturn.backward", "Drop Frame", enabled: stopped) { session.dropFrame() }
            tool("water.waves", "Trace Current Stream Chain", enabled: stopped) { workspace.traceCurrentStream() }
            Divider().frame(height: 14)
            tool("circle.grid.2x2", "View Breakpoints", enabled: true) { workspace.viewBreakpoints() }
            tool(workspace.breakpointsMuted ? "circle.slash.fill" : "circle.slash",
                 workspace.breakpointsMuted ? "Unmute Breakpoints" : "Mute Breakpoints", enabled: true,
                 color: workspace.breakpointsMuted ? .red : nil) { workspace.toggleBreakpointsMuted() }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            status(session)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func tool(_ symbol: String, _ help: String, enabled: Bool, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(enabled ? (color ?? IDEAppearance.ColorToken.foreground) : IDEAppearance.ColorToken.muted.opacity(0.5))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func status(_ session: JavaDebugSession) -> some View {
        switch session.state {
        case .idle:
            Text("Not debugging")
        case .launching:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Launching…")
            }
        case .running:
            Text("Running")
        case .stopped(let file, let line, _):
            Text("Paused at \(file.lastPathComponent):\(line)")
        case .terminated:
            Text("Debug session ended")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    /// Why the program stopped, when there is more to say than the line: an exception, a
    /// condition that failed, or a stop that holds only one thread.
    private func stopBanner(_ session: JavaDebugSession) -> AnyView? {
        guard session.isStopped, let info = session.stopInfo else { return nil }
        var text: String?
        var color = IDEAppearance.ColorToken.muted
        switch info.reason {
        case "exception":
            text = "Exception: \(info.message ?? "")"
            color = IDEAppearance.ColorToken.error
        case "conditionError":
            text = info.message
            color = IDEAppearance.ColorToken.error
        case "watchpoint":
            text = "Field watchpoint"
        case "method":
            text = "Method breakpoint"
        default:
            break
        }
        if !info.suspendsAll {
            let thread = "Only thread ‘\(info.threadName)’ is suspended."
            text = text.map { "\($0) · \(thread)" } ?? thread
        }
        guard let text else { return nil }
        return AnyView(
            Text(text)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(color)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.xs)
        )
    }

    // MARK: - Frames

    private func frames(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Frames")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                if !session.threads.isEmpty {
                    Picker("", selection: Binding(
                        get: { session.threads.first(where: \.isCurrent)?.id ?? session.stopInfo?.threadID ?? 0 },
                        set: { session.selectThread($0) }
                    )) {
                        ForEach(session.threads) { thread in
                            Text("\(thread.name) (\(thread.isSuspended ? "suspended" : thread.status))")
                                .tag(thread.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!session.isStopped)
                    .help("Threads: another suspended thread's frames and variables")
                }
                Spacer(minLength: 0)
                Toggle(isOn: Bindable(workspace).hideLibraryFrames) {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Hide Library Frames")
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            let frames = workspace.hideLibraryFrames ? session.stackFrames.filter { !$0.isLibrary } : session.stackFrames
            List(frames, selection: Binding(
                get: { session.selectedFrameIndex },
                set: { index in
                    session.selectFrame(index)
                    if let frame = session.stackFrames.first(where: { $0.index == index }), frame.filePath.hasPrefix("/") {
                        workspace.revealDebugStop(file: URL(fileURLWithPath: frame.filePath), line: frame.line)
                    }
                }
            )) { frame in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(frame.name):\(frame.line), \(frame.className.split(separator: ".").last ?? "")")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(frame.isLibrary ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                    Text(frame.className)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                .tag(frame.index)
                .contextMenu {
                    Button("Drop Frame") {
                        session.selectFrame(frame.index)
                        session.dropFrame()
                    }
                    .disabled(frame.index == session.stackFrames.last?.index)
                }
            }
        }
    }

    // MARK: - Variables and watches

    private func variables(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Variables")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                Spacer()
                Button {
                    workspace.addWatch(session.evaluationDraft.isEmpty ? "" : session.evaluationDraft)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("New Watch (type it below)")
                .disabled(session.evaluationDraft.isEmpty)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            List {
                ForEach(workspace.watches, id: \.self) { watch in
                    IDEWatchRow(expression: watch, outcome: session.watchResults[watch], session: session)
                }
                ForEach(session.variables) { value in
                    IDEDebugValueRow(session: session, value: value, onAddWatch: { workspace.addWatch($0) })
                }
            }
        }
    }

    // MARK: - Evaluate

    private func evaluateSection(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evaluate")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                Spacer()
                if !session.evaluationDraft.isEmpty {
                    Button("Add to Watches") { workspace.addWatch(session.evaluationDraft) }
                        .buttonStyle(.plain)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                if !session.evaluations.isEmpty {
                    Button("Clear") { session.clearEvaluations() }
                        .buttonStyle(.plain)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            TextField("Expression, then Return", text: Bindable(session).evaluationDraft)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($evaluateFieldFocused)
                .disabled(!session.isStopped)
                .onSubmit { submitEvaluation(session) }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.xs)
            List(session.evaluations) { evaluation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(evaluation.expression)
                        .font(IDEAppearance.Typography.monoSmall.weight(.semibold))
                        .lineLimit(1)
                    switch evaluation.outcome {
                    case .value(let value):
                        IDEDebugValueRow(session: session, value: value, onAddWatch: { workspace.addWatch($0) })
                    case .failure(let message):
                        Text(message)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contextMenu {
                    Button("Add to Watches") { workspace.addWatch(evaluation.expression) }
                    Button("Evaluate Again") { Task { await session.evaluate(evaluation.expression) } }
                }
            }
        }
        .onAppear { focusEvaluationFieldIfRequested(session) }
        .onChange(of: session.evaluationFocusRequest) { _, _ in focusEvaluationFieldIfRequested(session) }
    }

    private func submitEvaluation(_ session: JavaDebugSession) {
        let expression = session.evaluationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        Task { await session.evaluate(expression) }
    }

    /// The field may not exist yet when ⌥F8 opens this tab, so the request is compared on appearing too.
    private func focusEvaluationFieldIfRequested(_ session: JavaDebugSession) {
        guard handledFocusRequest != session.evaluationFocusRequest else { return }
        handledFocusRequest = session.evaluationFocusRequest
        pane = .debugger
        Task { @MainActor in evaluateFieldFocused = true }
    }

    // MARK: - Console

    /// The program's output. It never takes focus when output arrives: the Console tab shows a dot
    /// while something new is waiting and the Debugger tab is up.
    private func consolePane(_ session: JavaDebugSession) -> some View {
        let console = session.console
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Clear") { console.reset() }
                    .buttonStyle(.plain)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .disabled(console.isEmpty)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 2)
            if console.isEmpty {
                Text("The program's output appears here while it runs under the debugger.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                IDEDebugConsoleView(
                    log: console,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                )
            }
            Divider()
            Text("Read-only: the program's input is not connected.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
        }
        .onAppear { console.markRead() }
        .onChange(of: console.revision) { console.markRead() }
    }
}

/// One watch: its expression and its value at this stop; double click to edit, empty to remove.
private struct IDEWatchRow: View {
    @Environment(IDEWorkspace.self) private var workspace
    let expression: String
    let outcome: JavaDebugEvaluation.Outcome?
    let session: JavaDebugSession

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.accent)
            if isEditing {
                TextField("Watch", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                    .onSubmit {
                        workspace.replaceWatch(expression, with: draft)
                        isEditing = false
                    }
                    .onExitCommand { isEditing = false }
            } else {
                switch outcome {
                case .value(let value)?:
                    IDEDebugValueRow(session: session, value: JavaDebugValue(
                        name: expression, type: value.type, value: value.value, expression: value.expression,
                        hasChildren: value.hasChildren, children: value.children
                    ))
                case .failure(let message)?:
                    Text(expression).font(IDEAppearance.Typography.body.weight(.medium))
                    Spacer(minLength: IDEAppearance.Spacing.xs)
                    Text(message)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                case nil:
                    Text(expression).font(IDEAppearance.Typography.body.weight(.medium))
                    Spacer(minLength: IDEAppearance.Spacing.xs)
                    Text(session.isStopped ? "…" : "Not available")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
        }
        .onTapGesture(count: 2) {
            draft = expression
            isEditing = true
        }
        .contextMenu {
            Button("Edit Watch") {
                draft = expression
                isEditing = true
            }
            Button("Remove Watch") { workspace.removeWatch(expression) }
        }
    }
}

/// The Memory tab: instances of each loaded class, and the change since the previous stop. It
/// loads at each stop only while it is showing, as IntelliJ's memory view does.
private struct IDEDebugMemoryView: View {
    let session: JavaDebugSession

    @State private var counts: [JavaDebugClassCount] = []
    @State private var previous: [String: Int] = [:]
    @State private var diffs: [String: Int] = [:]
    @State private var filter = ""
    @State private var changedOnly = false
    @State private var error: String?
    @State private var isLoading = false
    @State private var instancesOf: String?
    @State private var instances: [JavaDebugValue] = []
    @State private var loadedStop: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                TextField("Filter classes", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Changed since last stop", isOn: $changedOnly)
                    .controlSize(.small)
                Button("Refresh") { Task { await load() } }
                    .disabled(!session.isStopped || isLoading)
                if isLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Text("Track new instances needs a JVM agent and is not available.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            if let error {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.isStopped && counts.isEmpty {
                Text("Pause the program to count the objects on its heap.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SplitPanes(minPrimary: 260, minSecondary: 200, storageKey: "umbra.debug.memorySplit") {
                    Table(visibleCounts, selection: Binding(get: { instancesOf }, set: { selectClass($0) })) {
                        TableColumn("Class") { Text($0.className).font(IDEAppearance.Typography.monoSmall) }
                        TableColumn("Count") { Text("\($0.count)").font(IDEAppearance.Typography.monoSmall) }
                            .width(min: 60, ideal: 80, max: 120)
                        TableColumn("Diff") { entry in
                            let diff = diffs[entry.className] ?? 0
                            Text(diff == 0 ? "" : (diff > 0 ? "+\(diff)" : "\(diff)"))
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(diff > 0 ? Color.orange : IDEAppearance.ColorToken.muted)
                        }
                        .width(min: 50, ideal: 70, max: 100)
                    }
                } secondary: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(instancesOf.map { "Instances of \($0)" } ?? "Select a class to list its instances")
                            .font(IDEAppearance.Typography.caption.weight(.semibold))
                            .padding(IDEAppearance.Spacing.xs)
                        List(instances) { IDEDebugValueRow(session: session, value: $0) }
                    }
                } divider: {
                    Splitter.rule()
                }
            }
        }
        .task(id: stopKey) {
            guard session.isStopped, loadedStop != stopKey else { return }
            await load()
        }
    }

    /// Changes at every stop, so the counts load once per stop.
    private var stopKey: String {
        if case .stopped(let file, let line, let reason) = session.state { return "\(file.path):\(line):\(reason):\(session.stopInfo?.threadID ?? 0)" }
        return ""
    }

    private var visibleCounts: [JavaDebugClassCount] {
        counts.filter { entry in
            (filter.isEmpty || entry.className.localizedCaseInsensitiveContains(filter))
                && (!changedOnly || (diffs[entry.className] ?? 0) != 0)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch await session.instanceCounts() {
        case .success(let fresh):
            var newDiffs: [String: Int] = [:]
            if !previous.isEmpty {
                for entry in fresh { newDiffs[entry.className] = entry.count - (previous[entry.className] ?? 0) }
            }
            diffs = newDiffs
            previous = Dictionary(fresh.map { ($0.className, $0.count) }, uniquingKeysWith: { first, _ in first })
            counts = fresh
            error = nil
            loadedStop = stopKey
            if let instancesOf { selectClass(instancesOf) }
        case .failure(let failure):
            error = JavaDebugSession.message(for: failure)
        }
    }

    private func selectClass(_ className: String?) {
        instancesOf = className
        instances = []
        guard let className else { return }
        Task {
            if case .success(let list) = await session.instances(of: className) { instances = list }
        }
    }
}

/// The Overhead tab: hits and time spent per breakpoint (conditions and logging) and in stepping,
/// refreshed every second while it shows.
private struct IDEDebugOverheadView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let session: JavaDebugSession

    @State private var overhead: JavaDebugOverhead?

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let hits: Int
        let milliseconds: Double
        let isEnabled: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let overhead {
                Table(rows(overhead)) {
                    TableColumn("") { row in
                        Toggle("", isOn: Binding(
                            get: { row.isEnabled },
                            set: { enabled in
                                if let breakpoint = workspace.breakpoints.first(where: { $0.id == row.id }) {
                                    workspace.setBreakpointEnabled(breakpoint, enabled: enabled)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(24)
                    TableColumn("Breakpoint") { Text($0.title) }
                    TableColumn("Hits") { Text("\($0.hits)").font(IDEAppearance.Typography.monoSmall) }
                        .width(min: 50, ideal: 70, max: 100)
                    TableColumn("Time (ms)") { Text(String(format: "%.1f", $0.milliseconds)).font(IDEAppearance.Typography.monoSmall) }
                        .width(min: 60, ideal: 90, max: 120)
                }
                Text(String(format: "Stepping: %.1f ms", overhead.steppingMilliseconds))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(IDEAppearance.Spacing.xs)
            } else {
                Text(session.isActive ? "Loading…" : "Start debugging to see what breakpoints cost.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.isActive) {
            while session.isActive, !Task.isCancelled {
                overhead = await session.overhead()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func rows(_ overhead: JavaDebugOverhead) -> [Row] {
        overhead.breakpoints.map { entry in
            let breakpoint = workspace.breakpoints.first { $0.id == entry.breakpointID }
            return Row(
                id: entry.breakpointID,
                title: breakpoint?.title ?? "Removed breakpoint",
                hits: entry.hits,
                milliseconds: entry.milliseconds,
                isEnabled: breakpoint?.isEnabled ?? false
            )
        }
        .sorted { $0.milliseconds > $1.milliseconds }
    }
}

struct IDEDebugTabItem: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "ladybug")
                Text("Debug")
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
