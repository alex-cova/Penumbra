import AppKit
import EditorIntelligence
import HTTPClient
import JavaIntelligence
import Observation
import Penumbra
import SwiftUI
import PenumbraLanguages
import PenumbraMarkdownLanguage

struct IDETabRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isDirty: Bool
    let isSelected: Bool
}

struct IDETerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var workingDirectory: URL
    var restartRequestID: UInt64 = 0

    static func defaultTitle(for directory: URL) -> String {
        let base = directory.lastPathComponent
        return base.isEmpty ? "Terminal" : base
    }
}

extension IDETerminalTab: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory
    }
}

/// One segment in the toolbar breadcrumb. Folders reveal in the Explorer; symbols jump in-file.
struct IDEBreadcrumbItem: Equatable, Identifiable {
    enum Target: Equatable {
        case folder(URL)
        case symbol(EditorIntelligence.TextRange)
    }

    let id: String
    let title: String
    let target: Target
}

/// Folder path plus enclosing symbols for the active document. Empty when nothing is open.
/// The filename is omitted: the tab already shows it.
struct IDEHeaderContext: Equatable {
    var documentID: UUID?
    var pathItems: [IDEBreadcrumbItem] = []
    var symbolItems: [IDEBreadcrumbItem] = []
    var isDirty = false

    var items: [IDEBreadcrumbItem] { pathItems + symbolItems }
}

/// Holds the workspace for the Java navigation provider without capturing `IDEWorkspace` in a
/// `@Sendable` closure. The provider calls it off the main actor and hops back here.
private final class NavigationBufferBridge: @unchecked Sendable {
    nonisolated(unsafe) weak var workspace: IDEWorkspace?
}

@MainActor
@Observable
public final class IDEWorkspace {
    private static let languageProvider = BundledLanguageProvider()

    private let workbench = EditorWorkbench()
    private let workspaceBridge = PenumbraWorkbenchWorkspaceBridge()
    private let hostCache = EditorHostCache<UUID, IDEEditorPaneHost>(maxEntries: 16)
    private let intelligenceServices = IDEIntelligenceServices()
    private let navigationBuffers = NavigationBufferBridge()
    private var adapter: PenumbraWorkbenchEditorAdapter!
    @ObservationIgnored
    private var paletteController: CommandPaletteController?
    @ObservationIgnored
    private weak var paletteOverlayContainer: NSView?
    @ObservationIgnored
    private var hostedPaneIDs: Set<UUID> = []
    private var hasPresentedMetalFailure = false
    private var recentFiles: [URL] = []
    private var recentProjects: [URL] = []

    public let preferences = IDEPreferences.shared
    let project = IDEProjectModel()
    let gitStatus = IDEGitStatusModel()
    private let projectWatcher = IDEProjectWatcher()
    @ObservationIgnored
    private let fileIndexer = IDEPaletteFileIndexer()

    var javaSupport: IDEJavaSupport { intelligenceServices.javaSupport }

    public init() {}

    var isSidebarVisible = false
    var isGradleSidebarVisible = true
    var gradleSidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var chromeOpacity = 1.0
    private(set) var layoutEpoch: UInt64 = 0
    private(set) var activePaneID = UUID()
    /// Mirrors whether any document is open. `hasOpenDocuments` reads the workbench, which is
    /// not observable, so this stored flag is what refreshes the welcome-vs-editor switch.
    private(set) var showsWelcome = true
    var showsFirstRunGuide = false

    var windowTitle = "Umbra"
    var headerContext = IDEHeaderContext()
    var statusLine = 1
    var statusColumn = 1
    var statusLanguage = ""
    /// True when the active editor is a Java file with `public static void main` (either modifier
    /// order) and there is something to launch: the file itself, or a Gradle `run` task.
    var javaFileCanRun = false
    private var javaRunFileURL: URL?
    /// True when the active editor is an HTTP request file with a parsable request at the caret.
    var httpFileCanSend = false
    let httpSupport = IDEHTTPSupport()
    /// Bumped when the play button should type a command into the selected terminal.
    var terminalCommandTicket: UInt64 = 0
    var pendingTerminalCommand: String?
    var isMarkdownPreviewVisible = false
    var statusSelectionLength = 0
    var statusRenderer = "Core Graphics"
    var tabsByPane: [UUID: [IDETabRow]] = [:]
    /// Standardized paths of every open document, so the Explorer can mark files open in a tab.
    private(set) var openDocumentPaths: Set<String> = []
    @ObservationIgnored private var lastAutoRevealedDocumentID: UUID?
    var isFindInFilesVisible = false
    var findInFilesQuery = ""
    var findInFilesHits: [ProjectSearchResult] = []
    var findInFilesStatus = ""
    var isTerminalVisible = false
    var terminalHeight = IDEAppearance.Spacing.terminalDefaultHeight
    var terminalFocusRequestID: UInt64 = 0
    var terminalTabs: [IDETerminalTab] = []
    var selectedTerminalTabID: UUID?
    /// True when the bottom panel's read-only "Gradle" console tab is showing instead of a shell.
    /// Not persisted in the session -- each launch starts on a shell (or no terminal at all).
    var isGradleConsoleSelected = false
    /// True when the bottom panel's read-only "HTTP" response tab is showing instead of a shell.
    var isHTTPConsoleSelected = false
    /// True when the bottom panel's Source Control tab is showing instead of a shell.
    var isSourceControlSelected = false
    /// Whether the "Gradle" tab should appear at all: while a sync is running, or once one has
    /// produced output worth revisiting.
    var showsGradleConsoleTab: Bool {
        javaSupport.isGradleProject
            && (javaSupport.isGradleBusy || !javaSupport.gradleConsole.lines.isEmpty)
    }
    /// Whether the "HTTP" tab should appear for the active `.http` file or after a request runs.
    var showsHTTPTab: Bool {
        statusLanguage == "http" || httpSupport.isSending || !httpSupport.responseLog.lines.isEmpty
    }
    /// Whether the "Source Control" tab should appear for the open git repository.
    var showsSourceControlTab: Bool {
        gitStatus.isRepository
    }

    var editorLayout: EditorLayout { workbench.layout }
    var hasOpenDocuments: Bool { !workbench.allDocuments().isEmpty }
    /// Whether the active document's syntax can be changed from the status bar or View > Syntax.
    var canChangeActiveLanguage: Bool {
        guard let document = workbench.activePane.selectedDocument else { return false }
        return !IDELanguageSupport.isLanguageLocked(for: document)
    }
    /// What `IDERootView` should actually render — just the user's sidebar toggle. The Explorer
    /// stays visible even with no folder or documents open, showing its own empty state.
    var showsSidebar: Bool { isSidebarVisible }
    /// Right-hand Gradle panel — modules and dependencies — only for Gradle project folders.
    var showsGradleSidebar: Bool { isGradleSidebarVisible && javaSupport.isGradleProject }

    func host(for paneID: UUID) -> IDEEditorPaneHost {
        hostedPaneIDs.insert(paneID)
        return hostCache.host(for: paneID) {
            makeHost(paneID: paneID)
        }
    }

    func focusActiveEditor() {
        host(for: workbench.activePaneID).textView.focusTextInputWhenReady()
    }

    /// Used when ⌘Z / ⌘⇧Z is not delivered to the focused control (a SwiftUI host with no
    /// `undo:` implementation). The editor's own undo manager is the stack those shortcuts edit.
    func undoActiveEditor() {
        host(for: workbench.activePaneID).textView.undoManager?.undo()
    }

    func redoActiveEditor() {
        host(for: workbench.activePaneID).textView.undoManager?.redo()
    }

    func bootstrap() {
        applyLaunchConfiguration()
        intelligenceServices.javaSupport.requestTrust = { [weak self] url in
            guard let self else { return false }
            return await self.promptGradleTrust(for: url)
        }
        intelligenceServices.javaSupport.onGradleSyncFailed = { [weak self] in
            self?.showGradleOutput()
        }
        intelligenceServices.javaSupport.onGradleModelChanged = { [weak self] model in
            self?.fileIndexer.setGradleModel(model)
        }
        loadSession()
        wireAdapter()
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()
        showsWelcome = !hasOpenDocuments
        showsFirstRunGuide = !preferences.hasCompletedFirstRunGuide

        if let index = CommandLine.arguments.firstIndex(of: "--open"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await openDocument(from: url) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--open-folder"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            isSidebarVisible = true
            applyProjectRoot(url)
        }

        navigationBuffers.workspace = self
        Task {
            await intelligenceServices.javaSupport.navigationProvider.setOpenBufferLookup { [navigationBuffers] url in
                await MainActor.run {
                    navigationBuffers.workspace?.openBufferText(for: url)
                }
            }
            await intelligenceServices.javaSupport.navigationProvider.setDecompilerConsent(
                accepted: preferences.javaDecompilerAgreementAccepted,
                request: { [navigationBuffers] in
                    await navigationBuffers.workspace?.requestDecompilerConsent() ?? false
                }
            )
            await workspaceBridge.syncWorkbench(workbench)
            await workspaceBridge.workspace.connect(to: adapter)
            await intelligenceServices.indexingService.connect(to: workspaceBridge.workspace)
            await intelligenceServices.javaSupport.connect(to: workspaceBridge.workspace)
        }

        (NSApp.delegate as? IDEAppDelegate)?.workspace = self
    }

    // MARK: - Commands

    public func showFirstRunGuide() {
        showsFirstRunGuide = true
    }

