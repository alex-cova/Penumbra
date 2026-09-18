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
        applyFontSize(IDEPreferences.shared.fontSize)
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

    func applyFontSize(_ size: Double) {
        terminalView.font = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

    func updateWorkingDirectory(_ url: URL?) {
        let resolved = url ?? FileManager.default.homeDirectoryForCurrentUser
        guard workingDirectory?.path != resolved.path else { return }
        workingDirectory = resolved
        restartProcess()
    }

    func restartProcess() {
        if terminalView.process.running {
            terminalView.terminate()
        }
        startProcessIfNeeded()
    }

    func startProcessIfNeeded() {
        guard isActive else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard !terminalView.process.running else { return }

        let shell = IDETerminalShell.resolvedShell()
        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: nil,
            execName: IDETerminalShell.loginExecName(for: shell),
            currentDirectory: cwd
        )
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

        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak host] in
                host?.handleProcessTerminated()
            }
        }
    }
}

// MARK: - Representable

private struct IDETerminalHostRepresentable: NSViewRepresentable {
    let workingDirectory: URL?
    let isActive: Bool
    let fontSize: Double
    let focusRequestID: UInt64
    let restartRequestID: UInt64

    func makeNSView(context: Context) -> IDETerminalHostView {
        let view = IDETerminalHostView(frame: .zero)
        view.workingDirectory = workingDirectory
        view.setActive(isActive)
        view.applyFontSize(fontSize)
        context.coordinator.hostView = view
        context.coordinator.lastFocusRequestID = focusRequestID
        if isActive {
            view.scheduleFocus()
        }
        return view
    }

    func updateNSView(_ view: IDETerminalHostView, context: Context) {
        view.applyFontSize(fontSize)
        view.updateWorkingDirectory(workingDirectory)
        let wasActive = context.coordinator.wasActive
        view.setActive(isActive)
        context.coordinator.wasActive = isActive

        if isActive && !wasActive {
            view.scheduleFocus()
        }

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            view.scheduleFocus()
        }

        if context.coordinator.lastRestartRequestID != restartRequestID {
            context.coordinator.lastRestartRequestID = restartRequestID
            view.restartProcess()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var hostView: IDETerminalHostView?
        var lastFocusRequestID: UInt64 = 0
        var lastRestartRequestID: UInt64 = 0
        var wasActive = false
    }
}

// MARK: - Panel

struct IDETerminalPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text("Terminal")
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
                Button(action: workspace.restartTerminal) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Restart shell")
                .accessibilityLabel("Restart shell")
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

            IDETerminalHostRepresentable(
                workingDirectory: workspace.terminalWorkingDirectory,
                isActive: workspace.isTerminalVisible,
                fontSize: workspace.preferences.fontSize,
                focusRequestID: workspace.terminalFocusRequestID,
                restartRequestID: workspace.terminalRestartRequestID
            )
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
