import AppKit
import SwiftTerm
import SwiftUI

// MARK: - Shell helpers

private enum IDETerminalShell {
    static func resolvedShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize > 0 else {
            return fallbackShell()
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0,
           let shell = result?.pointee.pw_shell {
            return String(cString: shell)
        }
        return fallbackShell()
    }

    /// Login-shell argv[0] (`-zsh`) so profile/rc files load like Terminal.app.
    static func loginExecName(for shell: String) -> String {
        "-" + (shell as NSString).lastPathComponent
    }

    private static func fallbackShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}

// MARK: - Host view

@MainActor
final class IDETerminalHostView: NSView {
    private let terminalView = LocalProcessTerminalView(frame: .zero)
    private let coordinator = TerminalCoordinator()
    private var isActive = false
    private var pendingFocus = false

    var workingDirectory: URL?
    var onTitleUpdate: ((String) -> Void)?
    var onDirectoryUpdate: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        coordinator.host = self
        terminalView.processDelegate = coordinator
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.nativeBackgroundColor = IDEAppearance.NSToken.editor
        terminalView.nativeForegroundColor = IDEAppearance.NSToken.foreground
        terminalView.caretColor = IDEAppearance.NSToken.accent
        terminalView.layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        terminalView.optionAsMetaKey = true
        applyEditorFont(
            name: IDEPreferences.shared.fontName,
            size: IDEPreferences.shared.fontSize
        )
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        terminalView.needsLayout = true
        if isActive {
            startProcessIfNeeded()
            if pendingFocus {
                pendingFocus = false
                requestFocus()
            }
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            startProcessIfNeeded()
        }
    }

    func applyEditorFont(name: String, size: Double) {
        terminalView.font = IDEEditorFonts.nsFont(familyName: name, size: CGFloat(size))
    }

    func requestFocus() {
        window?.makeFirstResponder(terminalView)
    }

    func scheduleFocus() {
        pendingFocus = true
        if bounds.width > 0, bounds.height > 0 {
            pendingFocus = false
            DispatchQueue.main.async { [weak self] in
                self?.requestFocus()
            }
        }
    }

    func syncWorkingDirectory(_ url: URL?) {
        workingDirectory = url ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func restartProcess() {
        if terminalView.process.running {
            terminalView.terminate()
        }
        startProcessIfNeeded()
    }

    func terminateProcess() {
        isActive = false
        if terminalView.process.running {
            terminalView.terminate()
        }
    }

    private var pendingCommands: [String] = []

    func sendCommand(_ command: String) {
        let line = command.hasSuffix("\n") ? command : command + "\n"
        pendingCommands.append(line)
        flushPendingCommands()
        guard !pendingCommands.isEmpty else { return }
        // The shell may not be running until the view is laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.flushPendingCommands()
        }
    }

    func startProcessIfNeeded() {
        guard isActive else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard !terminalView.process.running else {
            flushPendingCommands()
            return
        }

        let shell = IDETerminalShell.resolvedShell()
        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: nil,
            execName: IDETerminalShell.loginExecName(for: shell),
            currentDirectory: cwd
        )
        flushPendingCommands()
    }

    private func flushPendingCommands() {
        guard terminalView.process.running, !pendingCommands.isEmpty else { return }
        for command in pendingCommands {
            terminalView.send(txt: command)
        }
        pendingCommands.removeAll()
    }

    func handleProcessTerminated() {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startProcessIfNeeded()
        }
    }

    private final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var host: IDETerminalHostView?

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor [weak host] in
                host?.onTitleUpdate?(title)
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            Task { @MainActor [weak host] in
                host?.onDirectoryUpdate?(url)
            }
        }

        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak host] in
                host?.handleProcessTerminated()
            }
        }
    }
}

@MainActor
private enum IDETerminalCommandDelivery {
    static var lastTicket: UInt64 = 0
}

// MARK: - Representable

