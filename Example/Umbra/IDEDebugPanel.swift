import SwiftUI

struct IDEDebugPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var evaluateFieldFocused: Bool
    @State private var handledFocusRequest = 0
    @State private var pane = Pane.debugger

    private enum Pane: String, CaseIterable, Identifiable {
        case debugger = "Debugger"
        case console = "Console"

        var id: String { rawValue }
    }

    var body: some View {
        let session = workspace.debugSession
        VStack(spacing: 0) {
            toolbar(session)
            Divider()
            switch pane {
            case .debugger:
                SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.debug.stackSplit") {
                    stackList(session)
                } secondary: {
                    SplitPanes(minPrimary: 200, minSecondary: 220, storageKey: "umbra.debug.evaluateSplit") {
                        variablesList(session)
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

    @ViewBuilder
    private func toolbar(_ session: JavaDebugSession) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            paneSwitcher(session)
            switch session.state {
            case .idle:
                Text("Not debugging")
            case .launching:
                ProgressView().controlSize(.small)
                Text("Launching…")
            case .running:
                Text("Running")
            case .stopped(_, let line, let reason):
                Text("Paused at line \(line) (\(reason))")
            case .terminated:
                Text("Debug session ended")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
            Spacer()
            Button("Resume") { session.resume() }
                .disabled(!canControl(session))
            Button("Pause") { session.pause() }
                .disabled(!isRunning(session))
            Button("Step Over") { session.stepOver() }
                .disabled(!canControl(session))
            Button("Step Into") { session.stepInto() }
                .disabled(!canControl(session))
            Button("Step Out") { session.stepOut() }
                .disabled(!canControl(session))
            Button("Stop") { workspace.stopDebugging() }
                .disabled(!session.isActive)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func isRunning(_ session: JavaDebugSession) -> Bool {
        if case .running = session.state { return true }
        return false
    }

    private func canControl(_ session: JavaDebugSession) -> Bool {
        if case .stopped = session.state { return true }
        return false
    }

    private func stackList(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Call Stack")
                .font(IDEAppearance.Typography.caption.weight(.semibold))
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
            List(session.stackFrames, selection: Binding(
                get: { session.selectedFrameIndex },
                set: { session.selectFrame($0) }
            )) { frame in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(frame.className).\(frame.name)")
                        .font(IDEAppearance.Typography.body)
                    Text("\((frame.filePath as NSString).lastPathComponent):\(frame.line)")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .tag(frame.index)
            }
        }
    }

    private func evaluateSection(_ session: JavaDebugSession) -> some View {
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
                .disabled(!canControl(session))
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
                        IDEDebugValueRow(session: session, value: value)
                    case .failure(let message):
                        Text(message)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        Task { @MainActor in evaluateFieldFocused = true }
    }

    private func variablesList(_ session: JavaDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Variables")
                .font(IDEAppearance.Typography.caption.weight(.semibold))
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
            List(session.variables) { variable in
                HStack {
                    Text(variable.name)
                        .font(IDEAppearance.Typography.body.weight(.medium))
                    Text(variable.type)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Spacer()
                    Text(variable.value)
                        .font(IDEAppearance.Typography.monoSmall)
                        .lineLimit(1)
                }
            }
        }
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
