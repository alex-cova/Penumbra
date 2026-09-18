import AppKit
import EditorIntelligence
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

/// Path breadcrumb for the active document, shown in the toolbar. Empty when nothing is open.
struct IDEHeaderContext: Equatable {
    var components: [String] = []
    var isDirty = false
}

@MainActor
@Observable
public final class IDEWorkspace {
    private static let languageProvider = BundledLanguageProvider()

    private let workbench = EditorWorkbench()
    private let workspaceBridge = PenumbraWorkbenchWorkspaceBridge()
    private let hostCache = EditorHostCache<UUID, IDEEditorPaneHost>(maxEntries: 16)
    private let intelligenceServices = IDEIntelligenceServices()
    private var adapter: PenumbraWorkbenchEditorAdapter!
    @ObservationIgnored
    private var hostedPaneIDs: Set<UUID> = []
    private var hasPresentedMetalFailure = false
    private var recentFiles: [URL] = []

    public let preferences = IDEPreferences.shared
    let project = IDEProjectModel()

    public init() {}

    var isSidebarVisible = true
    var chromeOpacity = 1.0
    private(set) var layoutEpoch: UInt64 = 0
    private(set) var activePaneID = UUID()
    var showsWelcome = true

    var windowTitle = "Umbra"
    var headerContext = IDEHeaderContext()
    var statusLine = 1
    var statusColumn = 1
    var statusLanguage = ""
    var statusSelectionLength = 0
    var statusRenderer = "Core Graphics"
    var tabsByPane: [UUID: [IDETabRow]] = [:]
    var isFindInFilesVisible = false
    var findInFilesQuery = ""
    var findInFilesHits: [ProjectSearchResult] = []
    var findInFilesStatus = ""

    var editorLayout: EditorLayout { workbench.layout }
    var hasOpenDocuments: Bool { !workbench.allDocuments().isEmpty }
    /// What `IDERootView` should actually render — just the user's sidebar toggle. The Explorer
    /// stays visible even with no folder or documents open, showing its own empty state.
    var showsSidebar: Bool { isSidebarVisible }

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

    public func newFile() {
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
            self.project.setRoot(url)
            self.showsWelcome = false
        }
    }

    public func openRecentFile(_ url: URL) {
        Task { await openDocument(from: url) }
    }

    public var recentFileURLs: [URL] {
        recentFiles
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
        host(for: workbench.activePaneID).paletteController.presentFindAction()
        focusActiveEditor()
    }

    public func showQuickOpen() {
        host(for: workbench.activePaneID).paletteController.presentQuickOpen()
        focusActiveEditor()
    }

    public func showGoToSymbol() {
        host(for: workbench.activePaneID).paletteController.presentSymbols()
        focusActiveEditor()
    }

    public func showGoToLine() {
        host(for: workbench.activePaneID).paletteController.presentGoToLine()
        focusActiveEditor()
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

    func openFindInFilesHit(_ hit: ProjectSearchResult) {
        let length = max(0, hit.range.end.utf16Offset - hit.range.start.utf16Offset)
        let range = NSRange(location: hit.range.start.utf16Offset, length: length)
        Task { await openDocument(from: hit.url, selecting: range) }
    }

    public func splitRight() {
        workbench.splitActivePane(edge: .trailing)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    public func splitDown() {
        workbench.splitActivePane(edge: .bottom)
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

    public func toggleMarkdownPreview() {
        adapter.textView?.perform(.toggleMarkdownPreview)
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

    public func toggleTypewriterScrolling() {
        guard let textView = adapter.textView else { return }
        textView.isTypewriterScrollingEnabled.toggle()
        if textView.isTypewriterScrollingEnabled {
            textView.isAutomaticScrollEnabled = true
        }
        focusActiveEditor()
    }

    public func toggleDistractionFreeMode() {
        adapter.textView?.isDistractionFreeModeEnabled.toggle()
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

    public var isMetalRenderingEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isMetalRenderingEnabled)
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
        host.wireMarkdownPreview()
        // Find in Files (⌘⇧F) gets Umbra's own bottom panel rather than the built-in palette
        // mode; Go to Line needs no host wiring at all — `CommandPaletteController` handles
        // `.goToLine` natively.
        host.intelligenceController?.onRequestProjectSearch = { [weak self] in
            self?.showFindInFiles()
            return true
        }
        configurePalette(host.paletteController)
        preferences.apply(to: host.textView)
        return host
    }

    func openDocument(from url: URL, selecting range: NSRange? = nil) async {
        do {
            let identifier = LanguageIdentifier.identifier(for: url)
            let language = IDELanguageSupport.language(forIdentifier: identifier)
            let document = try await WorkbenchDocument.load(
                contentsOf: url,
                theme: IDEEditorTheme.shared,
                language: language,
                languageIdentifier: identifier,
                languageProvider: Self.languageProvider
            )
            document.language = language
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
                          action: { [weak self] in self?.toggleMetalRendering() })
        ])
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
            let newContext = IDEHeaderContext(
                components: breadcrumbComponents(for: document),
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

    /// Project-relative path components for the breadcrumb, e.g. `["src", "ui", "Editor.swift"]`.
    /// Falls back to just the display name when the document has no URL or sits outside the
    /// open project root.
    private func breadcrumbComponents(for document: WorkbenchDocument) -> [String] {
        guard let url = document.url else { return [document.displayName] }
        guard let rootURL = project.rootURL else { return [url.lastPathComponent] }

        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return [url.lastPathComponent] }

        let relative = filePath.dropFirst(rootPath.count)
        let components = relative.split(separator: "/").map(String.init)
        return components.isEmpty ? [url.lastPathComponent] : components
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
        if !document.isFileBacked {
            document.text = textView.text
        }
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
        host.markdownPreviewController.documentBaseURL = document.url
        host.markdownPreviewController.closeIfNotMarkdown()
        adapter.bindNavigationHistory(to: host.textView, document: document)
        if reloadOnlyIfNeeded, host.loadedDocumentID == document.id, document.pendingState == nil {
            return
        }
        if host.loadedDocumentID == document.id, document.pendingState == nil {
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
        PenumbraStateBuilder.prepareAndApply(
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
        preferences.apply(to: host.textView)
        host.loadedDocumentID = document.id
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
