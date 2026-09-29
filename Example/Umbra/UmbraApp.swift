import AppKit
import SwiftUI

@main
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(IDEAppDelegate.self) private var appDelegate
    @State private var workspace = IDEWorkspace()

    var body: some Scene {
        WindowGroup(id: "main") {
            IDERootView()
                .environment(workspace)
                .frame(minWidth: 960, minHeight: 640)
                .background(IDEWindowReopenBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            let preset = workspace.preferences.keymapPreset
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", systemImage: "gearshape", action: workspace.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New File", systemImage: "doc.badge.plus", action: workspace.newFile)
                    .menuShortcut(.newFile, in: preset)
                Button("Open…", systemImage: "folder", action: workspace.openFile)
                    .menuShortcut(.openFile, in: preset)
                Button("Open Folder…", systemImage: "folder.badge.plus", action: workspace.openFolder)
                    .menuShortcut(.openFolder, in: preset)
                Button("Close Folder", systemImage: "folder.badge.minus", action: workspace.closeFolder)
                    .disabled(!workspace.hasOpenProject)
                Divider()
                Button("Save", systemImage: "square.and.arrow.down") {
                    Task { await workspace.saveActiveDocument() }
                }
                .menuShortcut(.save, in: preset)
                Button("Save As…", systemImage: "square.and.arrow.down.on.square") {
                    Task { await workspace.saveActiveDocumentAs() }
                }
                .menuShortcut(.saveAs, in: preset)
                Divider()
                Button("Close Tab", systemImage: "xmark", action: workspace.closeActiveTab)
                    .menuShortcut(.closeTab, in: preset)
                if !workspace.recentProjectURLs.isEmpty || !workspace.recentFileURLs.isEmpty {
                    Divider()
                    Menu("Open Recent") {
                        if !workspace.recentProjectURLs.isEmpty {
                            ForEach(workspace.recentProjectURLs, id: \.path) { url in
                                Button(url.lastPathComponent, systemImage: "folder") {
                                    workspace.openRecentProject(url)
                                }
                            }
                            if !workspace.recentFileURLs.isEmpty {
                                Divider()
                            }
                        }
                        ForEach(workspace.recentFileURLs, id: \.path) { url in
                            Button(url.lastPathComponent, systemImage: "doc") {
                                workspace.openRecentFile(url)
                            }
                        }
                    }
                }
            }

            // SwiftUI's default Undo/Redo items call the environment undo manager, which is
            // not the editor's `TimedUndoManager`, and their ⌘Z / ⌘⇧Z equivalents consume the
            // key before `TextInputView` sees it. Send the actions down the responder chain
            // so the focused editor (or a focused text field) uses its own stack.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if !NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
                        workspace.undoActiveEditor()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if !NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                        workspace.redoActiveEditor()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("Find…", systemImage: "magnifyingglass", action: workspace.showFind)
                    .menuShortcut(.find, in: preset)
                Button("Replace…", systemImage: "arrow.left.arrow.right", action: workspace.showReplace)
                    .menuShortcut(.replace, in: preset)
                Button("Find in Files…", systemImage: "folder.badge.gearshape", action: workspace.showFindInFiles)
                    .menuShortcut(.findInFiles, in: preset)
                Button("Replace in Files…", systemImage: "arrow.left.arrow.right.square", action: workspace.showReplaceInFiles)
                    .menuShortcut(.replaceInFiles, in: preset)
            }

            CommandMenu("Go") {
                Button("Go to File…", action: workspace.showQuickOpen)
                    .menuShortcut(.goToFile, in: preset)
                Button("Go to Symbol…", action: workspace.showGoToSymbol)
                    .menuShortcut(.goToSymbol, in: preset)
                Button("Tool Window…", action: workspace.showToolWindows)
                Button("File Structure…", action: workspace.showFileStructure)
                    .menuShortcut(.fileStructure, in: preset)
                Button("Go to Line…", action: workspace.showGoToLine)
                    .menuShortcut(.goToLine, in: preset)
                Button("Next Problem") { workspace.goToProblem(forward: true) }
                    .menuShortcut(.nextProblem, in: preset)
                Button("Previous Problem") { workspace.goToProblem(forward: false) }
                    .menuShortcut(.previousProblem, in: preset)
                Button("Recent Locations…", action: workspace.showRecentLocations)
                    .menuShortcut(.recentLocations, in: preset)
                Button("Command Palette…", action: workspace.showCommandPalette)
                    .menuShortcut(.commandPalette, in: preset)
            }

            CommandMenu("Run") {
                Button("Run Last Configuration", action: workspace.runLastRunConfiguration)
                    .menuShortcut(.runLastConfiguration, in: preset)
                    .disabled(workspace.lastRunConfiguration == nil)
                Button("Debug Last Configuration", action: workspace.debugLastConfiguration)
                    .menuShortcut(.debugLastConfiguration, in: preset)
                    .disabled(workspace.lastRunConfiguration == nil)
                Button("Run in Context", action: { workspace.runInContext(debug: false) })
                    .menuShortcut(.runInContext, in: preset)
                Button("Debug in Context", action: { workspace.runInContext(debug: true) })
                    .menuShortcut(.debugInContext, in: preset)
                Button("Edit Run Configuration…", action: workspace.editRunConfiguration)
                    .disabled(!workspace.canEditRunConfiguration)
                Divider()
                Button("Toggle Breakpoint", action: workspace.toggleBreakpointAtCaret)
                    .menuShortcut(.toggleBreakpoint, in: preset)
                Divider()
                Button("Resume", action: workspace.debugResume)
                    .menuShortcut(.debugResume, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Button("Pause", action: workspace.debugPause)
                    .menuShortcut(.debugPause, in: preset)
                    .disabled(!workspace.isDebuggerRunning)
                Button("Step Over", action: workspace.debugStepOver)
                    .menuShortcut(.debugStepOver, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Button("Step Into", action: workspace.debugStepInto)
                    .menuShortcut(.debugStepInto, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Button("Step Out", action: workspace.debugStepOut)
                    .menuShortcut(.debugStepOut, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Divider()
                Button("Evaluate Expression…", action: workspace.showEvaluateExpression)
                    .menuShortcut(.evaluateExpression, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Button("Quick Evaluate Expression", action: workspace.quickEvaluate)
                    .menuShortcut(.quickEvaluate, in: preset)
                    .disabled(!workspace.isDebuggerStopped)
                Divider()
                Button("Stop", action: workspace.stopDebugging)
                    .menuShortcut(.debugStop, in: preset)
                    .disabled(!workspace.debugSession.isActive)
            }

            CommandMenu("Git") {
                Button("Update Project (Pull)", action: workspace.pullProject)
                    .menuShortcut(.gitPull, in: preset)
                    .disabled(!workspace.gitStatus.isRepository)
                Button("Push", action: workspace.pushProject)
                    .menuShortcut(.gitPush, in: preset)
                    .disabled(!workspace.gitStatus.isRepository)
                Divider()
                Button("Show History for File", action: workspace.showFileHistory)
                    .menuShortcut(.gitFileHistory, in: preset)
                    .disabled(!workspace.gitStatus.isRepository)
                Button(workspace.isBlameShownForActiveFile ? "Hide Git Blame" : "Show Git Blame", action: workspace.toggleGitBlame)
                    .disabled(!workspace.gitStatus.isRepository)
                Button("Revert File…", action: workspace.revertActiveFile)
                    .menuShortcut(.gitRevert, in: preset)
                    .disabled(!workspace.gitStatus.isRepository)
                Divider()
                Button("Show Source Control", action: workspace.showSourceControl)
                    .disabled(!workspace.gitStatus.isRepository)
            }

            CommandMenu("Java") {
                Button("Show Context Actions", action: workspace.showContextActions)
                    .menuShortcut(.showContextActions, in: preset)
                Button("Parameter Info", action: workspace.showParameterInfo)
                    .menuShortcut(.parameterInfo, in: preset)
                Button("Go to Super Method", action: workspace.goToSuperMethod)
                Button("Go to Type Declaration", action: workspace.goToTypeDefinition)
                    .menuShortcut(.goToTypeDefinition, in: preset)
                Button("Rename…", action: workspace.renameSymbol)
                Button("Extract Variable…", action: workspace.extractVariable)
                    .menuShortcut(.extractVariable, in: preset)
                Button("Extract Field…", action: workspace.extractField)
                    .menuShortcut(.extractField, in: preset)
                Button("Extract Constant…", action: workspace.extractConstant)
                    .menuShortcut(.extractConstant, in: preset)
                Button("Extract Method…", action: workspace.extractMethod)
                    .menuShortcut(.extractMethod, in: preset)
                Button("Inline Variable", action: workspace.inlineVariable)
                    .menuShortcut(.inlineVariable, in: preset)
                Button("Inline Method", action: workspace.inlineMethod)
                Button("Change Method Signature…", action: workspace.changeMethodSignature)
                Button("Encapsulate Field", action: workspace.encapsulateField)
                    .menuShortcut(.encapsulateField, in: preset)
                Button("Generate Getter and Setter", action: workspace.generateAccessors)
                Button("Move Class…", action: workspace.moveClass)
                Button("Safe Delete", action: workspace.safeDelete)
                Button("Reformat Code", action: workspace.reformatCode)
                Button("Type Hierarchy") { workspace.showTypeHierarchy() }
                Button("Call Hierarchy") { workspace.showCallHierarchy() }
                Divider()
                Button("Optimize Imports", action: workspace.optimizeImports)
                Divider()
                Menu("Project JDK") {
                    IDEJDKMenuContent()
                        .environment(workspace)
                }
                Button("Build Project", systemImage: "hammer", action: workspace.buildGradleProject)
                    .disabled(!workspace.javaSupport.isGradleProject)
                Button("Reload Gradle Project", action: workspace.reloadGradleProject)
                    .disabled(!workspace.javaSupport.isGradleProject)
                Button("Show Gradle Output", action: workspace.showGradleOutput)
                    .disabled(workspace.javaSupport.gradleConsole.lines.isEmpty)
            }

            CommandMenu("HTTP") {
                Button("Send Request", systemImage: "paperplane.fill", action: workspace.sendActiveHTTPRequest)
                    .menuShortcut(.sendHTTPRequest, in: preset)
                    .disabled(!workspace.httpFileCanSend)
                Button("Show Response", action: workspace.showHTTPResponse)
                    .disabled(workspace.httpSupport.responseLog.lines.isEmpty)
            }

            CommandMenu("View") {
                Button("Split Editor Right", systemImage: "rectangle.split.2x1", action: workspace.splitRight)
                    .menuShortcut(.splitRight, in: preset)
                Button("Split Editor Down", systemImage: "rectangle.split.1x2", action: workspace.splitDown)
                    .menuShortcut(.splitDown, in: preset)
                Button("Close Editor Group", systemImage: "rectangle.slash", action: workspace.closeActivePane)
                Button("Next Tab") { workspace.selectAdjacentTab(forward: true) }
                    .menuShortcut(.nextTab, in: preset)
                Button("Previous Tab") { workspace.selectAdjacentTab(forward: false) }
                    .menuShortcut(.previousTab, in: preset)
                Button("Next Editor Group") { workspace.focusAdjacentPane(forward: true) }
                    .menuShortcut(.nextSplit, in: preset)
                Button("Previous Editor Group") { workspace.focusAdjacentPane(forward: false) }
                    .menuShortcut(.previousSplit, in: preset)
                Divider()
                Button("Toggle Sidebar", systemImage: "sidebar.leading", action: workspace.toggleSidebar)
                    .menuShortcut(.toggleSidebar, in: preset)
                Button("Toggle Structure", systemImage: "list.bullet.indent", action: workspace.toggleStructureSidebar)
                    .menuShortcut(.toggleStructure, in: preset)
                    .disabled(!workspace.showsJavaStructureButton)
                Button("Toggle Gradle Sidebar", systemImage: "sidebar.trailing", action: workspace.toggleGradleSidebar)
                    .disabled(!workspace.javaSupport.isGradleProject)
                Button("Reveal Active File in Explorer", systemImage: "scope", action: workspace.revealActiveFileInExplorer)
                    .menuShortcut(.revealActiveFile, in: preset)
                Button("Markdown Preview", systemImage: "doc.richtext", action: workspace.toggleMarkdownPreview)
                    .menuShortcut(.markdownPreview, in: preset)
                Button("Toggle Terminal", systemImage: "terminal", action: workspace.toggleTerminal)
                    .menuShortcut(.toggleTerminal, in: preset)
                Button("Toggle Debug", systemImage: "ladybug", action: workspace.toggleDebugToolWindow)
                    .menuShortcut(.toggleDebugTool, in: preset)
                    .disabled(!workspace.showsDebugTab)
                Button("Hide All Tool Windows", systemImage: "rectangle.compress.vertical", action: workspace.toggleAllToolWindows)
                    .menuShortcut(.hideAllToolWindows, in: preset)
                Button("Toggle Problems", systemImage: "exclamationmark.triangle", action: workspace.toggleProblems)
                    .menuShortcut(.toggleProblems, in: preset)
                Button("Toggle Source Control", systemImage: "arrow.triangle.branch", action: workspace.toggleSourceControl)
                    .disabled(!workspace.showsSourceControlTab)
                    .menuShortcut(.toggleSourceControl, in: preset)
                Button("New Terminal Tab", systemImage: "plus.rectangle.on.rectangle") {
                    workspace.addTerminalTab()
                }
                    .menuShortcut(.newTerminalTab, in: preset)
                Button("Clear Terminal", systemImage: "eraser", action: workspace.clearTerminal)
                    .disabled(!(workspace.isTerminalVisible && workspace.isTerminalTabSelected))
                Button("Close Terminal Tab", systemImage: "xmark.rectangle", action: {
                    if let id = workspace.selectedTerminalTabID {
                        workspace.closeTerminalTab(id)
                    }
                })
                Button("Next Terminal Tab", action: workspace.selectNextTerminalTab)
                    .menuShortcut(.nextTerminalTab, in: preset)
                Button("Previous Terminal Tab", action: workspace.selectPreviousTerminalTab)
                    .menuShortcut(.previousTerminalTab, in: preset)
                Divider()
                Button("Zoom In", systemImage: "plus.magnifyingglass", action: workspace.zoomIn)
                    .menuShortcut(.zoomIn, in: preset)
                Button("Zoom Out", systemImage: "minus.magnifyingglass", action: workspace.zoomOut)
                    .menuShortcut(.zoomOut, in: preset)
                Button("Actual Size", systemImage: "1.magnifyingglass", action: workspace.resetZoom)
                    .menuShortcut(.resetZoom, in: preset)
                    .disabled(workspace.preferences.zoomPercent == 100)
                Divider()
                Toggle("Line Numbers", isOn: workspace.showLineNumbersBinding)
                Toggle("Code Folding", isOn: workspace.isLineFoldingEnabledBinding)
                Toggle("Word Wrap", isOn: workspace.wrapLinesBinding)
                Toggle("Minimap", isOn: workspace.showMinimapBinding)
                Toggle("Scrollbars", isOn: workspace.showScrollbarsBinding)
                Divider()
                Menu("Syntax") {
                    ForEach(IDELanguageSupport.selectableSyntaxes) { option in
                        Button(option.displayName) {
                            workspace.setLanguage(identifier: option.id)
                        }
                        .disabled(!workspace.canChangeActiveLanguage)
                    }
                }
                .disabled(!workspace.canChangeActiveLanguage)
                Divider()
                Toggle("Typewriter Scrolling", isOn: workspace.isTypewriterScrollingEnabledBinding)
                Toggle("Distraction Free", isOn: workspace.isDistractionFreeModeEnabledBinding)
                Toggle("Focus Mode", isOn: workspace.isFocusModeEnabledBinding)
                Toggle("Use Metal Renderer", isOn: workspace.isMetalRenderingEnabledBinding)
            }

            CommandGroup(replacing: .help) {
                Button("Welcome to Umbra", action: workspace.showFirstRunGuide)
                Divider()
                Button("Umbra on GitHub") {
                    if let url = URL(string: "https://github.com/alex-cova/Penumbra") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

    }
}
