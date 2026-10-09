import AppKit
import SwiftUI

/// The bottom panel's Run tab: a chip for each session when there are several, the selected
/// session's console, and an input line for the program's standard input.
struct IDERunPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let runs = workspace.runs
        VStack(spacing: 0) {
            if runs.sessions.count > 1 {
                IDERunSessionStrip()
                Divider().overlay(IDEAppearance.ColorToken.border)
            }
            ZStack {
                ForEach(runs.sessions) { session in
                    let isSelected = session.id == runs.selected?.id
                    IDERunConsoleView(
                        log: session.log,
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize,
                        onOpenFrame: { [weak workspace = workspace] in workspace?.openStackFrame($0) },
                        scrollToEndRequest: isSelected ? workspace.runScrollToEndRequest : 0
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                }
                if runs.sessions.isEmpty {
                    Text("Nothing has run yet")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let session = runs.selected, session.acceptsInput {
                Divider().overlay(IDEAppearance.ColorToken.border)
                IDERunInputBar(session: session)
            }
        }
    }
}

/// One chip per session: its name, a spinner or status mark, and × to close it.
private struct IDERunSessionStrip: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.runs.sessions) { session in
                    IDEChromeTabItem(
                        title: workspace.runs.title(for: session),
                        isSelected: session.id == workspace.runs.selected?.id,
                        accessibilityLabel: "\(session.title), \(session.statusText)",
                        onSelect: { workspace.runs.select(session.id) }
                    ) {
                        IDERunStatusMark(session: session)
                    } trailing: {
                        IDEChromeTabCloseButton(side: 14, onClose: { workspace.closeRunSession(session.id) })
                    }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 2)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
    }
}

struct IDERunStatusMark: View {
    let session: IDERunSession

    var body: some View {
        switch session.state {
        case .preparing:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .running:
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.green)
        case .exited(let code):
            Image(systemName: code == 0 ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(code == 0 ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
        case .stopped:
            Image(systemName: "stop.fill")
                .font(.system(size: 9))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        case .signaled, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(IDEAppearance.ColorToken.error)
        }
    }
}

/// A line of input for the running program. Return sends it; ⌃D closes standard input.
private struct IDERunInputBar: View {
    let session: IDERunSession
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("Input for the program — Return sends, ⌃D ends input", text: $text)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($isFocused)
                .onSubmit {
                    session.sendInput(text)
                    text = ""
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "d"), phases: .down) { press in
                    guard press.modifiers.contains(.control), text.isEmpty else { return .ignored }
                    session.closeInput()
                    return .handled
                }
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 6)
        .background(IDEAppearance.ColorToken.panel)
        .accessibilityLabel("Program input")
    }
}

/// Header controls shown in place of the shell's restart button while the Run tab is selected:
/// status and elapsed time, Rerun, Stop, Clear and Copy.
struct IDERunControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if let session = workspace.runs.selected {
                status(of: session)
                Button { workspace.rerun(session) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Rerun")
                    .accessibilityLabel("Rerun")
                Button { session.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(session.isActive ? Color.red : IDEAppearance.ColorToken.muted)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                    .disabled(!session.isActive)
                Button { workspace.runScrollToEndRequest += 1 } label: { Image(systemName: "arrow.down.to.line") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Scroll to End")
                    .accessibilityLabel("Scroll to End")
                Button { session.clearConsole() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Clear Console")
                    .accessibilityLabel("Clear Console")
                Menu {
                    Button("Copy Output") { copy(session.log.plainText) }
                    Button("Copy Command Line") { copy(session.commandLine ?? "") }
                        .disabled(session.commandLine == nil)
                    Divider()
                    Button("Close Finished Runs") { workspace.runs.closeFinished() }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy")
                .accessibilityLabel("Copy")
            }
        }
    }

    @ViewBuilder
    private func status(of session: IDERunSession) -> some View {
        if session.isActive {
            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                Text(Self.elapsed(context.date.timeIntervalSince(session.startedAt)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        } else if let finished = session.finishedAt {
            Text("\(session.statusText) · \(Self.elapsed(finished.timeIntervalSince(session.startedAt)))")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The bottom panel's "Run" tab in the strip next to the shells.
struct IDERunTabItem: View {
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void

    var body: some View {
        IDEChromeTabItem(title: "Run", isSelected: isSelected, onSelect: onSelect) {
            if isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Image(systemName: "play")
                    .font(.system(size: 10))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        } trailing: {
            EmptyView()
        }
    }
}