private struct IDETerminalHostRepresentable: NSViewRepresentable {
    let tabID: UUID
    let workingDirectory: URL?
    let isActive: Bool
    let fontName: String
    let fontSize: Double
    let focusRequestID: UInt64
    let restartRequestID: UInt64
    let commandTicket: UInt64
    let command: String?
    let onTitleUpdate: (String) -> Void
    let onDirectoryUpdate: (URL) -> Void

    func makeNSView(context: Context) -> IDETerminalHostView {
        let view = IDETerminalHostView(frame: .zero)
        view.workingDirectory = workingDirectory
        view.onTitleUpdate = onTitleUpdate
        view.onDirectoryUpdate = onDirectoryUpdate
        view.setActive(isActive)
        view.applyEditorFont(name: fontName, size: fontSize)
        context.coordinator.hostView = view
        context.coordinator.lastFocusRequestID = focusRequestID
        context.coordinator.lastRestartRequestID = restartRequestID
        if isActive {
            view.scheduleFocus()
        }
        deliver(command, ticket: commandTicket, to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: IDETerminalHostView, context: Context) {
        view.onTitleUpdate = onTitleUpdate
        view.onDirectoryUpdate = onDirectoryUpdate
        view.applyEditorFont(name: fontName, size: fontSize)
        view.syncWorkingDirectory(workingDirectory)
        let wasActive = context.coordinator.wasActive
        view.setActive(isActive)
        context.coordinator.wasActive = isActive

        if isActive && !wasActive {
            view.scheduleFocus()
        }

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            if isActive {
                view.scheduleFocus()
            }
        }

        if context.coordinator.lastRestartRequestID != restartRequestID {
            context.coordinator.lastRestartRequestID = restartRequestID
            if isActive {
                view.restartProcess()
            }
        }
        deliver(command, ticket: commandTicket, to: view, coordinator: context.coordinator)
    }

    private func deliver(_ command: String?, ticket: UInt64, to view: IDETerminalHostView, coordinator: Coordinator) {
        // One ticket is delivered once, by whichever host is selected when the view exists.
        // Remembering it per view would replay the command when switching terminal tabs.
        guard let command, ticket > IDETerminalCommandDelivery.lastTicket else { return }
        IDETerminalCommandDelivery.lastTicket = ticket
        coordinator.lastCommandTicket = ticket
        view.sendCommand(command)
    }

    func dismantleNSView(_ nsView: IDETerminalHostView, coordinator: Coordinator) {
        nsView.terminateProcess()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var hostView: IDETerminalHostView?
        var lastFocusRequestID: UInt64 = 0
        var lastRestartRequestID: UInt64 = 0
        var lastCommandTicket: UInt64 = 0
        var wasActive = false
    }
}

// MARK: - Panel

