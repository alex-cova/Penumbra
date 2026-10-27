import AppKit
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
    /// The child view that owns the shell and the keyboard.
    private let ghosttyView = GhosttyTerminalView(frame: .zero)
    /// The terminal got the keyboard: IntelliJ saves files "when switching to … a built-in terminal".
    /// The view's `becomeFirstResponder` is not open to override, so the window's first responder
    /// is watched instead.
    var onFocus: (() -> Void)?
    private var firstResponderObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        firstResponderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, change in
            guard let self, let responder = change.newValue ?? nil else { return }
            MainActor.assumeIsolated {
                if responder === self.ghosttyView { self.onFocus?() }
            }
        }
    }
    private var isActive = false
    /// Set once `terminateProcess()` ran. The window is closing, but SwiftUI can still update this view
    /// (tearing down changes the state it reads) and ask it to become active again, which would start a
    /// new shell in a window that is going away.
    private var isShutDown = false
    private var pendingFocus = false

    /// Whether this is the terminal tab the user is looking at.
    var isShownActive: Bool { isActive && !isShutDown }
    /// An agent command tab displays text and never starts a shell.
    private var mirrorsOutput = false
    private var pendingMirror = ""

    /// The last `lines` non-empty lines of the screen and scrollback, as text.
    func recentText(lines: Int) -> String? {
        ghosttyView.recentText(lines: lines)
    }

    var workingDirectory: URL?
    var onTitleUpdate: ((String) -> Void)?
    var onDirectoryUpdate: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let child: NSView = ghosttyView
        ghosttyView.onTitleUpdate = { [weak self] in self?.onTitleUpdate?($0) }
        ghosttyView.onDirectoryUpdate = { [weak self] in self?.onDirectoryUpdate?($0) }
        ghosttyView.onProcessTerminated = { [weak self] in self?.handleProcessTerminated() }
        ghosttyView.translatesAutoresizingMaskIntoConstraints = false
        ghosttyView.optionAsMeta = true
        ghosttyView.applyColors(
            background: IDEAppearance.NSToken.editor,
            foreground: IDEAppearance.NSToken.foreground,
            cursor: IDEAppearance.NSToken.accent)
        applyEditorFont(
            name: IDEPreferences.shared.fontName,
            size: IDEPreferences.shared.fontSize
        )
        // Inset so the prompt doesn't touch the bottom panel card's rounded edge; the host paints
        // the terminal's background so the inset reads as part of the terminal.
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IDEAppearance.Spacing.sm),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        if mirrorsOutput {
            flushMirror()
            return
        }
        if isActive {
            startProcessIfNeeded()
            if pendingFocus {
                pendingFocus = false
                requestFocus()
            }
        }
    }

    func applyUIColorScheme() {
        ghosttyView.applyColors(
            background: IDEAppearance.NSToken.editor,
            foreground: IDEAppearance.NSToken.foreground,
            cursor: IDEAppearance.NSToken.accent)
        ghosttyView.setNeedsDisplay(ghosttyView.bounds)
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
    }

    func setMirrorsOutput(_ mirror: Bool) {
        mirrorsOutput = mirror
        ghosttyView.setMirrorsOutput(mirror)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active, !mirrorsOutput {
            startProcessIfNeeded()
        }
    }

    func applyEditorFont(name: String, size: Double) {
        let font = IDEEditorFonts.nsFont(familyName: name, size: CGFloat(size))
        ghosttyView.applyFont(font)
    }

    func requestFocus() {
        window?.makeFirstResponder(ghosttyView)
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
        guard !mirrorsOutput, !isShutDown else { return }
        // SIGHUP is what actually ends an interactive shell (SIGTERM is ignored),
        // so the next start uses the working directory just set (closing a folder
        // retargets the shell at the home directory). The backend already SIGHUPs
        // (plus a tty hangup) inside terminate; the extra kill here is a harmless
        // no-op for it.
        if ghosttyView.isProcessRunning {
            let pid = ghosttyView.shellPid
            ghosttyView.terminateProcess()
            if pid > 0 {
                kill(pid, SIGHUP)
            }
        }
        startProcessIfNeeded()
    }

    /// Draws text into a command tab. Queued until the view has a size, then fed to the terminal.
    func feedOutput(_ text: String) {
        guard mirrorsOutput, !text.isEmpty else { return }
        pendingMirror += text
        flushMirror()
    }

    private func flushMirror() {
        guard mirrorsOutput, !pendingMirror.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        ghosttyView.feedOutput(pendingMirror)
        pendingMirror.removeAll(keepingCapacity: true)
    }

    /// Wipes the screen and scrollback, then sends Ctrl-L so the shell draws its prompt again.
    func clearScreen() {
        ghosttyView.feedOutput("\u{1B}[H\u{1B}[2J\u{1B}[3J")
        ghosttyView.send(Data([0x0C]))
    }

    /// ⌘K clears the terminal, as in Terminal.app and IntelliJ's terminal. It is claimed only while
    /// this terminal has the keyboard: in an editor ⌘K starts the ⌘K ⌘D chord.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === ghosttyView, modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            clearScreen()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Ends the shell. SIGHUP is what a closing terminal sends, and shells
    /// (and their foreground jobs) exit on it.
    func terminateProcess() {
        isActive = false
        isShutDown = true
        guard ghosttyView.isProcessRunning else { return }
        let pid = ghosttyView.shellPid
        ghosttyView.terminateProcess()
        if pid > 0 {
            kill(pid, SIGHUP)
        }
    }

    func startProcessIfNeeded() {
        guard !mirrorsOutput else { return }
        guard isActive, !isShutDown else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard !ghosttyView.isProcessRunning else { return }

        let shell = IDETerminalShell.resolvedShell()
        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
        ghosttyView.startProcess(
            executable: shell,
            execName: IDETerminalShell.loginExecName(for: shell),
            currentDirectory: cwd)
    }

    func handleProcessTerminated() {
        guard isActive, !mirrorsOutput else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startProcessIfNeeded()
        }
    }
}

