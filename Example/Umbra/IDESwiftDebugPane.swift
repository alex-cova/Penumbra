import SwiftUI

/// The Debug tool window while a Swift `lldb-dap` session is the one running: frames, variables,
/// evaluate, stepping and the program's output. Java-only panes stay on the Java session.
struct IDESwiftDebugPane: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var evaluateFieldFocused: Bool
    @State private var pane = Pane.debugger

    private enum Pane: String, CaseIterable, Identifiable {
        case debugger = "Debugger"
        case console = "Console"
        var id: String { rawValue }
    }

    var body: some View {
        let session = workspace.dapDebugSession
        VStack(spacing: 0) {
            toolbar(session)
            Divider()
            switch pane {
            case .debugger:
                SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.debug.swift.stackSplit") {
                    frames(session)
                } secondary: {
                    SplitPanes(minPrimary: 200, minSecondary: 180, storageKey: "umbra.debug.swift.evaluateSplit") {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toolbar(_ session: DAPDebugSession) -> some View {
        let stopped = session.isStopped
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: 2) {
                ForEach(Pane.allCases) { candidate in
                    Button {
                        pane = candidate
                    } label: {
                        Text(candidate.rawValue)
                            .font(IDEAppearance.Typography.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(pane == candidate ? IDEAppearance.ColorToken.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().frame(height: 14)
            tool("play.fill", "Resume", enabled: stopped, color: .green) { session.resume() }
            tool("pause.fill", "Pause", enabled: session.state == .running) { session.pause() }
            tool("stop.fill", "Stop", enabled: session.isActive, color: .red) { workspace.stopDebugging() }
            Divider().frame(height: 14)
            tool("arrow.turn.down.right", "Step Over", enabled: stopped) { session.stepOver() }
            tool("arrow.down.to.line", "Step Into", enabled: stopped) { session.stepInto() }
            tool("arrow.up.to.line", "Step Out", enabled: stopped) { session.stepOut() }
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
    private func status(_ session: DAPDebugSession) -> some View {
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
            Text("Paused at \(file?.lastPathComponent ?? "frame"):\(line)")
        case .terminated:
            Text("Debug session ended")
        case .failed(let message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func frames(_ session: DAPDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Frames")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                if !session.threads.isEmpty {
                    Picker("", selection: Binding(
                        get: { session.selectedThreadID ?? session.threads.first?.id ?? 0 },
                        set: { session.selectThread($0) }
                    )) {
                        ForEach(session.threads) { thread in
                            Text(thread.name).tag(thread.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!session.isStopped)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            List(session.frames, selection: Binding(
                get: { session.selectedFrameID },
                set: { id in
                    guard let id else { return }
                    session.selectFrame(id)
                    if let frame = session.frames.first(where: { $0.id == id }), let file = frame.file {
                        workspace.revealDebugStop(file: file, line: frame.line, selectsLine: false)
                    }
                }
            )) { frame in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(frame.name):\(frame.line)")
                        .font(IDEAppearance.Typography.body)
                    Text(frame.file?.lastPathComponent ?? "")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                .tag(frame.id)
            }
        }
    }

    private func variables(_ session: DAPDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Variables")
                .font(IDEAppearance.Typography.caption.weight(.semibold))
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
            List(session.variables) { variable in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(variable.name) = \(variable.value)")
                        .font(IDEAppearance.Typography.monoSmall)
                        .lineLimit(2)
                    if !variable.type.isEmpty {
                        Text(variable.type)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func evaluateSection(_ session: DAPDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Evaluate")
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                Spacer()
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
                .onSubmit { Task { await session.submitEvaluation() } }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.xs)
            List(session.evaluations) { evaluation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(evaluation.expression)
                        .font(IDEAppearance.Typography.monoSmall.weight(.semibold))
                        .lineLimit(1)
                    Text(evaluation.result)
                        .font(IDEAppearance.Typography.caption)
                        .lineLimit(3)
                }
            }
        }
    }

    private func consolePane(_ session: DAPDebugSession) -> some View {
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
        }
        .onAppear { console.markRead() }
        .onChange(of: console.revision) { console.markRead() }
    }
}
