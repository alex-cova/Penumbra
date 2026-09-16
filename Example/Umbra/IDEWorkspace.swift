import AppKit
import Combine
import EditorIntelligence
import Runestone
import SwiftUI
import RunestoneLanguages
import RunestoneMarkdownLanguage
import UmbraCore

struct IDETabRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isDirty: Bool
    let isSelected: Bool
}

@MainActor
final class IDEWorkspace: ObservableObject {
    private static let languageProvider = BundledLanguageProvider()

    private let workbench = EditorWorkbench()
    private let workspaceBridge = RunestoneWorkbenchWorkspaceBridge()
    private let hostCache = EditorHostCache<UUID, IDEEditorPaneHost>(maxEntries: 16)
    private let intelligenceServices = IDEIntelligenceServices()
    private var adapter: RunestoneWorkbenchEditorAdapter!
    private var isPromptingGoToLine = false
    private var hostedPaneIDs: Set<UUID> = []
    private var hasPresentedMetalFailure = false
    private var recentFiles: [URL] = []

    let preferences = IDEPreferences.shared
    let project = IDEProjectModel()

    @Published var isSidebarVisible = true
    @Published var chromeOpacity = 1.0
    @Published private(set) var layoutEpoch: UInt64 = 0
    @Published private(set) var activePaneID = UUID()
    @Published var showsWelcome = true

    @Published var windowTitle = "Umbra"
    @Published var statusLine = 1
    @Published var statusColumn = 1
    @Published var statusLanguage = ""
    @Published var statusSelectionLength = 0
    @Published var statusRenderer = "Core Graphics"
    @Published var tabsByPane: [UUID: [IDETabRow]] = [:]
    @Published var isFindInFilesVisible = false
    @Published var findInFilesQuery = ""
    @Published var findInFilesHits: [FindInFilesHit] = []
    @Published var findInFilesStatus = ""

    var editorLayout: EditorLayout { workbench.layout }
    var hasOpenDocuments: Bool { !workbench.allDocuments().isEmpty }

    func host(for paneID: UUID) -> IDEEditorPaneHost {
        hostedPaneIDs.insert(paneID)
        return hostCache.host(for: paneID) {
            makeHost(paneID: paneID)
        }
    }

    func focusActiveEditor() {
        host(for: workbench.activePaneID).textView.focusTextInputWhenReady()
    }

    func bootstrap() {
        applyLaunchConfiguration()
        loadSession()
        wireAdapter()
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()
        showsWelcome = !hasOpenDocuments

        if let index = CommandLine.arguments.firstIndex(of: "--open"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await openDocument(from: url) }
        }

