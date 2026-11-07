import SwiftUI

/// The Debug tool window: a toolbar (IntelliJ's Rerun, Resume, Pause, Stop, stepping, Evaluate,
/// Drop Frame, Trace Stream, View / Mute Breakpoints), then Debugger (frames, variables with
/// watches, evaluate), Console, Memory and Overhead.
struct IDEDebugPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var evaluateFieldFocused: Bool
    @FocusState private var isEvaluateListFocused: Bool
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
        if workspace.dapDebugSession.presentsDebugger, !workspace.debugSession.isActive {
            IDESwiftDebugPane()
        } else {
            javaBody
        }
    }

    @ViewBuilder
    private var javaBody: some View {
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
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(pane == candidate ? IDEAppearance.ColorToken.selection : Color.clear, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.selection))
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
            IDEIconButton(systemImage: "arrow.clockwise", help: "Rerun") { workspace.rerunDebugSession() }
            IDEIconButton(systemImage: "play.fill", help: "Resume", tint: .green, isDisabled: !stopped) { session.resume() }
            IDEIconButton(systemImage: "pause.fill", help: "Pause", isDisabled: session.state != .running) { session.pause() }
            IDEIconButton(systemImage: "stop.fill", help: "Stop", tint: .red, isDisabled: !session.isActive) { workspace.stopDebugging() }
            Divider().frame(height: 14)
            IDEIconButton(systemImage: "arrow.turn.down.right", help: "Step Over", isDisabled: !stopped) { session.stepOver() }
            IDEIconButton(systemImage: "arrow.down.to.line", help: "Step Into", isDisabled: !stopped) { session.stepInto() }
            IDEIconButton(systemImage: "arrow.down.to.line.compact", help: "Force Step Into", tint: .red, isDisabled: !stopped) { session.forceStepInto() }
            IDEIconButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Smart Step Into", isDisabled: !stopped) { workspace.debugSmartStepInto() }
            IDEIconButton(systemImage: "arrow.up.to.line", help: "Step Out", isDisabled: !stopped) { session.stepOut() }
            IDEIconButton(systemImage: "arrow.right.to.line", help: "Run to Cursor", isDisabled: !stopped) { workspace.debugRunToCursor(force: false) }
            Divider().frame(height: 14)
            IDEIconButton(systemImage: "function", help: "Evaluate Expression", isDisabled: !stopped) { workspace.showEvaluateExpression(prefill: nil) }
            IDEIconButton(systemImage: "arrow.uturn.backward", help: "Drop Frame", isDisabled: !stopped) { session.dropFrame() }
            IDEIconButton(systemImage: "water.waves", help: "Trace Current Stream Chain", isDisabled: !stopped) { workspace.traceCurrentStream() }
            Divider().frame(height: 14)
            IDEIconButton(systemImage: "circle.grid.2x2", help: "View Breakpoints") { workspace.viewBreakpoints() }
            IDEIconButton(
                systemImage: workspace.breakpointsMuted ? "circle.slash.fill" : "circle.slash",
                help: workspace.breakpointsMuted ? "Unmute Breakpoints" : "Mute Breakpoints",
                tint: workspace.breakpointsMuted ? .red : nil,
                isActive: workspace.breakpointsMuted
            ) { workspace.toggleBreakpointsMuted() }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            status(session)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        .ideIconButtonSize(.compact)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
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
                IDEIconButton(
                    systemImage: "line.3.horizontal.decrease",
                    help: "Hide Library Frames",
                    isActive: workspace.hideLibraryFrames
                ) {
                    workspace.hideLibraryFrames.toggle()
                }
            }
            .ideIconButtonSize(.compact)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            IDEDebugFramesList(session: session)
        }
    }

    // MARK: - Variables and watches

    private func variables(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Variables")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                Spacer()
                IDEIconButton(systemImage: "plus", help: "New Watch (type it below)", isDisabled: session.evaluationDraft.isEmpty) {
                    workspace.addWatch(session.evaluationDraft)
                }
            }
            .ideIconButtonSize(.compact)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            IDEDebugValueList(
                session: session,
                groups: [
                    .init(idPrefix: "watch:", isWatch: true, roots: watchRoots(session)),
                    .init(roots: session.variables)
                ],
                resetID: "\(session.selectedFrameIndex)-\(session.variables.map(\.id).joined(separator: ","))-\(workspace.watches.joined(separator: ","))",
                emptyMessage: session.isStopped ? "No variables in this frame." : "Variables appear when the program is paused.",
                onAddWatch: { workspace.addWatch($0) }
            )
        }
    }

    private func watchRoots(_ session: JavaDebugSession) -> [JavaDebugValue] {
        workspace.watches.map { expression in
            switch session.watchResults[expression] {
            case .value(let value)?:
                JavaDebugValue(
                    name: expression, type: value.type, value: value.value,
                    expression: value.expression.isEmpty ? expression : value.expression,
                    hasChildren: value.hasChildren, children: value.children
                )
            case .failure(let message)?:
                JavaDebugValue(name: expression, type: "", value: message, expression: expression)
            case nil:
                JavaDebugValue(
                    name: expression, type: "",
                    value: session.isStopped ? "…" : "Not available",
                    expression: expression
                )
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
                .onKeyPress(.downArrow) {
                    isEvaluateListFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    if session.evaluationDraft.isEmpty { return .ignored }
                    session.evaluationDraft = ""
                    return .handled
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.xs)
            IDEDebugValueList(
                session: session,
                groups: [.init(roots: evaluationRoots(session))],
                resetID: session.evaluations.map { "\($0.id)" }.joined(separator: ","),
                emptyMessage: session.isStopped ? "Evaluate an expression to see its value." : "Pause the program to evaluate.",
                onAddWatch: { workspace.addWatch($0) },
                listFocus: $isEvaluateListFocused
            )
        }
        .onAppear { focusEvaluationFieldIfRequested(session) }
        .onChange(of: session.evaluationFocusRequest) { _, _ in focusEvaluationFieldIfRequested(session) }
    }

    private func evaluationRoots(_ session: JavaDebugSession) -> [JavaDebugValue] {
        session.evaluations.map { evaluation in
            switch evaluation.outcome {
            case .value(let value):
                JavaDebugValue(
                    name: evaluation.expression, type: value.type, value: value.value,
                    expression: value.expression.isEmpty ? evaluation.expression : value.expression,
                    hasChildren: value.hasChildren, children: value.children
                )
            case .failure(let message):
                JavaDebugValue(name: evaluation.expression, type: "", value: message, expression: evaluation.expression)
            }
        }
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
            .padding(.vertical, IDEAppearance.Spacing.xxs)
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

/// Stack frames as a flat list so arrow keys and type-select walk them like Variables.
private struct IDEDebugFramesList: View {
    @Environment(IDEWorkspace.self) private var workspace
    let session: JavaDebugSession
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool

    private var frames: [JavaDebugStackFrame] {
        workspace.hideLibraryFrames ? session.stackFrames.filter { !$0.isLibrary } : session.stackFrames
    }

    var body: some View {
        let rows = frames
        return Group {
            if rows.isEmpty {
                Text(session.isStopped ? "No frames." : "Frames appear when the program is paused.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.escape) {
                        workspace.focusActiveEditor()
                        return .handled
                    }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { frame in
                                IDEDebugFrameRow(
                                    frame: frame,
                                    isSelected: session.selectedFrameIndex == frame.index,
                                    onSelect: { select(frame) },
                                    onActivate: { select(frame) },
                                    onDrop: {
                                        session.selectFrame(frame.index)
                                        session.dropFrame()
                                    },
                                    canDrop: frame.index != session.stackFrames.last?.index
                                )
                                .id(frame.index)
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                    }
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, rows: rows)
                    }
                    .onChange(of: session.selectedFrameIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
    }

    private func handleKey(_ press: KeyPress, rows: [JavaDebugStackFrame]) -> KeyPress.Result {
        let current = rows.first { $0.index == session.selectedFrameIndex }
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let index = IDEListNeighbor.move(session.selectedFrameIndex, in: rows.map(\.index), by: delta),
               let frame = rows.first(where: { $0.index == index }) {
                select(frame)
            }
            return .handled
        case .return:
            typeahead.reset()
            if let current { select(current) }
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let frame = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows, selected: current, title: Self.title
            ) {
                select(frame)
            }
            return .handled
        }
    }

    private func select(_ frame: JavaDebugStackFrame) {
        session.selectFrame(frame.index)
        isListFocused = true
        guard frame.filePath.hasPrefix("/") else { return }
        workspace.revealDebugStop(file: URL(fileURLWithPath: frame.filePath), line: frame.line, selectsLine: false)
    }

    private static func title(_ frame: JavaDebugStackFrame) -> String {
        let simple = frame.className.split(separator: ".").last.map(String.init) ?? frame.className
        return "\(frame.name) \(simple)"
    }
}

private struct IDEDebugFrameRow: View {
    let frame: JavaDebugStackFrame
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onDrop: () -> Void
    let canDrop: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(frame.name):\(frame.line), \(frame.className.split(separator: ".").last ?? "")")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(frame.isLibrary ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
            Text(frame.className)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.tight)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu {
            Button("Drop Frame", action: onDrop)
                .disabled(!canDrop)
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                        IDEDebugValueList(
                            session: session,
                            groups: [.init(roots: instances)],
                            resetID: "\(instancesOf ?? "")-\(instances.map(\.id).joined(separator: ","))",
                            emptyMessage: instancesOf == nil
                                ? "Select a class to list its instances."
                                : "No instances of this class."
                        )
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
        IDEChromeTabItem(title: "Debug", isSelected: isSelected, onSelect: onSelect) {
            Image(systemName: "ladybug")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } trailing: {
            EmptyView()
        }
    }
}
