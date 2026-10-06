import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// `undo:` and `redo:` are what Edit menus send down the responder chain. AppKit no longer
/// declares them on `NSResponder` (`TextInputView` provides them). This type only exists so
/// those selectors can be formed; nothing sends the actions to it.
private final class IDEEditMenuAction: NSObject {
    @objc(undo:) func undo(_ sender: Any?) {}
    @objc(redo:) func redo(_ sender: Any?) {}
}

/// The menu bar. Every item acts on the focused window's workspace (`IDEWorkspace` is published
/// per window with `focusedSceneValue`); with no window focused the items are disabled or absent,
/// except New Window, which always works.
struct IDEAppCommands: Commands {
    @FocusedValue(\.ideWorkspace) private var focused
    @Environment(\.openWindow) private var openWindow

    /// Resolved when read. Closures below capture `self`, which holds only the weak handle.
    private var workspace: IDEWorkspace? { focused?.workspace }

    var body: some Commands {
        // `CommandsBuilder` only takes 10 children on older SDKs (Xcode 26.3 in CI); group to stay under.
        Group {
            CommandGroup(replacing: .appInfo) {
                Button("About Umbra") { IDEAbout.show() }
                Button("Check for Updates…") { IDEAppUpdater.checkForUpdates(nil) }
                    .disabled(!IDEAppUpdater.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", systemImage: "gearshape") { workspace?.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(workspace == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Window Tab", systemImage: "plus.rectangle.on.rectangle") {
                    IDEWindowRegistry.shared.openNewTab()
                }
                Divider()
                IDEFileCommands(ref: focused)
            }

            // SwiftUI's default Undo/Redo items call the environment undo manager, which is
            // not the editor's `TimedUndoManager`, and their ⌘Z / ⌘⇧Z equivalents consume the
            // key before `TextInputView` sees it. Send the actions down the responder chain
            // so the focused editor (or a focused text field) uses its own stack.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if !NSApp.sendAction(#selector(IDEEditMenuAction.undo(_:)), to: nil, from: nil) {
                        workspace?.undoActiveEditor()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if !NSApp.sendAction(#selector(IDEEditMenuAction.redo(_:)), to: nil, from: nil) {
                        workspace?.redoActiveEditor()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                if let focused {
                    IDEFindCommands(ref: focused)
                }
            }
        }

        CommandMenu("Go") {
            if let focused { IDEGoCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandMenu("Run") {
            if let focused { IDERunCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandMenu("Git") {
            if let focused { IDEGitCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandMenu("Java") {
            if let focused { IDEJavaCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandMenu("HTTP") {
            if let focused { IDEHTTPCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandMenu("View") {
            if let focused { IDEViewCommands(ref: focused) } else { IDENoWindowCommand() }
        }

        CommandGroup(replacing: .help) {
            Button("Welcome to Umbra") { workspace?.showFirstRunGuide() }
                .disabled(workspace == nil)
            Divider()
            Button("Umbra on GitHub") {
                if let url = URL(string: "https://github.com/alex-cova/Penumbra") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// Shown in a menu while no window is focused.
private struct IDENoWindowCommand: View {
    var body: some View {
        Button("No Open Window") {}
            .disabled(true)
    }
}

/// The File menu's documents, folders and recents. Open Folder… and Open Recent work with no window
/// focused (they route to a window, or open a new one); the rest need one.
private struct IDEFileCommands: View {
    let ref: IDEWorkspaceRef?

    private var workspace: IDEWorkspace? { ref?.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }
    private var origin: IDEOpenOrigin { workspace.map { .window($0.windowID) } ?? .external }

    var body: some View {
        Button("New File", systemImage: "doc.badge.plus") { workspace?.newFile() }
            .menuShortcut(.newFile, in: preset)
            .disabled(workspace == nil)
        Button("Open…", systemImage: "folder") { workspace?.openFile() }
            .menuShortcut(.openFile, in: preset)
            .disabled(workspace == nil)
        Button("Open Folder…", systemImage: "folder.badge.plus") {
            IDEWindowRegistry.shared.chooseFolder(from: origin)
        }
        .menuShortcut(.openFolder, in: preset)
        Button("Close Folder", systemImage: "folder.badge.minus") { workspace?.closeFolder() }
            .disabled(!(workspace?.hasOpenProject ?? false))
        Divider()
        Button("Save", systemImage: "square.and.arrow.down") {
            Task { await workspace?.saveActiveDocument() }
        }
        .menuShortcut(.save, in: preset)
        .disabled(workspace == nil)
        Button("Save As…", systemImage: "square.and.arrow.down.on.square") {
            Task { await workspace?.saveActiveDocumentAs() }
        }
        .menuShortcut(.saveAs, in: preset)
        .disabled(workspace == nil)
        Divider()
        Button("Close Tab", systemImage: "xmark") { workspace?.closeActiveTab() }
            .menuShortcut(.closeTab, in: preset)
            .disabled(workspace == nil)
        IDEOpenRecentMenu(origin: origin)
    }
}

/// Open Recent, from the shared recent lists, so it lists the same entries in every window and with
/// none open. It holds the window's id, not the workspace: SwiftUI keeps this menu's content
/// closures after the window closes, and a captured workspace would stay alive with them.
private struct IDEOpenRecentMenu: View {
    let origin: IDEOpenOrigin

    private var appState: IDEAppState { IDEAppState.shared }

    var body: some View {
        if !appState.recentProjects.isEmpty || !appState.recentFiles.isEmpty {
            Divider()
            Menu("Open Recent") {
                if !appState.recentProjects.isEmpty {
                    ForEach(appState.recentProjects, id: \.path) { url in
                        Button(url.lastPathComponent, systemImage: "folder") {
                            IDEWindowRegistry.shared.open(urls: [url], origin: origin)
                        }
                    }
                    if !appState.recentFiles.isEmpty {
                        Divider()
                    }
                }
                ForEach(appState.recentFiles, id: \.path) { url in
                    Button(url.lastPathComponent, systemImage: "doc") {
                        if case .window(let id) = origin,
                           let target = IDEWindowRegistry.shared.workspace(withID: id) {
                            target.openRecentFile(url)
                        } else {
                            IDEWindowRegistry.shared.open(urls: [url])
                        }
                    }
                }
            }
        }
    }
}

/// Find and replace items in the Edit menu.
private struct IDEFindCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Find…", systemImage: "magnifyingglass", action: { workspace?.showFind() })
            .menuShortcut(.find, in: preset)
        Button("Replace…", systemImage: "arrow.left.arrow.right", action: { workspace?.showReplace() })
            .menuShortcut(.replace, in: preset)
        Button("Find in Files…", systemImage: "folder.badge.gearshape", action: { workspace?.showFindInFiles() })
            .menuShortcut(.findInFiles, in: preset)
        Button("Replace in Files…", systemImage: "arrow.left.arrow.right.square", action: { workspace?.showReplaceInFiles() })
            .menuShortcut(.replaceInFiles, in: preset)
    }
}

/// The Go menu.
private struct IDEGoCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Go to File…", action: { workspace?.showQuickOpen() })
            .menuShortcut(.goToFile, in: preset)
        Button("Go to Symbol…", action: { workspace?.showGoToSymbol() })
            .menuShortcut(.goToSymbol, in: preset)
        Button("Tool Window…", action: { workspace?.showToolWindows() })
        Button("File Structure…", action: { workspace?.showFileStructure() })
            .menuShortcut(.fileStructure, in: preset)
        Button("Go to Line…", action: { workspace?.showGoToLine() })
            .menuShortcut(.goToLine, in: preset)
        Button("Next Problem") { workspace?.goToProblem(forward: true) }
            .menuShortcut(.nextProblem, in: preset)
        Button("Previous Problem") { workspace?.goToProblem(forward: false) }
            .menuShortcut(.previousProblem, in: preset)
        Button("Recent Locations…", action: { workspace?.showRecentLocations() })
            .menuShortcut(.recentLocations, in: preset)
        Button("Command Palette…", action: { workspace?.showCommandPalette() })
            .menuShortcut(.commandPalette, in: preset)
    }
}

/// The Run menu: run configurations, breakpoints and the debugger.
private struct IDERunCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Run Last Configuration", action: { workspace?.runLastRunConfiguration() })
            .menuShortcut(.runLastConfiguration, in: preset)
            .disabled(workspace?.lastRunConfiguration == nil)
        Button("Debug Last Configuration", action: { workspace?.debugLastConfiguration() })
            .menuShortcut(.debugLastConfiguration, in: preset)
            .disabled(workspace?.lastRunConfiguration == nil)
        Button("Run in Context", action: { workspace?.runInContext(debug: false) })
            .menuShortcut(.runInContext, in: preset)
        Button("Debug in Context", action: { workspace?.runInContext(debug: true) })
            .menuShortcut(.debugInContext, in: preset)
        Button("Edit Run Configuration…", action: { workspace?.editRunConfiguration() })
            .disabled(!(workspace?.canEditRunConfiguration ?? false))
        Divider()
        Button("Toggle Breakpoint", action: { workspace?.toggleBreakpointAtCaret() })
            .menuShortcut(.toggleBreakpoint, in: preset)
        Button("View Breakpoints…", action: { workspace?.viewBreakpoints() })
            .menuShortcut(.viewBreakpoints, in: preset)
        Toggle("Mute Breakpoints", isOn: Binding(
            get: { workspace?.breakpointsMuted ?? false },
            set: { workspace?.setBreakpointsMuted($0) }
        ))
        .menuShortcut(.muteBreakpoints, in: preset)
        Divider()
        Button("Resume", action: { workspace?.debugResume() })
            .menuShortcut(.debugResume, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Pause", action: { workspace?.debugPause() })
            .menuShortcut(.debugPause, in: preset)
            .disabled(!(workspace?.isDebuggerRunning ?? false))
        Button("Step Over", action: { workspace?.debugStepOver() })
            .menuShortcut(.debugStepOver, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Step Into", action: { workspace?.debugStepInto() })
            .menuShortcut(.debugStepInto, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Step Out", action: { workspace?.debugStepOut() })
            .menuShortcut(.debugStepOut, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Smart Step Into", action: { workspace?.debugSmartStepInto() })
            .menuShortcut(.debugSmartStepInto, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Force Step Into", action: { workspace?.debugForceStepInto() })
            .menuShortcut(.debugForceStepInto, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Run to Cursor", action: { workspace?.debugRunToCursor(force: false) })
            .menuShortcut(.debugRunToCursor, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Force Run to Cursor", action: { workspace?.debugRunToCursor(force: true) })
            .menuShortcut(.debugForceRunToCursor, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Drop Frame", action: { workspace?.debugDropFrame() })
            .menuShortcut(.debugDropFrame, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Force Return…", action: { workspace?.debugForceReturn() })
            .menuShortcut(.debugForceReturn, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Show Execution Point", action: { workspace?.showExecutionPoint() })
            .menuShortcut(.showExecutionPoint, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Trace Current Stream Chain", action: { workspace?.traceCurrentStream() })
            .menuShortcut(.traceStream, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Divider()
        Button("Evaluate Expression…", action: { workspace?.showEvaluateExpression() })
            .menuShortcut(.evaluateExpression, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Button("Quick Evaluate Expression", action: { workspace?.quickEvaluate() })
            .menuShortcut(.quickEvaluate, in: preset)
            .disabled(!(workspace?.isDebuggerStopped ?? false))
        Divider()
        Button("Stop", action: { workspace?.stopDebugging() })
            .menuShortcut(.debugStop, in: preset)
            .disabled(!(workspace?.debugSession.isActive ?? false))
    }
}

/// The Git menu.
private struct IDEGitCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Update Project (Pull)", action: { workspace?.pullProject() })
            .menuShortcut(.gitPull, in: preset)
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Button("Push", action: { workspace?.pushProject() })
            .menuShortcut(.gitPush, in: preset)
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Divider()
        Button("Show History for File", action: { workspace?.showFileHistory() })
            .menuShortcut(.gitFileHistory, in: preset)
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Button(workspace?.isBlameShownForActiveFile == true ? "Hide Git Blame" : "Show Git Blame", action: { workspace?.toggleGitBlame() })
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Button(workspace?.showsChangedLines == true ? "Hide Changed Lines" : "Highlight Changed Lines", action: { workspace?.toggleChangedLines() })
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Button("Revert File…", action: { workspace?.revertActiveFile() })
            .menuShortcut(.gitRevert, in: preset)
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Divider()
        Button("Show Diff with HEAD", action: { workspace?.openWorkingTreeDiff(against: .head, title: "HEAD") })
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Menu("Compare with Branch") {
            ForEach(workspace?.gitStatus.branches ?? [], id: \.self) { branch in
                Button(branch, action: { workspace?.openWorkingTreeDiff(against: .ref(branch), title: branch) })
            }
        }
        .disabled(!(workspace?.gitStatus.isRepository ?? false))
        Button("Compare with Clipboard", action: { workspace?.compareActiveFileWithClipboard() })
        Divider()
        Button("Show Source Control", action: { workspace?.showSourceControl() })
            .disabled(!(workspace?.gitStatus.isRepository ?? false))
    }
}

/// The Java menu: refactorings, Gradle and the project JDK.
private struct IDEJavaCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Show Context Actions", action: { workspace?.showContextActions() })
            .menuShortcut(.showContextActions, in: preset)
        Button("Parameter Info", action: { workspace?.showParameterInfo() })
            .menuShortcut(.parameterInfo, in: preset)
        Button("Go to Super Method", action: { workspace?.goToSuperMethod() })
        Button("Go to Type Declaration", action: { workspace?.goToTypeDefinition() })
            .menuShortcut(.goToTypeDefinition, in: preset)
        Button("Rename…", action: { workspace?.renameSymbol() })
        Button("Extract Variable…", action: { workspace?.extractVariable() })
            .menuShortcut(.extractVariable, in: preset)
        Button("Extract Field…", action: { workspace?.extractField() })
            .menuShortcut(.extractField, in: preset)
        Button("Extract Constant…", action: { workspace?.extractConstant() })
            .menuShortcut(.extractConstant, in: preset)
        Button("Extract Method…", action: { workspace?.extractMethod() })
            .menuShortcut(.extractMethod, in: preset)
        Button("Inline Variable", action: { workspace?.inlineVariable() })
            .menuShortcut(.inlineVariable, in: preset)
        Button("Inline Method", action: { workspace?.inlineMethod() })
        Button("Change Method Signature…", action: { workspace?.changeMethodSignature() })
        Button("Encapsulate Field", action: { workspace?.encapsulateField() })
            .menuShortcut(.encapsulateField, in: preset)
        Button("Generate…", action: { workspace?.generate() })
        Button("Generate Getter and Setter", action: { workspace?.generateAccessors() })
        Button("Move Class…", action: { workspace?.moveClass() })
        Button("Safe Delete", action: { workspace?.safeDelete() })
        Button("Reformat Code", action: { workspace?.reformatCode() })
        Button("Type Hierarchy") { workspace?.showTypeHierarchy() }
        Button("Call Hierarchy") { workspace?.showCallHierarchy() }
        Menu("Diagrams") {
            Button("Show Class Diagram") { workspace?.showClassDiagramForActiveFile() }
                .disabled(!(workspace?.canShowClassDiagram ?? false))
            Button("Show Package Class Diagram") { workspace?.showClassDiagramForActivePackage() }
                .disabled(workspace?.activeJavaFileURL == nil)
            Button("Show Project Class Diagram") { workspace?.showClassDiagramForProject() }
                .disabled(!(workspace?.canShowClassDiagram ?? false))
            Divider()
            Button("Show Gradle Module Diagram") { workspace?.showGradleModuleDiagram() }
                .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
            Button("Show Gradle Dependency Diagram") { workspace?.showGradleDependencyDiagram() }
                .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        }
        Divider()
        Button("Optimize Imports", action: { workspace?.optimizeImports() })
        Divider()
        Menu("Project JDK") {
            IDEJDKMenuFromRef(ref: ref)
        }
        Button("Build Project", systemImage: "hammer", action: { workspace?.buildGradleProject() })
            .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        Button("Reload Gradle Project", action: { workspace?.reloadGradleProject() })
            .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        Button("Show Gradle Output", action: { workspace?.showGradleOutput() })
            .disabled(workspace?.javaSupport.gradleConsole.lines.isEmpty ?? true)
    }
}

/// The HTTP menu.
private struct IDEHTTPCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Send Request", systemImage: "paperplane.fill", action: { workspace?.sendActiveHTTPRequest() })
            .menuShortcut(.sendHTTPRequest, in: preset)
            .disabled(!(workspace?.httpFileCanSend ?? false))
        Button("Show Response", action: { workspace?.showHTTPResponse() })
            .disabled(workspace?.httpSupport.responseLog.lines.isEmpty ?? true)
    }
}

/// The View menu: layout, tool windows, terminal, zoom and editor toggles.
private struct IDEViewCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    /// A binding that reaches the workspace when read or written, instead of capturing it. With the
    /// window gone it reads false and ignores writes.
    private func binding(_ keyPath: KeyPath<IDEWorkspace, Binding<Bool>>) -> Binding<Bool> {
        Binding(
            get: { workspace?[keyPath: keyPath].wrappedValue ?? false },
            set: { workspace?[keyPath: keyPath].wrappedValue = $0 }
        )
    }

    var body: some View {
        Button("Split Editor Right", systemImage: "rectangle.split.2x1", action: { workspace?.splitRight() })
            .menuShortcut(.splitRight, in: preset)
        Button("Split Editor Down", systemImage: "rectangle.split.1x2", action: { workspace?.splitDown() })
            .menuShortcut(.splitDown, in: preset)
        Button("Close Editor Group", systemImage: "rectangle.slash", action: { workspace?.closeActivePane() })
        Button("Next Tab") { workspace?.selectAdjacentTab(forward: true) }
            .menuShortcut(.nextTab, in: preset)
        Button("Previous Tab") { workspace?.selectAdjacentTab(forward: false) }
            .menuShortcut(.previousTab, in: preset)
        Button("Next Editor Group") { workspace?.focusAdjacentPane(forward: true) }
            .menuShortcut(.nextSplit, in: preset)
        Button("Previous Editor Group") { workspace?.focusAdjacentPane(forward: false) }
            .menuShortcut(.previousSplit, in: preset)
        Divider()
        Button("Toggle Sidebar", systemImage: "sidebar.leading", action: { workspace?.toggleSidebar() })
            .menuShortcut(.toggleSidebar, in: preset)
        Button("Toggle Structure", systemImage: "list.bullet.indent", action: { workspace?.toggleStructureSidebar() })
            .menuShortcut(.toggleStructure, in: preset)
        Button("Toggle Breakpoints", systemImage: "circle.fill") {
            workspace?.toggleSidebarTab(.breakpoints)
        }
        Button("Toggle Gradle Sidebar", systemImage: "sidebar.trailing", action: { workspace?.toggleGradleSidebar() })
            .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        Button("Toggle Agent", systemImage: "sparkles", action: { workspace?.toggleAgentPanel() })
            .disabled(!(workspace?.hasOpenProject ?? false))
        Button("Show Local History", systemImage: "clock.arrow.circlepath", action: { workspace?.showLocalHistory() })
            .disabled(!(workspace?.hasOpenProject ?? false))
        Button("Recent Changes", action: { workspace?.showLocalHistory(project: true) })
            .menuShortcut(.recentChanges, in: preset)
            .disabled(!(workspace?.hasOpenProject ?? false))
        Button("Put Label on This Version…", action: { workspace?.putLocalHistoryLabel() })
            .disabled(!(workspace?.hasOpenProject ?? false))
        Divider()
        Button("New Agent Chat", systemImage: "plus.bubble", action: { workspace?.newAgentChat() })
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!(workspace?.hasOpenProject ?? false))
        Button("Run Markdown with Agent", systemImage: "sparkles", action: { workspace?.runActiveMarkdownWithAgent() })
            .menuShortcut(.runMarkdownWithAgent, in: preset)
            .disabled(!(workspace?.canRunMarkdownWithAgent ?? false))
        Button("Next Agent Chat", action: { workspace?.selectAgentChat(1) })
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(!(workspace?.hasOpenProject ?? false) || (workspace?.agent.conversations.count ?? 0) < 2)
        Button("Previous Agent Chat", action: { workspace?.selectAgentChat(-1) })
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(!(workspace?.hasOpenProject ?? false) || (workspace?.agent.conversations.count ?? 0) < 2)
        Button("Reveal Active File in Explorer", systemImage: "scope", action: { workspace?.revealActiveFileInExplorer() })
            .menuShortcut(.revealActiveFile, in: preset)
        Button(
            workspace?.statusLanguage == "json" ? "JSON Diagram" : "Markdown Preview",
            systemImage: workspace?.statusLanguage == "json" ? "curlybraces" : "doc.richtext",
            action: { workspace?.toggleMarkdownPreview() }
        )
            .menuShortcut(.markdownPreview, in: preset)
        Button("Toggle Terminal", systemImage: "terminal", action: { workspace?.toggleTerminal() })
            .menuShortcut(.toggleTerminal, in: preset)
        Button("Toggle Debug", systemImage: "ladybug", action: { workspace?.toggleDebugToolWindow() })
            .menuShortcut(.toggleDebugTool, in: preset)
            .disabled(!(workspace?.showsDebugTab ?? false))
        Button("Hide All Tool Windows", systemImage: "rectangle.compress.vertical", action: { workspace?.toggleAllToolWindows() })
            .menuShortcut(.hideAllToolWindows, in: preset)
        Button("Toggle Problems", systemImage: "exclamationmark.triangle", action: { workspace?.toggleProblems() })
            .menuShortcut(.toggleProblems, in: preset)
        Button("Toggle Changes", systemImage: "arrow.triangle.branch", action: { workspace?.toggleSourceControl() })
            .disabled(!(workspace?.showsSourceControlTab ?? false))
            .menuShortcut(.toggleSourceControl, in: preset)
        Button("New Terminal Tab", systemImage: "plus.rectangle.on.rectangle") {
            workspace?.addTerminalTab()
        }
            .menuShortcut(.newTerminalTab, in: preset)
        Button("Clear Terminal", systemImage: "eraser", action: { workspace?.clearTerminal() })
            .disabled(!(workspace.map { $0.isTerminalVisible && $0.isTerminalTabSelected } ?? false))
        Button("Close Terminal Tab", systemImage: "xmark.rectangle", action: {
            if let id = workspace?.selectedTerminalTabID {
                workspace?.closeTerminalTab(id)
            }
        })
        Button("Next Terminal Tab", action: { workspace?.selectNextTerminalTab() })
            .menuShortcut(.nextTerminalTab, in: preset)
        Button("Previous Terminal Tab", action: { workspace?.selectPreviousTerminalTab() })
            .menuShortcut(.previousTerminalTab, in: preset)
        Divider()
        Button("Zoom In", systemImage: "plus.magnifyingglass", action: { workspace?.zoomIn() })
            .menuShortcut(.zoomIn, in: preset)
        Button("Zoom Out", systemImage: "minus.magnifyingglass", action: { workspace?.zoomOut() })
            .menuShortcut(.zoomOut, in: preset)
        Button("Actual Size", systemImage: "1.magnifyingglass", action: { workspace?.resetZoom() })
            .menuShortcut(.resetZoom, in: preset)
            .disabled(IDEPreferences.shared.zoomPercent == 100)
        Divider()
        Toggle("Line Numbers", isOn: binding(\.showLineNumbersBinding))
        Toggle("Code Folding", isOn: binding(\.isLineFoldingEnabledBinding))
        Toggle("Word Wrap", isOn: binding(\.wrapLinesBinding))
        Toggle("Minimap", isOn: binding(\.showMinimapBinding))
        Toggle("Scrollbars", isOn: binding(\.showScrollbarsBinding))
        Divider()
        Menu("Syntax") {
            ForEach(IDELanguageSupport.selectableSyntaxes) { option in
                Button(option.displayName) {
                    workspace?.setLanguage(identifier: option.id)
                }
                .disabled(!(workspace?.canChangeActiveLanguage ?? false))
            }
        }
        .disabled(!(workspace?.canChangeActiveLanguage ?? false))
        Divider()
        Toggle("Typewriter Scrolling", isOn: binding(\.isTypewriterScrollingEnabledBinding))
        Toggle("Distraction Free", isOn: binding(\.isDistractionFreeModeEnabledBinding))
        Toggle("Focus Mode", isOn: binding(\.isFocusModeEnabledBinding))
        Toggle("Use Metal Renderer", isOn: binding(\.isMetalRenderingEnabledBinding))
    }
}

/// The Project JDK submenu. Built from the handle so the menu holds no workspace of its own; the
/// content needs one in the environment while it is shown.
private struct IDEJDKMenuFromRef: View {
    let ref: IDEWorkspaceRef

    var body: some View {
        // The workspace is read while the body is evaluated and handed to the environment only;
        // the body holds no closure that keeps it.
        if let workspace = ref.workspace {
            IDEJDKMenuContent()
                .environment(workspace)
        }
    }
}