        Task {
            await workspaceBridge.syncWorkbench(workbench)
            await workspaceBridge.workspace.connect(to: adapter)
            await intelligenceServices.indexingService.connect(to: workspaceBridge.workspace)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveSession()
            }
        }
    }

    // MARK: - Commands

    func newFile() {
        let document = WorkbenchDocument(
            displayName: "Untitled",
            text: "",
            language: nil,
            languageIdentifier: nil
        )
        workbench.openDocument(document)
        showsWelcome = false
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { await self.openDocument(from: url) }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            self.project.setRoot(url)
            self.showsWelcome = false
        }
    }

    func openRecentFile(_ url: URL) {
        Task { await openDocument(from: url) }
    }

    var recentFileURLs: [URL] {
        recentFiles
    }

    func saveActiveDocument() async {
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
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    func saveActiveDocumentAs() async {
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
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    func closeActiveTab() {
        guard let document = workbench.activePane.selectedDocument else { return }
        closeDocument(document.id, in: workbench.activePane)
    }

    func showCommandPalette() {
        host(for: workbench.activePaneID).paletteController.presentFindAction()
        focusActiveEditor()
    }

    func showQuickOpen() {
        host(for: workbench.activePaneID).paletteController.presentQuickOpen()
        focusActiveEditor()
    }

    func showGoToSymbol() {
        host(for: workbench.activePaneID).paletteController.presentSymbols()
        focusActiveEditor()
    }

    func showFind() {
        adapter.textView?.perform(.toggleFindPanel)
        focusActiveEditor()
    }

    func showReplace() {
        adapter.textView?.perform(.toggleReplacePanel)
        focusActiveEditor()
    }

    func showFindInFiles() {
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

    func runFindInFiles() {
        isFindInFilesVisible = true
        let query = findInFilesQuery
        guard let root = project.rootURL else {
            findInFilesHits = []
            findInFilesStatus = "Open a folder to search the project"
            return
        }
        let files = FindInFilesService.files(under: root)
        findInFilesStatus = "Searching…"
        let hits = FindInFilesService.search(query: query, files: files)
        findInFilesHits = hits
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findInFilesStatus = "Enter a query and press Return"
        } else if hits.isEmpty {
            findInFilesStatus = "No results"
        } else if hits.count == 1 {
            findInFilesStatus = "1 result"
        } else {
            findInFilesStatus = "\(hits.count) results"
        }
    }

    func openFindInFilesHit(_ hit: FindInFilesHit) {
        let target = FindInFilesService.openTarget(for: hit)
        Task { await openDocument(from: target.url, selecting: target.range) }
    }

    func showGoToLine() {
        guard !isPromptingGoToLine else { return }
        isPromptingGoToLine = true
        defer { isPromptingGoToLine = false }
        guard let input = promptGoToLine() else { return }
        _ = applyGoToLine(input)
    }

    @discardableResult
    func applyGoToLine(_ raw: String) -> Bool {
        guard let textView = adapter?.textView else { return false }
        return GoToLineCommand.apply(raw, to: textView)
    }

    func splitRight() {
        workbench.splitActivePane(edge: .trailing)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    func splitDown() {
        workbench.splitActivePane(edge: .bottom)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    func closeActivePane() {
        closePane(workbench.activePaneID)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        focusActiveEditor()
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

    func toggleTypewriterScrolling() {
        guard let textView = adapter.textView else { return }
        textView.isTypewriterScrollingEnabled.toggle()
        if textView.isTypewriterScrollingEnabled {
            textView.isAutomaticScrollEnabled = true
        }
        focusActiveEditor()
    }

    func toggleDistractionFreeMode() {
        adapter.textView?.isDistractionFreeModeEnabled.toggle()
        focusActiveEditor()
    }

    func toggleMetalRendering() {
        preferences.isMetalRenderingEnabled.toggle()
        applyPreferencesToAllHosts()
        focusActiveEditor()
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
                    project.setRoot(url)
                    showsWelcome = false
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

    func makeSession(sidebarWidth: Double) -> AppSession {
        AppSession(
            restoration: hasOpenDocuments ? workbench.makeRestorationState() : nil,
            projectRootBookmark: project.makeBookmarkData(),
            recentFiles: recentFiles,
            preferences: preferences.snapshot(),
            sidebarWidth: sidebarWidth,
            isSidebarVisible: isSidebarVisible
        )
    }

    func saveSession(sidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth) {
        IDESessionStore.save(makeSession(sidebarWidth: sidebarWidth))
    }

    // MARK: - Private

    private func loadSession() {
        let session = IDESessionStore.load()
        preferences.restore(from: session.preferences)
        recentFiles = session.recentFiles
        isSidebarVisible = session.isSidebarVisible
        project.restoreRoot(from: session.projectRootBookmark)

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
        adapter = RunestoneWorkbenchEditorAdapter(workbench: workbench)
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
        configurePalette(host.paletteController)
        preferences.apply(to: host.textView)
        installUmbraActionHandler(on: host.textView)
        return host
    }

    func openDocument(from url: URL, selecting range: NSRange? = nil) async {
        do {
            let identifier = LanguageIdentifier.identifier(for: url)
            let document = try await WorkbenchDocument.load(
                contentsOf: url,
                language: nil,
                languageIdentifier: identifier,
                languageProvider: Self.languageProvider
            )
            document.language = IDELanguageSupport.language(forIdentifier: identifier)
            workbench.openDocument(document)
            if let range, let selected = workbench.activePane.selectedDocument {
                selected.selectedRange = range
            }
            recordRecentFile(url)
            showsWelcome = false
            rebuildLayoutHosts()
            activatePane(workbench.activePaneID)
            if let range {
                let host = host(for: workbench.activePaneID)
                if host.loadedDocumentID == workbench.activePane.selectedDocumentID {
                    host.textView.selectedRange = range
                    host.textView.scrollRangeToVisible(range)
                    _ = host.textView.focusTextInput()
                }
            }
            await workspaceBridge.syncWorkbench(workbench)
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    private func recordRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 15 {
            recentFiles = Array(recentFiles.prefix(15))
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
                showDocument(in: pane, host: host, reloadOnlyIfNeeded: true)
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
        palette.fileEntriesProvider = { [weak self] in
            guard let self else { return [] }
            let projectFiles = self.project.allProjectFiles().map {
                PaletteFileEntry(url: $0, displayName: $0.lastPathComponent)
            }
            let openFiles = self.workbench.allDocuments().compactMap { document in
                document.url.map { PaletteFileEntry(url: $0, displayName: document.displayName) }
            }
            var seen = Set<URL>()
            return (projectFiles + openFiles).filter { seen.insert($0.url).inserted }
        }
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
            EditorCommand(id: "app.toggleSidebar", title: "Toggle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleSidebar() }),
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
            EditorCommand(id: "app.toggleMetalRendering", title: "Use Metal Renderer", group: "View",
                          action: { [weak self] in self?.toggleMetalRendering() }),
            EditorCommand(id: "app.findInFiles", title: "Find in Files…", group: "Find",
                          shortcutDisplay: "⌘⇧F",
                          action: { [weak self] in self?.showFindInFiles() })
        ])
    }

    private func installUmbraActionHandler(on textView: TextView) {
        let previous = textView.editorActionHandler
        textView.editorActionHandler = { [weak self] action in
            guard let self else { return previous?(action) ?? false }
            if action == .goToLine {
                self.showGoToLine()
                return true
            }
            if action == UmbraKeymap.findInFiles {
                self.showFindInFiles()
                return true
            }
            return previous?(action) ?? false
        }
    }

    private func promptGoToLine() -> String? {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a 1-based line number."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Line number"
        field.stringValue = ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func activatePane(_ paneID: UUID) {
        let host = host(for: paneID)
        let alreadyActive = workbench.activePaneID == paneID && adapter.textView === host.textView
        let sameDocument = host.loadedDocumentID == workbench.activePane.selectedDocumentID
        if alreadyActive && sameDocument {
            return
        }
        workbench.activatePane(paneID)
        activePaneID = workbench.activePaneID
        adapter.textView = host.textView
        host.textView.editorDelegate = adapter
        showDocument(in: workbench.activePane, host: host)
        adapter.refreshCachedDocuments()
        host.intelligenceController?.refreshDiagnostics()
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
        if let document = workbench.activePane.selectedDocument {
            windowTitle = "\(document.displayName) · Umbra"
        } else {
            windowTitle = "Umbra"
        }
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
    }

    private func syncTextViewToDocument(_ textView: TextView, document: WorkbenchDocument) {
        document.text = textView.text
        document.selectedRange = textView.selectedRange
        document.scrollOffset = textView.contentOffset
    }

    private func showDocument(
        in pane: EditorPane,
        host: IDEEditorPaneHost,
        reloadOnlyIfNeeded: Bool = false
    ) {
        guard let document = pane.selectedDocument else { return }
        host.textView.languageIdentifier = document.languageIdentifier
        adapter.bindNavigationHistory(to: host.textView, document: document)
        if reloadOnlyIfNeeded, host.loadedDocumentID == document.id {
            return
        }
        if host.loadedDocumentID == document.id {
            return
        }
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }) {
            syncTextViewToDocument(host.textView, document: previous)
        }
        if let state = document.pendingState {
            document.pendingState = nil
            host.applyGate.bump()
            applyState(state, for: document, in: pane, host: host)
            return
        }
        let generation = host.applyGate.bump()
        RunestoneStateBuilder.prepareAndApply(
            text: document.text,
            theme: IDEEditorTheme.shared,
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

    private func applyState(
        _ state: TextViewState,
        for document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        host.textView.setState(state)
        host.textView.selectedRange = document.selectedRange
        if document.scrollOffset != .zero {
            host.textView.contentOffset = document.scrollOffset
        }
        host.loadedDocumentID = document.id
        host.textView.layoutSubtreeIfNeeded()
        if pane.id == workbench.activePaneID {
            adapter.refreshCachedDocuments()
            host.textView.focusTextInputWhenReady()
            host.intelligenceController?.refreshDiagnostics()
        }
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
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
    func textViewDidChangeSelection(_ textView: TextView) {
        updateStatus(from: textView)
    }

    func textViewDidChange(_ textView: TextView) {
        refreshPresentation()
    }

    func textView(
        _ textView: TextView,
        didChangeDistractionFreeChromeVisibility isVisible: Bool,
        transitionDuration: TimeInterval
    ) {
        withAnimation(isVisible ? .spring(duration: transitionDuration, bounce: 0.1) : .easeOut(duration: transitionDuration)) {
            chromeOpacity = isVisible ? 1 : 0
        }
    }
}