// MARK: - Representable

private struct IDETerminalHostRepresentable: NSViewRepresentable {
    let tabID: UUID
    let workingDirectory: URL?
    let isActive: Bool
    let fontName: String
    let fontSize: Double
    let uiColorSchemeID: String
    let focusRequestID: UInt64
    let restartRequestID: UInt64
    let clearRequestID: UInt64
    let mirrorsOutput: Bool
    let agentFeedGeneration: UInt64
    let takeAgentFeed: () -> String
    let onTitleUpdate: (String) -> Void
    let onDirectoryUpdate: (URL) -> Void
    /// Tells the workspace about the view, so closing the window can end its shell.
    let onHostCreated: (IDETerminalHostView) -> Void

    func makeNSView(context: Context) -> IDETerminalHostView {
        let view = IDETerminalHostView(frame: .zero)
        onHostCreated(view)
        view.workingDirectory = workingDirectory
        view.onTitleUpdate = onTitleUpdate
        view.onDirectoryUpdate = onDirectoryUpdate
        view.setMirrorsOutput(mirrorsOutput)
        view.setActive(isActive)
        view.applyEditorFont(name: fontName, size: fontSize)
        context.coordinator.hostView = view
        context.coordinator.lastFocusRequestID = focusRequestID
        context.coordinator.lastRestartRequestID = restartRequestID
        context.coordinator.lastClearRequestID = clearRequestID
        context.coordinator.lastUIColorSchemeID = uiColorSchemeID
        if isActive, !mirrorsOutput {
            view.scheduleFocus()
        }
        deliverAgentFeed(generation: agentFeedGeneration, to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: IDETerminalHostView, context: Context) {
        view.onTitleUpdate = onTitleUpdate
        view.onDirectoryUpdate = onDirectoryUpdate
        view.setMirrorsOutput(mirrorsOutput)
        view.applyEditorFont(name: fontName, size: fontSize)
        view.syncWorkingDirectory(workingDirectory)
        if context.coordinator.lastUIColorSchemeID != uiColorSchemeID {
            context.coordinator.lastUIColorSchemeID = uiColorSchemeID
            view.applyUIColorScheme()
        }
        let wasActive = context.coordinator.wasActive
        view.setActive(isActive)
        context.coordinator.wasActive = isActive

        if isActive && !wasActive && !mirrorsOutput {
            view.scheduleFocus()
        }

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            if isActive, !mirrorsOutput {
                view.scheduleFocus()
            }
        }

        if context.coordinator.lastClearRequestID != clearRequestID {
            context.coordinator.lastClearRequestID = clearRequestID
            if isActive {
                view.clearScreen()
            }
        }

        if context.coordinator.lastRestartRequestID != restartRequestID {
            context.coordinator.lastRestartRequestID = restartRequestID
            if isActive {
                view.restartProcess()
            }
        }
        deliverAgentFeed(generation: agentFeedGeneration, to: view, coordinator: context.coordinator)
    }