struct IDETerminalPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                IDETerminalTabsBar()
                Button(action: { workspace.addTerminalTab() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("New Terminal Tab")
                .accessibilityLabel("New Terminal Tab")
                if workspace.isUsagesSelected {
                    IDEUsagesControls()
                } else if workspace.isProblemsSelected {
                    IDEProblemsControls()
                } else if workspace.isSourceControlSelected {
                    IDESourceControlControls()
                } else if workspace.isGradleConsoleSelected {
                    IDEGradleConsoleControls()
                } else if workspace.isHTTPConsoleSelected {
                    IDEHTTPConsoleControls()
                } else {
                    Button(action: workspace.restartTerminal) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Restart shell")
                    .accessibilityLabel("Restart shell")
                }
                Button(action: workspace.hideTerminal) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)

            ZStack {
                ForEach(workspace.terminalTabs) { tab in
                    let isSelected = workspace.isTerminalTabSelected
                        && tab.id == workspace.selectedTerminalTabID
                    IDETerminalHostRepresentable(
                        tabID: tab.id,
                        workingDirectory: tab.workingDirectory,
                        isActive: workspace.isTerminalVisible && isSelected,
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize,
                        focusRequestID: workspace.terminalFocusRequestID,
                        restartRequestID: tab.restartRequestID,
                        commandTicket: isSelected ? workspace.terminalCommandTicket : 0,
                        command: isSelected ? workspace.pendingTerminalCommand : nil,
                        onTitleUpdate: { workspace.updateTerminalTabTitle(tab.id, title: $0) },
                        onDirectoryUpdate: { workspace.updateTerminalTabDirectory(tab.id, url: $0) }
                    )
                    .id(tab.id)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                }

                if workspace.showsGradleConsoleTab {
                    IDEGradleConsoleView(
                        log: workspace.javaSupport.gradleConsole,
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize
                    )
                    .opacity(workspace.isGradleConsoleSelected ? 1 : 0)
                    .allowsHitTesting(workspace.isGradleConsoleSelected)
                }

                if workspace.showsHTTPTab {
                    IDEHTTPResponseView(
                        log: workspace.httpSupport.responseLog,
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize
                    )
                    .opacity(workspace.isHTTPConsoleSelected ? 1 : 0)
                    .allowsHitTesting(workspace.isHTTPConsoleSelected)
                }

                if workspace.showsProblemsTab {
                    IDEProblemsPanel()
                        .opacity(workspace.isProblemsSelected ? 1 : 0)
                        .allowsHitTesting(workspace.isProblemsSelected)
                }

                if workspace.showsTypeHierarchyTab {
                    IDETypeHierarchyPanel()
                        .opacity(workspace.isTypeHierarchySelected ? 1 : 0)
                        .allowsHitTesting(workspace.isTypeHierarchySelected)
                }

                if workspace.showsUsagesTab {
                    IDEUsagesPanel()
                        .opacity(workspace.isUsagesSelected ? 1 : 0)
                        .allowsHitTesting(workspace.isUsagesSelected)
                }

                if workspace.showsTestResultsTab {
                    IDETestResultsPanel()
                        .opacity(workspace.isTestResultsSelected ? 1 : 0)
                        .allowsHitTesting(workspace.isTestResultsSelected)
                }

                if workspace.showsSourceControlTab {
                    IDESourceControlPanel(gitStatus: workspace.gitStatus)
                        .opacity(workspace.isSourceControlSelected ? 1 : 0)
                        .allowsHitTesting(workspace.isSourceControlSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(IDEAppearance.ColorToken.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .onExitCommand { workspace.hideTerminal() }
    }
}

/// Header controls shown in place of the shell's restart button while the Gradle console tab is
/// selected: elapsed time, Cancel (syncing) or Reload (idle), and Copy.
private struct IDEGradleConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            elapsedTimeView
            actionButton
            Button(action: copyOutput) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Copy Gradle Output")
            .accessibilityLabel("Copy Gradle Output")
        }
    }

    @ViewBuilder
    private var elapsedTimeView: some View {
        if let startedAt = workspace.javaSupport.gradleConsole.startedAt {
            if workspace.javaSupport.isGradleBusy {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.formattedElapsed(context.date.timeIntervalSince(startedAt)))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            } else if let finishedAt = workspace.javaSupport.gradleConsole.finishedAt {
                Text(Self.formattedElapsed(finishedAt.timeIntervalSince(startedAt)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if workspace.javaSupport.isGradleBusy {
            Button("Cancel", action: workspace.cancelGradleOperation)
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } else {
            Button(action: workspace.reloadGradleProject) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Reload Gradle Project")
            .accessibilityLabel("Reload Gradle Project")
        }
    }

    private func copyOutput() {
        let text = workspace.javaSupport.gradleConsole.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func formattedElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct IDEHTTPConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if let statusCode = workspace.httpSupport.lastStatusCode {
                Text("HTTP \(statusCode)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if workspace.httpSupport.isSending {
                Text("Sending…")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let duration = workspace.httpSupport.lastDuration {
                Text(String(format: "%.0f ms", duration * 1000))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Button(action: copyOutput) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Copy HTTP Response")
            .accessibilityLabel("Copy HTTP Response")
        }
    }

    private func copyOutput() {
        let text = workspace.httpSupport.responseLog.lines.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
