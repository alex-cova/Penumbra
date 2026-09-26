import SwiftUI

struct IDEDebugPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let session = workspace.debugSession
        VStack(spacing: 0) {
            toolbar(session)
            Divider()
            SplitPanes(minPrimary: 220, minSecondary: 220, storageKey: "umbra.debug.stackSplit") {
                stackList(session)
            } secondary: {
                variablesList(session)
            } divider: {
                Splitter.rule()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func toolbar(_ session: JavaDebugSession) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
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
            Button("Step Over") { session.stepOver() }
                .disabled(!canControl(session))
            Button("Stop") { workspace.stopDebugging() }
                .disabled(!session.isActive)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
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
            List(session.stackFrames) { frame in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(frame.className).\(frame.name)")
                        .font(IDEAppearance.Typography.body)
                    Text("\((frame.filePath as NSString).lastPathComponent):\(frame.line)")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .tag(frame.index)
            }
            .onChange(of: session.selectedFrameIndex) { _, index in
                session.selectFrame(index)
            }
        }
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