    public func dismissFirstRunGuide() {
        showsFirstRunGuide = false
        preferences.hasCompletedFirstRunGuide = true
    }

    public func newFile() {
        let document = WorkbenchDocument(
            displayName: "Untitled",
            text: "",
            language: nil,
            languageIdentifier: nil
        )
        workbench.openDocument(document)
        showsWelcome = false
        // Layout is unchanged — only the active pane's selected document is. Reloading every
        // pane here used to bump a file-backed document's `contentGeneration` and then rebuild
        // sibling split panes from empty `document.text`, blanking both editors.
        let pane = workbench.activePane
        showDocument(in: pane, host: host(for: pane.id))
        activatePane(workbench.activePaneID)
        layoutEpoch += 1
        refreshPresentation()
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    /// Sets the syntax highlighting language for the given pane's selected document (the active
    /// pane by default), the way Sublime Text's "View > Syntax" / status bar syntax picker does.
    /// `identifier` is a ``LanguageIdentifier`` string, or `nil` for plain text — needed since
    /// `newFile()` opens documents with no language and today gives the user no way to pick one.
    public func setLanguage(identifier: String?, in pane: EditorPane? = nil) {
        let targetPane = pane ?? workbench.activePane
        guard let document = targetPane.selectedDocument else { return }
        guard !IDELanguageSupport.isLanguageLocked(for: document) else { return }
        document.languageIdentifier = identifier
        document.language = IDELanguageSupport.language(forIdentifier: identifier)

        let languageMode: LanguageMode
        if let language = document.language {
            languageMode = TreeSitterLanguageMode(language: language, languageProvider: Self.languageProvider)
        } else {
            languageMode = PlainTextLanguageMode()
        }
        host(for: targetPane.id).textView.setLanguageMode(languageMode)

        if targetPane.id == workbench.activePaneID {
            statusLanguage = identifier ?? ""
        }
        Task { await workspaceBridge.syncPane(targetPane) }
    }

    public func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { await self.openDocument(from: url) }
        }
    }

    public func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            _ = url.startAccessingSecurityScopedResource()
            self.isSidebarVisible = true
            self.applyProjectRoot(url)
            self.refreshPresentation()
            self.saveSession()
        }
    }

    public func openRecentFile(_ url: URL) {
        Task { await openDocument(from: url) }
    }

    public func openRecentProject(_ url: URL) {
        applyProjectRoot(url)
        isSidebarVisible = true
        showsWelcome = !hasOpenDocuments
        refreshPresentation()
        saveSession()
    }

    public var recentFileURLs: [URL] {
        recentFiles
    }

    public var recentProjectURLs: [URL] {
        recentProjects
    }

    public func saveActiveDocument() async {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument else { return }
        let textView = host(for: pane.id).textView
        var destination = document.url
        if destination == nil {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = document.displayName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        do {
            _ = try await document.save(from: textView, to: destination)
            recordRecentFile(destination!)
            gitStatus.refresh()
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    public func saveActiveDocumentAs() async {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument else { return }
        let textView = host(for: pane.id).textView
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.displayName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try await document.save(from: textView, to: url)
            recordRecentFile(url)
            gitStatus.refresh()
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    public func closeActiveTab() {
        guard let document = workbench.activePane.selectedDocument else { return }
        closeDocument(document.id, in: workbench.activePane)
    }

    public func showCommandPalette() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentFindAction()
    }

    public func showQuickOpen() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentQuickOpen()
    }

    public func showGoToSymbol() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentSymbols()
    }

    public func showGoToLine() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentGoToLine()
    }

    public func showFind() {
        adapter.textView?.perform(.toggleFindPanel)
        focusActiveEditor()
    }

    public func showReplace() {
        adapter.textView?.perform(.toggleReplacePanel)
        focusActiveEditor()
    }

    public func showFindInFiles() {
        isFindInFilesVisible = true
        if findInFilesStatus.isEmpty {
            findInFilesStatus = project.rootURL == nil
                ? "Open a folder to search the project"
                : "Enter a query and press Return"
        }
    }

    func hideFindInFiles() {
        isFindInFilesVisible = false
        focusActiveEditor()
    }

    var javaRunHelp: String {
        javaSupport.isGradleProject ? "Run Gradle project" : "Run Java file"
    }

    /// Hammer for an open Gradle project. Types `./gradlew build` (or `gradle build`) into the
    /// terminal so the whole project, including every subproject, is built.
    public func buildGradleProject() {
        guard javaSupport.isGradleProject, let root = project.rootURL else { return }
        let wrapper = FileManager.default.fileExists(atPath: root.appendingPathComponent("gradlew").path)
        let command = JavaLaunchCommand.build(projectRoot: root, gradleWrapperExists: wrapper)
        runInTerminal(command.shellCommand)
    }

    /// Play button for a Java file that has `main`. Gradle projects get `gradle run` (or
    /// `./gradlew :module:run` when the file sits in a subproject). Other files are launched with
    /// `java File.java`.
    public func runActiveJava() {
        guard javaFileCanRun else { return }
        let root = project.rootURL
        let wrapper = root.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("gradlew").path)
        } ?? false
        guard let command = JavaLaunchCommand.make(
            file: javaRunFileURL,
            projectRoot: root,
            isGradleProject: javaSupport.isGradleProject,
            model: javaSupport.gradleModel,
            gradleWrapperExists: wrapper
        ) else { return }
        runInTerminal(command.shellCommand)
    }

    public func sendActiveHTTPRequest() {
        guard httpFileCanSend else { return }
        let host = host(for: workbench.activePaneID)
        let textView = host.textView
        let fileURL = workbench.activePane.selectedDocument?.url
        showHTTPResponse()
        httpSupport.send(
            text: textView.text,
            caretUTF16Offset: textView.selectedRange.location,
            fileURL: fileURL
        )
    }

    func showHTTPResponse() {
        selectHTTPConsoleTab()
    }

    private func runInTerminal(_ command: String) {
        // Build and run always need an actual shell, even if the Gradle console tab is what's
        // currently showing.
        isGradleConsoleSelected = false
        isHTTPConsoleSelected = false
        isSourceControlSelected = false
        if terminalTabs.isEmpty {
            addTerminalTab(saveSession: false)
        } else if !isTerminalVisible {
            isTerminalVisible = true
            requestTerminalFocus()
        }
        pendingTerminalCommand = command
        terminalCommandTicket += 1
    }

    public func toggleTerminal() {
        isTerminalVisible.toggle()
        if isTerminalVisible {
            // Leave the Gradle console showing if that's what's already selected; only a shell
            // toggle (no tabs at all yet) needs a fresh tab created for it.
            if terminalTabs.isEmpty && !isGradleConsoleSelected && !isHTTPConsoleSelected && !isSourceControlSelected {
                addTerminalTab(saveSession: false)
            }
            requestTerminalFocus()
        } else {
            focusActiveEditor()
        }
        saveSession()
    }

    public func showTerminal() {
        if !isTerminalVisible {
            toggleTerminal()
        }
    }

    func hideTerminal() {
        if isTerminalVisible {
            toggleTerminal()
        }
    }

    func syncTerminalWorkingDirectory() {
        // New tabs use `defaultTerminalDirectory()`; existing tabs keep their cwd.
    }

    func addTerminalTab(cwd: URL? = nil, saveSession: Bool = true) {
        isGradleConsoleSelected = false
        isHTTPConsoleSelected = false
        isSourceControlSelected = false
        let tab = makeTerminalTab(cwd: cwd)
        terminalTabs.append(tab)
        selectedTerminalTabID = tab.id
        if !isTerminalVisible {
            isTerminalVisible = true
        }
        requestTerminalFocus()
        if saveSession {
            self.saveSession()
        }
    }

    func closeTerminalTab(_ id: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }

        if terminalTabs.count == 1 {
            terminalTabs.removeAll()
            selectedTerminalTabID = nil
            if showsGradleConsoleTab {
                isGradleConsoleSelected = true
            } else if showsSourceControlTab {
                isSourceControlSelected = true
            } else {
                hideTerminal()
            }
            return
        }

        let selectedIndex = terminalTabs.firstIndex(where: { $0.id == selectedTerminalTabID }) ?? 0
        let countBeforeRemoval = terminalTabs.count
        terminalTabs.remove(at: index)

        if let newIndex = TabListEngine.selectionIndexAfterClose(
            closing: index,
            selected: selectedIndex,
            count: countBeforeRemoval
        ) {
            selectedTerminalTabID = terminalTabs[newIndex].id
        } else {
            selectedTerminalTabID = terminalTabs.first?.id
        }
        requestTerminalFocus()
        saveSession()
    }

    func selectTerminalTab(_ id: UUID) {
        guard terminalTabs.contains(where: { $0.id == id }) else { return }
        isGradleConsoleSelected = false
        isHTTPConsoleSelected = false
        isSourceControlSelected = false
        selectedTerminalTabID = id
        requestTerminalFocus()
        saveSession()
    }

    /// Selects the read-only Gradle console tab -- backs both clicking it directly and
    /// `showGradleOutput()`.
    func selectGradleConsoleTab() {
        isGradleConsoleSelected = true
        isHTTPConsoleSelected = false
        isSourceControlSelected = false
        if !isTerminalVisible {
            isTerminalVisible = true
            saveSession()
        }
    }

    func selectHTTPConsoleTab() {
        isHTTPConsoleSelected = true
        isGradleConsoleSelected = false
        isSourceControlSelected = false
        if !isTerminalVisible {
            isTerminalVisible = true
            saveSession()
        }
    }

    func selectSourceControlTab() {
        isSourceControlSelected = true
        isGradleConsoleSelected = false
        isHTTPConsoleSelected = false
        if !isTerminalVisible {
            isTerminalVisible = true
            saveSession()
        }
        gitStatus.refresh()
    }

    func showSourceControl() {
        selectSourceControlTab()
    }

    func toggleSourceControl() {
        if isTerminalVisible && isSourceControlSelected {
            hideTerminal()
        } else {
            showSourceControl()
        }
    }

    func cancelGradleSync() {
        javaSupport.cancelGradleSync()
    }

    func cancelGradleOperation() {
        if javaSupport.gradleSync.isSyncing {
            cancelGradleSync()
        } else if javaSupport.isRunningGradleTasks {
            javaSupport.cancelGradleTasks()
        }
    }

    func runGradleTask(_ taskPath: String) {
        showGradleOutput()
        javaSupport.runGradleTasks([taskPath])
    }

    func restartTerminal() {
        restartTerminalTab(selectedTerminalTabID)
    }

    func restartTerminalTab(_ id: UUID?) {
        guard let id = id ?? selectedTerminalTabID,
              let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        terminalTabs[index].restartRequestID += 1
        selectedTerminalTabID = id
        requestTerminalFocus()
    }

    func selectNextTerminalTab() {
        guard isTerminalVisible, !terminalTabs.isEmpty,
              let selectedID = selectedTerminalTabID,
              let currentIndex = terminalTabs.firstIndex(where: { $0.id == selectedID }),
              let nextIndex = TabListEngine.nextIndex(after: currentIndex, count: terminalTabs.count) else { return }
        selectTerminalTab(terminalTabs[nextIndex].id)
    }

    func selectPreviousTerminalTab() {
        guard isTerminalVisible, !terminalTabs.isEmpty,
              let selectedID = selectedTerminalTabID,
              let currentIndex = terminalTabs.firstIndex(where: { $0.id == selectedID }),
              let previousIndex = TabListEngine.previousIndex(before: currentIndex, count: terminalTabs.count) else { return }
        selectTerminalTab(terminalTabs[previousIndex].id)
    }

    func updateTerminalTabTitle(_ id: UUID, title: String) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, terminalTabs[index].title != trimmed else { return }
        terminalTabs[index].title = trimmed
    }

    func updateTerminalTabDirectory(_ id: UUID, url: URL) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        guard terminalTabs[index].workingDirectory.path != url.path else { return }
        terminalTabs[index].workingDirectory = url
    }

    func requestTerminalFocus() {
        terminalFocusRequestID += 1
    }

    func runFindInFiles() {
        isFindInFilesVisible = true
        let query = findInFilesQuery
        guard let root = project.rootURL else {
            findInFilesHits = []
            findInFilesStatus = "Open a folder to search the project"
            return
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findInFilesHits = []
            findInFilesStatus = "Enter a query and press Return"
            return
        }
        guard let intelligenceController = host(for: workbench.activePaneID).intelligenceController else {
            return
        }
        findInFilesStatus = "Searching…"
        Task {
            let hits = await intelligenceController.searchProject(query, in: root)
            findInFilesHits = hits
            if hits.isEmpty {
                findInFilesStatus = "No results"
            } else if hits.count == 1 {
                findInFilesStatus = "1 result"
            } else {
                findInFilesStatus = "\(hits.count) results"
            }
        }
    }

    /// Opens a Go to Definition target. A file already open is focused without reloading it, so a
    /// dirty buffer keeps the user's edits. JDK and dependency sources extracted into the index
    /// cache are ordinary files the read-only check in ``applyState`` then locks.
    @discardableResult
    func openNavigationLocation(_ location: Location) -> Bool {
        let current = host(for: workbench.activePaneID)
        current.textView.recordNavigationCheckpoint()
        let nsRange = NSRange(
            location: location.range.start.utf16Offset,
            length: max(0, location.range.end.utf16Offset - location.range.start.utf16Offset)
        )
        if let url = location.url,
           url.standardizedFileURL.path != current.textView.documentURL?.standardizedFileURL.path {
            if let (pane, document) = paneAndDocument(matching: url) {
                document.selectedRange = nsRange
                workbench.activatePane(pane.id)
                pane.selectDocument(document.id)
                let destination = host(for: pane.id)
                showDocument(in: pane, host: destination)
                if destination.loadedDocumentID == document.id {
                    destination.textView.selectedRange = nsRange
                    destination.textView.scrollRangeToVisible(nsRange)
                    _ = destination.textView.focusTextInput()
                }
                return true
            }
            Task { await openDocument(from: url, selecting: nsRange) }
            return true
        }
        current.textView.selectedRange = nsRange
        current.textView.scrollRangeToVisible(nsRange)
        _ = current.textView.focusTextInput()
        return true
    }

    func presentNavigationChoices(_ locations: [Location]) {
        guard let paletteController else {
            if let first = locations.first {
                _ = openNavigationLocation(first)
            }
            return
        }
        let items = locations.map { location -> (title: String, subtitle: String?) in
            (location.displayName, location.url?.lastPathComponent)
        }
        paletteController.presentList(title: "Go to Definition", items: items) { [weak self] index in
            guard let self, locations.indices.contains(index) else { return }
            _ = self.openNavigationLocation(locations[index])
        }
    }

    private func paneAndDocument(matching url: URL) -> (EditorPane, WorkbenchDocument)? {
        let path = url.standardizedFileURL.path
        for pane in workbench.panes {
            if let document = pane.documents.first(where: { $0.url?.standardizedFileURL.path == path }) {
                return (pane, document)
            }
        }
        return nil
    }

    /// Text of an open document, including unsaved edits. Nil when `url` is not open, so navigation
    /// reads the file from disk instead of an empty file-backed model.
    func openBufferText(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let document = workbench.allDocuments().first(where: { $0.url?.standardizedFileURL.path == path }) else {
            return nil
        }
        let text = sourceText(for: document)
        return text.isEmpty ? nil : text
    }

    func openFindInFilesHit(_ hit: ProjectSearchResult) {
        let length = max(0, hit.range.end.utf16Offset - hit.range.start.utf16Offset)
        let range = NSRange(location: hit.range.start.utf16Offset, length: length)
        Task { await openDocument(from: hit.url, selecting: range) }
    }

    public func splitRight() {
        split(edge: .trailing)
    }

    public func splitDown() {
        split(edge: .bottom)
    }

    /// Pane-scoped variants for the tab context menu, so right-clicking a tab in a pane that
    /// isn't currently active still splits that pane rather than whichever one is.
    func splitRight(in paneID: UUID) {
        guard workbench.layout.findPane(id: paneID) != nil else { return }
        if paneID != workbench.activePaneID {
            activatePane(paneID)
        }
        splitRight()
    }

    func splitDown(in paneID: UUID) {
        guard workbench.layout.findPane(id: paneID) != nil else { return }
        if paneID != workbench.activePaneID {
            activatePane(paneID)
        }
        splitDown()
    }

    /// Splits the active pane, opening its currently selected document into the new pane too —
    /// two views on the same file, like Sublime Text/VS Code. The two panes reconcile on focus
    /// switch (`activatePane`'s outgoing sync + `showDocument`'s same-document refresh) rather
    /// than mirroring edits live.
    private func split(edge: EditorSplitEdge) {
        let sourcePane = workbench.activePane
        let sourceHost = host(for: sourcePane.id)
        let document = sourcePane.selectedDocument
        if let document {
            // Flush the active pane's current selection/scroll into the document so the new pane
            // starts at the same spot, not wherever it was last explicitly synced.
            syncTextViewToDocument(sourceHost.textView, document: document, from: sourceHost)
        }
        let newPane = workbench.splitActivePane(edge: edge)
        if let document {
            workbench.openDocument(document, in: newPane)
        }
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    public func closeActivePane() {
        closePane(workbench.activePaneID)
    }

    public func toggleSidebar() {
        isSidebarVisible.toggle()
        focusActiveEditor()
    }

    public func toggleGradleSidebar() {
        isGradleSidebarVisible.toggle()
        focusActiveEditor()
        saveSession()
    }

    /// Reveals a folder or file in the left Explorer, expanding ancestors as needed.
    func revealInExplorer(_ url: URL) {
        guard project.rootURL != nil else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        isSidebarVisible = true
        project.revealAndSelect(url: url, centered: false)
    }

    public func toggleMarkdownPreview() {
        adapter.textView?.perform(.toggleMarkdownPreview)
        isMarkdownPreviewVisible = hostCache.peek(workbench.activePaneID)?.markdownPreviewController.isVisible ?? false
        focusActiveEditor()
    }

    /// Exports the currently visible markdown preview to a PDF the user picks a location for.
    /// No-op when the preview isn't shown (there's nothing rendered to export yet).
    public func exportMarkdownPreviewToPDF() {
        guard let host = hostCache.peek(workbench.activePaneID),
              let data = host.markdownPreviewController.exportPDFData(),
              let document = workbench.activePane.selectedDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (document.displayName as NSString).deletingPathExtension

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    func toggleMinimap() {
        preferences.showMinimap.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    func toggleLineNumbers() {
        preferences.showLineNumbers.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    func toggleFolding() {
        preferences.isLineFoldingEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    func toggleWordWrap() {
        preferences.wrapLines.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    public func toggleTypewriterScrolling() {
        preferences.isTypewriterScrollingEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    public func toggleDistractionFreeMode() {
        preferences.isDistractionFreeModeEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    public func toggleFocusMode() {
        preferences.isFocusModeEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    func toggleMetalRendering() {
        preferences.isMetalRenderingEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
    }

    public var showLineNumbersBinding: Binding<Bool> {
        preferenceBinding(\.showLineNumbers)
    }

    public var isLineFoldingEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isLineFoldingEnabled)
    }

    public var wrapLinesBinding: Binding<Bool> {
        preferenceBinding(\.wrapLines)
    }

    public var showMinimapBinding: Binding<Bool> {
        preferenceBinding(\.showMinimap)
    }

    public var showScrollbarsBinding: Binding<Bool> {
        preferenceBinding(\.showScrollbars)
    }

    public var isMetalRenderingEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isMetalRenderingEnabled)
    }

    public var isTypewriterScrollingEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isTypewriterScrollingEnabled)
    }

    public var isDistractionFreeModeEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isDistractionFreeModeEnabled)
    }

    public var isFocusModeEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isFocusModeEnabled)
    }

    private func preferenceBinding(_ keyPath: ReferenceWritableKeyPath<IDEPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { newValue in
                self.preferences[keyPath: keyPath] = newValue
                self.applyPreferencesToAllHosts()
                self.focusActiveEditor()
            }
        )
    }

    func applyPreferencesToAllHosts() {
        for pane in workbench.panes {
            preferences.apply(to: host(for: pane.id).textView)
        }
        if let textView = adapter?.textView {
            updateStatus(from: textView)
        }
    }

    func openDroppedURLs(_ urls: [URL]) {
        Task {
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    continue
                }
                if isDirectory.boolValue {
                    _ = url.startAccessingSecurityScopedResource()
                    isSidebarVisible = true
                    applyProjectRoot(url)
                    refreshPresentation()
                    saveSession()
                } else {
                    await openDocument(from: url)
                }
            }
        }
    }

    func selectTab(_ id: UUID, in paneID: UUID? = nil) {
        let pane: EditorPane
        if let paneID, let found = workbench.layout.findPane(id: paneID) {
            pane = found
        } else {
            pane = workbench.activePane
        }
        if pane.id != workbench.activePaneID {
            workbench.activatePane(pane.id)
        }
        guard pane.selectedDocumentID != id else {
            activatePane(pane.id)
            focusActiveEditor()
            return
        }
        pane.selectDocument(id)
        let host = host(for: pane.id)
        showDocument(in: pane, host: host)
        refreshPresentation()
        activatePane(pane.id)
        focusActiveEditor()
        Task { await workspaceBridge.syncPane(pane) }
    }

    func closeTab(_ id: UUID, in paneID: UUID? = nil) {
        let pane: EditorPane
        if let paneID, let found = workbench.layout.findPane(id: paneID) {
            pane = found
        } else {
            pane = workbench.activePane
        }
        closeDocument(id, in: pane)
    }

    /// Closes every tab in `paneID` except `id`.
    func closeOtherTabs(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID) else { return }
        for document in pane.documents where document.id != id {
            closeDocument(document.id, in: pane)
        }
    }

    /// Closes every tab to the right of `id` within `paneID`, tab-order matching `pane.documents`.
    func closeTabsToRight(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID),
              let index = pane.documents.firstIndex(where: { $0.id == id }) else { return }
        for document in pane.documents[(index + 1)...] {
            closeDocument(document.id, in: pane)
        }
    }

    /// Closes every tab in `paneID`, which in turn closes the pane itself once it's empty.
    func closeAllTabs(in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID) else { return }
        for document in pane.documents {
            closeDocument(document.id, in: pane)
        }
    }

    /// Collapses the split layout back to a single pane by closing every pane except `paneID`.
    func unsplit(from paneID: UUID) {
        let otherPaneIDs = workbench.panes.map(\.id).filter { $0 != paneID }
        guard !otherPaneIDs.isEmpty else { return }
        for otherPaneID in otherPaneIDs {
            workbench.closePane(otherPaneID)
            hostCache.remove(otherPaneID)
            hostedPaneIDs.remove(otherPaneID)
        }
        workbench.activatePane(paneID)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        showsWelcome = !hasOpenDocuments
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    /// Renames the tab's underlying file on disk (or, for an unsaved document, just its
    /// in-memory display name) via a simple name-prompt alert.
    func renameTab(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID),
              let document = pane.documents.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: document.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != document.displayName else { return }

        if let currentURL = document.url {
            let destination = currentURL.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: currentURL, to: destination)
            } catch {
                presentError(error)
                return
            }
            document.url = destination
        }
        document.displayName = newName
        refreshPresentation()
    }

    func makeSession(
        sidebarWidth: Double,
        gradleSidebarWidth: Double? = nil,
        terminalHeight: Double? = nil
    ) -> AppSession {
        AppSession(
            restoration: hasOpenDocuments ? workbench.makeRestorationState() : nil,
            projectRootBookmark: project.makeBookmarkData(),
            recentFiles: recentFiles,
            recentProjects: recentProjects,
            preferences: preferences.snapshot(),
            sidebarWidth: sidebarWidth,
            isSidebarVisible: isSidebarVisible,
            gradleSidebarWidth: gradleSidebarWidth ?? self.gradleSidebarWidth,
            isGradleSidebarVisible: isGradleSidebarVisible,
            isTerminalVisible: isTerminalVisible,
            terminalHeight: terminalHeight ?? self.terminalHeight,
            terminalTabs: terminalTabs.isEmpty ? nil : terminalTabs,
            selectedTerminalTabID: selectedTerminalTabID
        )
    }

    func saveSession(
        sidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        gradleSidebarWidth: Double? = nil,
        terminalHeight: Double? = nil
    ) {
        IDESessionStore.save(makeSession(
            sidebarWidth: sidebarWidth,
            gradleSidebarWidth: gradleSidebarWidth,
            terminalHeight: terminalHeight
        ))
    }

    // MARK: - Private

    private func defaultTerminalDirectory() -> URL {
        project.rootURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func makeTerminalTab(cwd: URL? = nil) -> IDETerminalTab {
        let directory = cwd ?? defaultTerminalDirectory()
        return IDETerminalTab(
            id: UUID(),
            title: IDETerminalTab.defaultTitle(for: directory),
            workingDirectory: directory
        )
    }

    private func loadSession() {
        let session = IDESessionStore.load()
        preferences.restore(from: session.preferences)
        recentFiles = session.recentFiles
        recentProjects = session.recentProjects
        isSidebarVisible = session.isSidebarVisible
        gradleSidebarWidth = session.gradleSidebarWidth
        isGradleSidebarVisible = session.isGradleSidebarVisible
        isTerminalVisible = session.isTerminalVisible
        terminalHeight = session.terminalHeight
        terminalTabs = session.terminalTabs ?? []
        selectedTerminalTabID = session.selectedTerminalTabID
        if let selectedID = selectedTerminalTabID,
           !terminalTabs.contains(where: { $0.id == selectedID }) {
            selectedTerminalTabID = terminalTabs.first?.id
        }
        if isTerminalVisible && terminalTabs.isEmpty {
            addTerminalTab(saveSession: false)
        }
        // Same path as Open Folder, so a restored Gradle project syncs instead of only rebuilding
        // the sidebar. `restoreRoot` alone never reached `javaSupport.setProjectRoot`.
        applyProjectRoot(project.rootURL(from: session.projectRootBookmark))

        if let restoration = session.restoration {
            workbench.restore(from: restoration, languageResolver: IDELanguageSupport.languageResolver)
            Task {
                try? await workbench.reloadFileBackedDocuments(languageResolver: IDELanguageSupport.fileBackedLanguageResolver)
                rebuildLayoutHosts()
                refreshPresentation()
                showsWelcome = !hasOpenDocuments
            }
        }
    }

    private func wireAdapter() {
        adapter = PenumbraWorkbenchEditorAdapter(workbench: workbench)
        adapter.forwardingDelegate = self
        adapter.onOpenHistoryEntry = { [weak self] entry in
            self?.openHistoryEntry(entry) ?? false
        }
    }

    private func makeHost(paneID: UUID) -> IDEEditorPaneHost {
        let pane = workbench.layout.findPane(id: paneID) ?? EditorPane(id: paneID)
        let host = IDEEditorPaneHost(pane: pane, preferences: preferences)
        host.textView.onMetalRenderingFailure = { [weak self] reason in
            self?.statusRenderer = "Core Graphics (Metal unavailable)"
            NSLog("Umbra: Metal disabled: %@", reason)
            self?.presentMetalFailureOnce(reason: reason)
        }
        host.onActivated = { [weak self] in
            self?.activatePane(paneID)
        }
        host.intelligenceController = intelligenceServices.makeController(
            textView: host.textView,
            adapter: adapter,
            workspace: workspaceBridge.workspace
        )
        host.intelligenceController?.onOpenLocationInOtherDocument = { [weak self] location in
            self?.openNavigationLocation(location) ?? false
        }
        host.intelligenceController?.onPresentNavigationChoices = { [weak self] locations in
            self?.presentNavigationChoices(locations)
        }
        host.wireMarkdownPreview()
        host.wireHTTPActions(sendRequest: { [weak self] in
            self?.sendActiveHTTPRequest()
        })
        // Find in Files (⌘⇧F) gets Umbra's own bottom panel rather than the built-in palette
        // mode; Go to Line needs no host wiring at all — `CommandPaletteController` handles
        // `.goToLine` natively.
        host.intelligenceController?.onRequestProjectSearch = { [weak self] in
            self?.showFindInFiles()
            return true
        }
        host.intelligenceController?.onBreadcrumbsUpdated = { [weak self] segments in
            self?.applySymbolBreadcrumbs(segments)
        }
        _ = sharedPalette(for: host)
        preferences.apply(to: host.textView)
        return host
    }

    /// Installs the Spotlight-style palette overlay on a window-level host view. Clicks pass
    /// through that host while the palette is hidden.
    func attachPaletteOverlay(to container: NSView) {
        paletteOverlayContainer = container
        paletteController?.installOverlay(in: container)
    }

    /// One palette for the window: created against the first pane, then retargeted as panes
    /// activate so go-to-line / in-buffer search / Find Action run on the focused editor.
    private func sharedPalette(for host: IDEEditorPaneHost) -> CommandPaletteController {
        if let existing = paletteController {
            existing.attach(to: host.textView)
            existing.bindActions(to: host.textView)
            existing.workspaceRoot = project.rootURL
            return existing
        }
        let controller = CommandPaletteController(
            textView: host.textView,
            overlayContainer: paletteOverlayContainer,
            bindActions: true
        )
        configurePalette(controller)
        paletteController = controller
        return controller
    }

    /// Loads `url` as an image or text document, not yet attached to any pane.
    private func loadDocument(from url: URL) async throws -> WorkbenchDocument {
        if ImageContentDetector.isImageFile(url) {
            return WorkbenchDocument.loadImage(from: url)
        }
        let identifier = LanguageIdentifier.identifier(for: url)
        let language = IDELanguageSupport.language(forIdentifier: identifier)
        let document = try await WorkbenchDocument.load(
            contentsOf: url,
            theme: IDEEditorTheme.shared.current,
            language: language,
            languageIdentifier: identifier,
            languageProvider: Self.languageProvider
        )
        document.language = language
        return document
    }

    /// Makes the pane to the right of the active one active, splitting the active pane first when
    /// it is the last (or only) pane — "Open In Right Split".
    private func activatePaneToTheRight() {
        let panes = workbench.layout.flattenedPanes()
        if let current = panes.firstIndex(where: { $0.id == workbench.activePaneID }), current + 1 < panes.count {
            workbench.activatePane(panes[current + 1].id)
            return
        }
        // Flush the pane we're leaving so it keeps its caret and scroll position after the rebuild.
        let sourcePane = workbench.activePane
        if let document = sourcePane.selectedDocument {
            syncTextViewToDocument(host(for: sourcePane.id).textView, document: document, from: host(for: sourcePane.id))
        }
        _ = workbench.splitActivePane(edge: .trailing)
    }

    func openDocument(from url: URL, selecting range: NSRange? = nil, inRightSplit: Bool = false) async {
        do {
            let document = try await loadDocument(from: url)
            if inRightSplit {
                activatePaneToTheRight()
            }
            workbench.openDocument(document)
            if let range, document.contentKind == .text, let selected = workbench.activePane.selectedDocument {
                selected.selectedRange = range
            }
            recordRecentFile(url)
            showsWelcome = false
            rebuildLayoutHosts()
            activatePane(workbench.activePaneID)
            if let range, document.contentKind == .text {
                let host = host(for: workbench.activePaneID)
                if host.loadedDocumentID == workbench.activePane.selectedDocumentID {
                    host.textView.selectedRange = range
                    host.textView.scrollRangeToVisible(range)
                    _ = host.textView.focusTextInput()
                }
            }
            if document.contentKind == .text {
                await workspaceBridge.syncWorkbench(workbench)
            }
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    /// Opens a class's file with its name selected. The index reports the name as UTF-8 byte
    /// offsets; the editor selects in UTF-16, so convert against the file's own text.
    private func openClassDeclaration(in url: URL, utf8NameRange: Range<Int>, inRightSplit: Bool) {
        Task {
            let range = await Task.detached { Self.utf16Range(fromUTF8: utf8NameRange, in: url) }.value
            await openDocument(from: url, selecting: range, inRightSplit: inRightSplit)
        }
    }

    nonisolated private static func utf16Range(fromUTF8 range: Range<Int>, in url: URL) -> NSRange? {
        guard let data = try? Data(contentsOf: url), range.upperBound <= data.count else { return nil }
        let location = String(decoding: data.prefix(range.lowerBound), as: UTF8.self).utf16.count
        let length = String(decoding: data[range], as: UTF8.self).utf16.count
        return NSRange(location: location, length: length)
    }

    private func recordRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 15 {
            recentFiles = Array(recentFiles.prefix(15))
        }
    }

    private func recordRecentProject(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentProjects.removeAll { $0.standardizedFileURL == standardized }
        recentProjects.insert(standardized, at: 0)
        if recentProjects.count > 15 {
            recentProjects = Array(recentProjects.prefix(15))
        }
    }

    private func openHistoryEntry(_ entry: NavigationEntry) -> Bool {
        guard let documentID = entry.documentID,
              let pane = workbench.panes.first(where: { $0.documents.contains { $0.id == documentID } }) else {
            return false
        }
        let host = host(for: pane.id)
        workbench.activatePane(pane.id)
        pane.selectDocument(documentID)
        showDocument(in: pane, host: host)
        refreshPresentation()
        guard pane.selectedDocument?.contentKind != .image else {
            host.imageViewerController.focusForInteraction()
            return true
        }
        if let location = host.textView.location(at: entry.location) {
            host.textView.selectedRange = NSRange(location: location, length: 0)
            host.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
        _ = host.textView.focusTextInput()
        return true
    }

    private func closeDocument(_ documentID: UUID, in pane: EditorPane) {
        pane.closeDocument(documentID)
        if pane.documents.isEmpty {
            closePane(pane.id)
            showsWelcome = !hasOpenDocuments
            return
        }
        let host = host(for: pane.id)
        showDocument(in: pane, host: host)
        refreshPresentation()
        focusActiveEditor()
        Task { await workspaceBridge.syncPane(pane) }
    }

    private func closePane(_ paneID: UUID) {
        workbench.closePane(paneID)
        hostCache.remove(paneID)
        hostedPaneIDs.remove(paneID)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        showsWelcome = !hasOpenDocuments
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    private func rebuildLayoutHosts() {
        let panes = workbench.layout.flattenedPanes()
        let live = Set(panes.map(\.id))
        for id in hostedPaneIDs.subtracting(live) {
            hostCache.remove(id)
        }
        hostedPaneIDs = live
        for pane in panes {
            let host = host(for: pane.id)
            if pane.selectedDocument != nil {
                showDocument(in: pane, host: host)
            }
        }
        layoutEpoch += 1
        refreshPresentation()
    }

    private func configurePalette(_ palette: CommandPaletteController) {
        palette.recentFileEntriesProvider = { [weak self] in
            guard let self else { return [] }
            return self.recentFiles.map { PaletteFileEntry(url: $0, displayName: $0.lastPathComponent) }
        }
        palette.fileIndex = fileIndexer.index
        fileIndexer.onIndexChanged = { [weak palette] index in
            palette?.fileIndex = index
        }
        palette.fileBoostsProvider = { [weak self] in
            guard let self else { return [] }
            var seen = Set<URL>()
            let open = self.workbench.recentDocuments(limit: 30).compactMap(\.url)
            return (open + self.recentFiles).filter { seen.insert($0).inserted }
        }
        palette.projectSearchEngine = ProjectSearchEngine()
        // ⌘⇧F keeps Umbra's own Find in Files panel; the palette's Text tab stays a tab.
        palette.handlesFindInFilesAction = false
        palette.onOpenProjectSearchResult = { [weak self] result in
            self?.openFindInFilesHit(result)
        }
        palette.onOpenFileInSplit = { [weak self] url in
            guard let self else { return }
            Task { await self.openDocument(from: url, inRightSplit: true) }
        }
        palette.classesProvider = IDEJavaClassesPaletteProvider(
            javaIndex: intelligenceServices.javaSupport.javaIndex,
            fileIndex: { [weak self] in self?.fileIndexer.index },
            onOpen: { [weak self] url, nameRange, inSplit in
                self?.openClassDeclaration(in: url, utf8NameRange: nameRange, inRightSplit: inSplit)
            }
        )
        palette.symbolIndex = intelligenceServices.symbolIndex
        palette.workspaceRoot = project.rootURL
        palette.onOpenFile = { [weak self] url in
            guard let self else { return }
            Task { await self.openDocument(from: url) }
        }
        palette.onSelectSymbol = { [weak self] symbol in
            guard let self else { return }
            let location = Location(
                documentID: symbol.documentID,
                range: symbol.range,
                displayName: symbol.name
            )
            _ = IDEIntelligenceServices.openLocation(location, adapter: self.adapter)
        }
        palette.commandRegistry.register([
            EditorCommand(id: "app.splitRight", title: "Split Editor Right", group: "View",
                          action: { [weak self] in self?.splitRight() }),
            EditorCommand(id: "app.splitDown", title: "Split Editor Down", group: "View",
                          action: { [weak self] in self?.splitDown() }),
            EditorCommand(id: "app.toggleSidebar", title: "Toggle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleSidebar() }),
            EditorCommand(id: "app.toggleGradleSidebar", title: "Toggle Gradle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleGradleSidebar() }),
            EditorCommand(id: "app.revealActiveFile", title: "Reveal Active File in Explorer", group: "View",
                          action: { [weak self] in self?.revealActiveFileInExplorer() }),
            EditorCommand(id: "app.toggleMinimap", title: "Toggle Minimap", group: "View",
                          action: { [weak self] in self?.toggleMinimap() }),
            EditorCommand(id: "app.toggleLineNumbers", title: "Toggle Line Numbers", group: "View",
                          action: { [weak self] in self?.toggleLineNumbers() }),
            EditorCommand(id: "app.toggleFolding", title: "Toggle Code Folding", group: "View",
                          action: { [weak self] in self?.toggleFolding() }),
            EditorCommand(id: "app.toggleWrap", title: "Toggle Word Wrap", group: "View",
                          action: { [weak self] in self?.toggleWordWrap() }),
            EditorCommand(id: "app.toggleTypewriter", title: "Toggle Typewriter Scrolling", group: "View",
                          action: { [weak self] in self?.toggleTypewriterScrolling() }),
            EditorCommand(id: "app.toggleDistractionFree", title: "Toggle Distraction Free", group: "View",
                          action: { [weak self] in self?.toggleDistractionFreeMode() }),
            EditorCommand(id: "app.toggleFocusMode", title: "Toggle Focus Mode", group: "View",
                          action: { [weak self] in self?.toggleFocusMode() }),
            EditorCommand(id: "app.toggleMetalRendering", title: "Use Metal Renderer", group: "View",
                          action: { [weak self] in self?.toggleMetalRendering() }),
            EditorCommand(id: "app.toggleTerminal", title: "Toggle Terminal", group: "View",
                          action: { [weak self] in self?.toggleTerminal() }),
            EditorCommand(id: "app.toggleSourceControl", title: "Toggle Source Control", group: "View",
                          action: { [weak self] in self?.toggleSourceControl() }),
            EditorCommand(id: "app.newTerminalTab", title: "New Terminal Tab", group: "View",
                          action: { [weak self] in self?.addTerminalTab() }),
            EditorCommand(id: "app.closeTerminalTab", title: "Close Terminal Tab", group: "View",
                          action: { [weak self] in
                              guard let self, let id = self.selectedTerminalTabID else { return }
                              self.closeTerminalTab(id)
                          }),
            EditorCommand(id: "app.nextTerminalTab", title: "Next Terminal Tab", group: "View",
                          action: { [weak self] in self?.selectNextTerminalTab() }),
            EditorCommand(id: "app.previousTerminalTab", title: "Previous Terminal Tab", group: "View",
                          action: { [weak self] in self?.selectPreviousTerminalTab() }),
            EditorCommand(id: "app.java.buildGradleProject", title: "Java: Build Project", group: "Java",
                          action: { [weak self] in self?.buildGradleProject() }),
            EditorCommand(id: "app.java.reloadGradleProject", title: "Java: Reload Gradle Project", group: "Java",
                          action: { [weak self] in self?.reloadGradleProject() }),
            EditorCommand(id: "app.java.showGradleOutput", title: "Java: Show Gradle Output", group: "Java",
                          action: { [weak self] in self?.showGradleOutput() }),
            EditorCommand(id: "app.http.sendRequest", title: "HTTP: Send Request", group: "HTTP",
                          action: { [weak self] in self?.sendActiveHTTPRequest() }),
            EditorCommand(id: "app.http.showResponse", title: "HTTP: Show Response", group: "HTTP",
                          action: { [weak self] in self?.showHTTPResponse() })
        ])
    }

    func reloadGradleProject() {
        javaSupport.reloadGradleProject()
    }

    func showGradleOutput() {
        selectGradleConsoleTab()
    }

    func dismissGradleReloadBanner() {
        javaSupport.dismissGradleBuildFileChanges()
    }

    private func applyProjectRoot(_ url: URL?) {
        project.setRoot(url)
        gitStatus.setRoot(url)
        fileIndexer.setRoot(url)
        projectWatcher.onBatch = [{ [weak self] batch in
            guard let self else { return }
            self.project.applyChanges(in: batch.affectedDirectories)
            self.gitStatus.refresh()
            self.fileIndexer.handle(batch)
        }]
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            recordRecentProject(url)
            projectWatcher.start(root: url)
        } else {
            projectWatcher.stop()
        }
        syncTerminalWorkingDirectory()
        intelligenceServices.javaSupport.setProjectRoot(url)
        paletteController?.workspaceRoot = url
    }

    private func activatePane(_ paneID: UUID) {
        let host = host(for: paneID)
        let alreadyActive = workbench.activePaneID == paneID && adapter.textView === host.textView
        let sameDocument = host.loadedDocumentID == workbench.activePane.selectedDocumentID
        if alreadyActive && sameDocument {
            return
        }
        // Sync whichever pane is currently wired up (identified by `adapter.textView`, not
        // `workbench.activePaneID` — a caller such as `split(edge:)` may have already moved that
        // forward) into its document before switching away, so a second pane on the same document
        // picks up these edits instead of showing stale content.
        if let outgoingTextView = adapter.textView, outgoingTextView !== host.textView,
           let outgoingPane = workbench.panes.first(where: { hostCache.peek($0.id)?.textView === outgoingTextView }),
           let outgoingHost = hostCache.peek(outgoingPane.id),
           let outgoingDocument = outgoingPane.selectedDocument {
            syncTextViewToDocument(outgoingTextView, document: outgoingDocument, from: outgoingHost)
        }
        workbench.activatePane(paneID)
        activePaneID = workbench.activePaneID
        adapter.textView = host.textView
        host.textView.editorDelegate = adapter
        paletteController?.attach(to: host.textView)
        paletteController?.workspaceRoot = project.rootURL
        showDocument(in: workbench.activePane, host: host)
        adapter.refreshCachedDocuments()
        host.intelligenceController?.refreshDiagnostics()
        host.intelligenceController?.refreshBreadcrumbs()
        updateStatus(from: host.textView)
        refreshPresentation()
        Task { await workspaceBridge.syncPane(workbench.activePane) }
    }

    private func refreshPresentation() {
        activePaneID = workbench.activePaneID
        var tabs: [UUID: [IDETabRow]] = [:]
        for pane in workbench.panes {
            tabs[pane.id] = pane.documents.map { document in
                IDETabRow(
                    id: document.id,
                    title: document.displayName,
                    isDirty: document.isDirty,
                    isSelected: document.id == pane.selectedDocumentID
                )
            }
        }
        tabsByPane = tabs
        let openPaths = Set(workbench.panes.flatMap(\.documents).compactMap { $0.url?.standardizedFileURL.path })
        if openPaths != openDocumentPaths { openDocumentPaths = openPaths }
        autoRevealActiveDocumentIfNeeded()
        isMarkdownPreviewVisible = hostCache.peek(workbench.activePaneID)?.markdownPreviewController.isVisible ?? false
        if let document = workbench.activePane.selectedDocument {
            windowTitle = "\(document.displayName) · Umbra"
            let pathItems = pathBreadcrumbItems(for: document)
            let symbolItems = headerContext.documentID == document.id ? headerContext.symbolItems : []
            let newContext = IDEHeaderContext(
                documentID: document.id,
                pathItems: pathItems,
                symbolItems: symbolItems,
                isDirty: document.isDirty
            )
            if headerContext != newContext {
                headerContext = newContext
            }
        } else {
            windowTitle = "Umbra"
            if headerContext != IDEHeaderContext() {
                headerContext = IDEHeaderContext()
            }
        }
    }

    func selectBreadcrumb(_ item: IDEBreadcrumbItem) {
        switch item.target {
        case .folder(let url):
            revealInSidebar(url)
        case .symbol(let range):
            jumpToSymbol(range)
        }
    }

    private func applySymbolBreadcrumbs(_ segments: [BreadcrumbSegment]) {
        let items = segments.map { segment in
            IDEBreadcrumbItem(
                id: "symbol:\(segment.range.start.utf16Offset)-\(segment.range.end.utf16Offset):\(segment.title)",
                title: segment.title,
                target: .symbol(segment.range)
            )
        }
        guard headerContext.symbolItems != items else { return }
        headerContext.symbolItems = items
    }

    // MARK: - Explorer file operations

    private var fileOperations: IDEFileOperations? {
        project.rootURL.map(IDEFileOperations.init(rootURL:))
    }

    /// Where Explorer create commands should land: the selected folder, the parent of a selected
    /// file, or the project root when nothing is selected.
    func explorerCreationDirectory() -> URL? {
        guard let rootURL = project.rootURL else { return nil }
        if let selected = project.selectedPath, let node = project.node(at: selected) {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        return rootURL
    }

    /// Creates a new file in the Explorer and starts inline rename. Shows the sidebar when hidden.
    func createExplorerFile(in directory: URL? = nil) {
        guard let directory = directory ?? explorerCreationDirectory() else { return }
        isSidebarVisible = true
        createExplorerItem(in: directory, isDirectory: false)
    }

    /// Creates a new folder in the Explorer and starts inline rename. Shows the sidebar when hidden.
    func createExplorerFolder(in directory: URL? = nil) {
        guard let directory = directory ?? explorerCreationDirectory() else { return }
        isSidebarVisible = true
        createExplorerItem(in: directory, isDirectory: true)
    }

    /// Creates an empty file or folder named `untitled…` in `directory` and opens the inline rename
    /// field on its row. Cancelling that rename removes the placeholder again.
    func createExplorerItem(in directory: URL, isDirectory: Bool) {
        guard let operations = fileOperations else { return }
        cancelExplorerRename()
        do {
            let name = operations.uniqueName(base: isDirectory ? "untitled folder" : "untitled", in: directory)
            let url = isDirectory
                ? try operations.createDirectory(in: directory, name: name)
                : try operations.createFile(in: directory, name: name)
            project.reveal(url: directory)
            Task {
                await project.refresh(directories: [directory.path])
                project.pendingCreationPath = url.path
                project.renamingPath = url.path
                project.revealAndSelect(url: url, centered: false)
                gitStatus.refresh()
            }
        } catch {
            presentError(error)
        }
    }

    func beginExplorerRename(_ url: URL) {
        guard let root = project.rootURL, url.standardizedFileURL.path != root.standardizedFileURL.path else { return }
        cancelExplorerRename()
        project.selectedPath = url.path
        project.renamingPath = url.path
    }

    /// Applies the inline rename. For a fresh placeholder this names it (and opens files); an
    /// empty or unchanged name on a placeholder keeps its default name only when non-empty.
    func commitExplorerRename(of url: URL, to newName: String) {
        guard let operations = fileOperations else { return }
        let isPlaceholder = project.pendingCreationPath == url.path
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        project.renamingPath = nil
        project.pendingCreationPath = nil
        if trimmed.isEmpty {
            if isPlaceholder { discardPlaceholder(url) }
            return
        }
        var result = url
        if trimmed != url.lastPathComponent {
            do {
                result = try operations.rename(url, to: trimmed)
            } catch {
                presentError(error)
                if isPlaceholder { discardPlaceholder(url) }
                return
            }
            retargetOpenDocuments(from: url, to: result)
            project.didMove(from: url.path, to: result.path)
            recentFiles = recentFiles.map { retargeted($0, from: url, to: result) }
        }
        let parent = url.deletingLastPathComponent().path
        Task {
            await project.refresh(directories: [parent])
            project.revealAndSelect(url: result, centered: false)
            gitStatus.refresh()
            refreshPresentation()
            if isPlaceholder {
                let isDirectory = (try? result.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isDirectory { await openDocument(from: result) }
            }
        }
    }

    func cancelExplorerRename() {
        guard let path = project.renamingPath else { return }
        let placeholder = project.pendingCreationPath == path
        project.renamingPath = nil
        project.pendingCreationPath = nil
        if placeholder { discardPlaceholder(URL(fileURLWithPath: path)) }
    }

    func duplicateExplorerItem(_ url: URL) {
        guard let operations = fileOperations else { return }
        do {
            let copy = try operations.duplicate(url)
            Task {
                await project.refresh(directories: [url.deletingLastPathComponent().path])
                project.revealAndSelect(url: copy, centered: false)
                gitStatus.refresh()
            }
        } catch {
            presentError(error)
        }
    }

    /// Always asks first. Open editors on the item (or inside a trashed folder) are closed.
    func trashExplorerItem(_ url: URL) {
        guard let operations = fileOperations else { return }
        let affected = openDocuments(at: url)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        var details = "You can restore it from the Trash in Finder."
        let dirty = affected.filter { $0.document.isDirty }.count
        if dirty > 0 {
            details += " \(dirty) open editor\(dirty == 1 ? " has" : "s have") unsaved changes that will be lost."
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try operations.trash(url)
        } catch {
            presentError(error)
            return
        }
        for (pane, document) in affected { closeDocument(document.id, in: pane) }
        if project.selectedPath == url.path { project.selectedPath = nil }
        project.removeExpanded(under: url.path)
        Task {
            await project.refresh(directories: [url.deletingLastPathComponent().path])
            gitStatus.refresh()
        }
    }

    func copyExplorerPath(_ url: URL, relative: Bool) {
        let value = relative ? (fileOperations?.relativePath(of: url) ?? url.path) : url.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func discardPlaceholder(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Task {
            await project.refresh(directories: [url.deletingLastPathComponent().path])
            gitStatus.refresh()
        }
    }

    private func openDocuments(at url: URL) -> [(pane: EditorPane, document: WorkbenchDocument)] {
        let path = url.standardizedFileURL.path
        return workbench.panes.flatMap { pane in
            pane.documents.compactMap { document -> (EditorPane, WorkbenchDocument)? in
                guard let documentPath = document.url?.standardizedFileURL.path else { return nil }
                return documentPath == path || documentPath.hasPrefix(path + "/") ? (pane, document) : nil
            }
        }
    }

    private func retargeted(_ url: URL, from old: URL, to new: URL) -> URL {
        let path = url.standardizedFileURL.path
        let oldPath = old.standardizedFileURL.path
        if path == oldPath { return new }
        if path.hasPrefix(oldPath + "/") {
            return URL(fileURLWithPath: new.standardizedFileURL.path + path.dropFirst(oldPath.count))
        }
        return url
    }

    /// Points open tabs at the renamed file (or at files inside a renamed folder). Buffers,
    /// including unsaved edits, are kept.
    private func retargetOpenDocuments(from old: URL, to new: URL) {
        for (_, document) in openDocuments(at: old) {
            guard let current = document.url else { continue }
            let updated = retargeted(current, from: old, to: new)
            document.url = updated
            if current.standardizedFileURL.path == old.standardizedFileURL.path {
                document.displayName = updated.lastPathComponent
            }
        }
        refreshPresentation()
        for pane in workbench.panes {
            Task { await workspaceBridge.syncPane(pane) }
        }
    }

    /// Explorer's "Reveal Active File": shows the sidebar, expands to the active tab's file, and
    /// scrolls it to the center.
    func revealActiveFileInExplorer() {
        guard let url = workbench.activePane.selectedDocument?.url else { return }
        guard project.rootURL != nil else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        isSidebarVisible = true
        project.revealAndSelect(url: url, centered: true)
    }

    private func autoRevealActiveDocumentIfNeeded() {
        let document = workbench.activePane.selectedDocument
        guard document?.id != lastAutoRevealedDocumentID else { return }
        lastAutoRevealedDocumentID = document?.id
        guard IDEPreferences.shared.explorerAutoReveal, project.renamingPath == nil,
              let url = document?.url, project.rootURL != nil else { return }
        project.revealAndSelect(url: url, centered: false)
    }

    private func revealInSidebar(_ url: URL) {
        if project.rootURL != nil {
            isSidebarVisible = true
            project.reveal(url: url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func jumpToSymbol(_ range: EditorIntelligence.TextRange) {
        let textView = host(for: workbench.activePaneID).textView
        textView.recordNavigationCheckpoint()
        let nsRange = TextEditApplicator.nsRange(for: range, in: textView)
        textView.selectedRanges = [nsRange]
        textView.scrollRangeToVisible(nsRange)
        _ = textView.focusTextInput()
    }

    /// Folder crumbs leading to the active file, excluding the filename (the tab already shows
    /// that). Project-relative when a folder is open; otherwise the last few parent directories.
    private func pathBreadcrumbItems(for document: WorkbenchDocument) -> [IDEBreadcrumbItem] {
        guard let url = document.url else { return [] }
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        if let rootURL = project.rootURL {
            let root = rootURL.standardizedFileURL
            let directoryPath = directory.path
            let rootPath = root.path
            guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
                return ancestorFolderItems(from: directory)
            }
            var items = [folderItem(root)]
            var current = root
            let relative = directoryPath.dropFirst(rootPath.count)
            for component in relative.split(separator: "/") where !component.isEmpty {
                current.appendPathComponent(String(component))
                items.append(folderItem(current))
            }
            return items
        }
        return ancestorFolderItems(from: directory)
    }

    private func ancestorFolderItems(from directory: URL, limit: Int = 3) -> [IDEBreadcrumbItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var folders: [URL] = []
        var current = directory.standardizedFileURL
        while folders.count < limit {
            let path = current.path
            if path == "/" || path == home || path.isEmpty { break }
            folders.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == path { break }
            current = parent
        }
        return folders.reversed().map(folderItem)
    }

    private func folderItem(_ url: URL) -> IDEBreadcrumbItem {
        IDEBreadcrumbItem(id: "folder:\(url.path)", title: url.lastPathComponent, target: .folder(url))
    }

    private func applyLaunchConfiguration() {
        let arguments = CommandLine.arguments
        if arguments.contains("--no-metal") {
            preferences.isMetalRenderingEnabled = false
        } else if arguments.contains("--metal") {
            preferences.isMetalRenderingEnabled = true
        }
    }

    private func updateStatus(from textView: TextView) {
        if workbench.activePane.selectedDocument?.contentKind == .image {
            statusLine = 1
            statusColumn = 1
            statusLanguage = "Image"
            statusSelectionLength = 0
            statusRenderer = ""
            javaFileCanRun = false
            javaRunFileURL = nil
            return
        }
        let range = textView.selectedRange
        if let textLocation = textView.textLocation(at: range.location) {
            statusLine = textLocation.lineNumber + 1
            statusColumn = textLocation.column + 1
        } else {
            statusLine = 1
            statusColumn = 1
        }
        statusLanguage = workbench.activePane.selectedDocument?.languageIdentifier ?? ""
        statusSelectionLength = range.length
        statusRenderer = textView.isMetalRenderingActive ? "Metal" : "Core Graphics"
        refreshJavaRunAvailability(from: textView)
        refreshHTTPSendAvailability(from: textView)
    }

    private func refreshHTTPSendAvailability(from textView: TextView) {
        let document = workbench.activePane.selectedDocument
        guard document?.languageIdentifier == "http" else {
            httpFileCanSend = false
            return
        }
        httpFileCanSend = HTTPRequestParser.canParseRequest(
            in: textView.text,
            caretUTF16Offset: textView.selectedRange.location,
            fileURL: document?.url
        )
    }

    private func refreshJavaRunAvailability(from textView: TextView) {
        let document = workbench.activePane.selectedDocument
        let isJava = document?.languageIdentifier == "java"
        let hasMain = isJava && JavaMainMethod.containsMain(in: textView.text)
        let fileURL = document?.url
        let canPlainRun = fileURL?.pathExtension.lowercased() == "java"
        let canGradleRun = javaSupport.isGradleProject && project.rootURL != nil
        javaFileCanRun = hasMain && (canPlainRun || canGradleRun)
        javaRunFileURL = fileURL
    }

    /// Writes `textView`'s live content back into `document` and bumps `document.contentGeneration`
    /// when the content actually changed, so another pane showing the same document (from a split)
    /// can tell its own loaded content is now stale. `host` is the pane host `textView` belongs to:
    /// its own content already reflects this generation, so it needs no reload for itself.
    private func syncTextViewToDocument(_ textView: TextView, document: WorkbenchDocument, from host: IDEEditorPaneHost) {
        var changed = false
        if document.isFileBacked {
            // File-backed `document.text` is empty by design, so compare the live buffer's
            // generation rather than treating every sync (tab switch, ⌘N) as an edit.
            changed = host.loadedBufferGeneration != textView.contentGeneration
        } else {
            let newText = textView.text
            if newText != document.text {
                document.text = newText
                changed = true
            }
        }
        document.selectedRange = textView.selectedRange
        document.scrollOffset = textView.contentOffset
        host.loadedBufferGeneration = textView.contentGeneration
        if changed {
            document.contentGeneration &+= 1
            host.loadedGeneration = document.contentGeneration
        }
    }

    /// The freshest known text for `document`: the live content of whichever open pane's host is
    /// currently caught up with `document.contentGeneration`, then any host still showing this
    /// document (its buffer is valid even if a sibling just bumped generation), then
    /// `document.text`. File-backed documents keep `text` empty, so the host fallbacks are what
    /// stop a tab/split switch from rebuilding an empty editor.
    private func sourceText(for document: WorkbenchDocument) -> String {
        var staleHostText: String?
        for pane in workbench.panes {
            guard let host = hostCache.peek(pane.id),
                  host.loadedDocumentID == document.id
            else { continue }
            let text = host.textView.text
            if host.loadedGeneration == document.contentGeneration {
                return text
            }
            if staleHostText == nil {
                staleHostText = text
            }
        }
        return staleHostText ?? document.text
    }

    private func showDocument(
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        guard let document = pane.selectedDocument else { return }
        if document.contentKind == .image {
            showImageDocument(document, in: pane, host: host)
            return
        }
        host.imageViewerController.hide()
        host.textView.languageIdentifier = document.languageIdentifier
        host.markdownPreviewController.documentBaseURL = document.url
        host.markdownPreviewController.closeIfNotMarkdown()
        adapter.bindNavigationHistory(to: host.textView, document: document)
        let isSameDocument = host.loadedDocumentID == document.id
        if isSameDocument, document.pendingState == nil, host.loadedGeneration == document.contentGeneration {
            return
        }
        if isSameDocument {
            // A different pane showing this same document (from a split) just synced newer
            // content into it. Capture this pane's own scroll/selection before reloading so
            // `applyState` can restore them instead of jumping to wherever the other pane's
            // cursor happens to be.
            host.lastSelectedRange = host.textView.selectedRange
            host.lastScrollOffset = host.textView.contentOffset
        } else if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            // File-backed documents don't store text on the model. Snapshot the live buffer
            // before this TextView is overwritten so switching back (or a sibling pane
            // picking up edits) can restore it instead of rebuilding from empty `text`.
            previous.pendingState = host.textView.makeCapturedState()
        }
        if let state = document.pendingState {
            document.pendingState = nil
            host.applyGate.bump()
            applyState(state, for: document, in: pane, host: host)
            return
        }
        // Untitled / empty in-memory buffers can apply on the main queue immediately. Doing
        // this through `prepareAndApply` raced sibling panes: they would reload from empty
        // `document.text` while this pane still held the previous file's buffer.
        if !document.isFileBacked, document.text.isEmpty {
            host.applyGate.bump()
            applyState(
                TextViewState(text: "", theme: IDEEditorTheme.shared.current),
                for: document,
                in: pane,
                host: host
            )
            return
        }
        let generation = host.applyGate.bump()
        PenumbraStateBuilder.prepareAndApply(
            text: sourceText(for: document),
            theme: IDEEditorTheme.shared.current,
            language: document.language,
            languageProvider: Self.languageProvider,
            generation: generation,
            isCurrent: { [host] gen in host.applyGate.matches(gen) },
            apply: { [weak self, weak host] state in
                guard let self, let host else { return }
                self.applyState(state, for: document, in: pane, host: host)
            }
        )
    }

    private func showImageDocument(
        _ document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        guard let url = document.url else { return }
        let isSameDocument = host.loadedDocumentID == document.id
        if isSameDocument, host.imageViewerController.isShowing(url: url) {
            return
        }
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.imageViewerController.show(url: url)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            adapter.refreshCachedDocuments()
            host.imageViewerController.focusForInteraction()
        }
    }

    private func applyState(
        _ state: TextViewState,
        for document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        // A same-document refresh (another pane on the same document just synced newer content)
        // restores this pane's own captured position; a genuine switch to a different document
        // uses that document's last-known position instead.
        let isSameDocumentRefresh = host.loadedDocumentID == document.id
        host.textView.setState(state)
        if isSameDocumentRefresh, let lastSelectedRange = host.lastSelectedRange {
            host.textView.selectedRange = lastSelectedRange
        } else {
            host.textView.selectedRange = document.selectedRange
        }
        if isSameDocumentRefresh, let lastScrollOffset = host.lastScrollOffset {
            host.textView.contentOffset = lastScrollOffset
        } else if document.scrollOffset != .zero {
            host.textView.contentOffset = document.scrollOffset
        }
        host.lastSelectedRange = nil
        host.lastScrollOffset = nil
        preferences.apply(to: host.textView)
        let attachedSource = document.url.map { JavaAttachedSources.isExtractedSource($0) } ?? false
        host.textView.isEditable = !attachedSource
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        host.loadedBufferGeneration = host.textView.contentGeneration
        host.textView.layoutSubtreeIfNeeded()
        // `setState` above does not route through `textViewDidChange`, so a preview left open
        // from the previous document in this pane would otherwise keep showing stale content
        // until the next keystroke.
        host.markdownPreviewController.refresh()
        if pane.id == workbench.activePaneID {
            adapter.refreshCachedDocuments()
            host.textView.focusTextInputWhenReady()
            host.intelligenceController?.refreshDiagnostics()
        }
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func promptGradleTrust(for url: URL) async -> Bool {
        let name = url.lastPathComponent
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Trust and run Gradle build scripts for “\(name)”?"
            alert.informativeText = "Gradle build scripts can run arbitrary code, including code from plugins they apply. Trust this folder only if you trust its contents."
            alert.addButton(withTitle: "Trust Project")
            alert.addButton(withTitle: "Don't Trust")
            let finish: @Sendable (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window) { response in
                    finish(response)
                }
            } else {
                finish(alert.runModal())
            }
        }
    }

    /// Shown once before Umbra first decompiles a `.class` file with no attached source. Accepting
    /// persists to ``IDEPreferences/javaDecompilerAgreementAccepted``, which the caller then treats
    /// as standing consent — this alert should not appear again.
    private func requestDecompilerConsent() async -> Bool {
        let accepted = await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = JavaDecompilerAgreement.title
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Cancel")
            let scrollView = NSTextView.scrollableTextView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
            if let textView = scrollView.documentView as? NSTextView {
                textView.string = JavaDecompilerAgreement.text
                textView.isEditable = false
                textView.font = .systemFont(ofSize: 11)
            }
            alert.accessoryView = scrollView
            let finish: @Sendable (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window) { response in
                    finish(response)
                }
            } else {
                finish(alert.runModal())
            }
        }
        if accepted {
            preferences.javaDecompilerAgreementAccepted = true
        }
        return accepted
    }

    private func presentMetalFailureOnce(reason: String) {
        guard !hasPresentedMetalFailure else { return }
        hasPresentedMetalFailure = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Metal rendering was disabled"
        alert.informativeText = "\(reason)\n\nThe editor has switched to Core Graphics."
        alert.addButton(withTitle: "OK")
        if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension IDEWorkspace: TextViewDelegate {
    public func textViewDidChangeSelection(_ textView: TextView) {
        updateStatus(from: textView)
    }

    public func textViewDidChange(_ textView: TextView) {
        refreshJavaRunAvailability(from: textView)
        refreshHTTPSendAvailability(from: textView)
        refreshPresentation()
    }

    public func textView(
        _ textView: TextView,
        didChangeDistractionFreeChromeVisibility isVisible: Bool,
        transitionDuration: TimeInterval
    ) {
        withAnimation(isVisible ? .spring(duration: transitionDuration, bounce: 0.1) : .easeOut(duration: transitionDuration)) {
            chromeOpacity = isVisible ? 1 : 0
        }
    }
}