    private func deliverAgentFeed(generation: UInt64, to view: IDETerminalHostView, coordinator: Coordinator) {
        guard mirrorsOutput, generation != coordinator.lastAgentFeedGeneration else { return }
        coordinator.lastAgentFeedGeneration = generation
        view.feedOutput(takeAgentFeed())
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
        var lastClearRequestID: UInt64 = 0
        var lastAgentFeedGeneration: UInt64 = 0
        var lastUIColorSchemeID = ""
        var wasActive = false
    }
}

// MARK: - Panel

struct IDETerminalPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let _ = workspace.uiColorSchemeEpoch
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
                if workspace.isBottomTabSelected(.usages) {
                    IDEUsagesControls()
                } else if workspace.isBottomTabSelected(.problems) {
                    IDEProblemsControls()
                } else if workspace.isBottomTabSelected(.sourceControl) {
                    IDESourceControlControls()
                } else if let controls = workspace.languageModuleBottomTabs()
                    .first(where: { $0.tab == workspace.selectedBottomTab })?.controls {
                    // A language module's tab brings its own header controls.
                    controls(workspace)
                } else {
                    Button(action: workspace.restartTerminal) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Restart shell")
                    .accessibilityLabel("Restart shell")
                }
                Button(action: workspace.toggleBottomPanelExpanded) {
                    Image(systemName: workspace.isBottomPanelExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help(workspace.isBottomPanelExpanded ? "Restore Panel Size" : "Expand Over the Editor")
                .accessibilityLabel(workspace.isBottomPanelExpanded ? "Restore Panel Size" : "Expand Over the Editor")
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
                        uiColorSchemeID: workspace.preferences.uiColorSchemeID,
                        focusRequestID: workspace.terminalFocusRequestID,
                        restartRequestID: tab.restartRequestID,
                        clearRequestID: tab.clearRequestID,
                        mirrorsOutput: tab.agentCommandID != nil,
                        agentFeedGeneration: tab.agentFeedGeneration,
                        takeAgentFeed: { [weak workspace = workspace] in workspace?.takeAgentCommandFeed(tabID: tab.id) ?? "" },
                        // Weak: a running shell keeps its terminal view alive, and a strong capture
                        // here would keep the whole workspace alive through it after the window closes.
                        onTitleUpdate: { [weak workspace = workspace] in workspace?.updateTerminalTabTitle(tab.id, title: $0) },
                        onDirectoryUpdate: { [weak workspace = workspace] in workspace?.updateTerminalTabDirectory(tab.id, url: $0) },
                        onHostCreated: { [weak workspace = workspace] in workspace?.registerTerminalHost($0) }
                    )
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                }

                if workspace.showsProblemsTab {
                    IDEProblemsPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(workspace.isBottomTabSelected(.problems) ? 1 : 0)
                        .allowsHitTesting(workspace.isBottomTabSelected(.problems))
                }

                if workspace.showsUsagesTab {
                    IDEUsagesPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(workspace.isBottomTabSelected(.usages) ? 1 : 0)
                        .allowsHitTesting(workspace.isBottomTabSelected(.usages))
                }

                if workspace.showsSourceControlTab {
                    IDESourceControlPanel(gitStatus: workspace.gitStatus)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(workspace.isBottomTabSelected(.sourceControl) ? 1 : 0)
                        .allowsHitTesting(workspace.isBottomTabSelected(.sourceControl))
                }

                // The language modules' tabs (Run, Gradle, HTTP, hierarchies, tests, debugger).
                ForEach(workspace.languageModuleBottomTabs(), id: \.tab) { contribution in
                    let isSelected = workspace.selectedBottomTab == contribution.tab
                    contribution.content(workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(IDEAppearance.ColorToken.panel)
        .onExitCommand { workspace.hideTerminal() }
    }
}

/// Header controls shown in place of the shell's restart button while the Gradle console tab is
/// selected: elapsed time, Cancel (syncing) or Reload (idle), and Copy.
struct IDEHTTPConsoleControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if let statusCode = workspace.httpSupport.lastStatusCode {
                Text("HTTP \(statusCode)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(Color.httpStatus(statusCode) ?? IDEAppearance.ColorToken.muted)
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
            Button(action: { workspace.httpSupport.resend() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .disabled(!workspace.httpSupport.canResend)
            .help("Send Request Again")
            .accessibilityLabel("Send Request Again")
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
