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
    private var paletteController: CommandPaletteController?
    @ObservationIgnored
    private weak var paletteOverlayContainer: NSView?
    @ObservationIgnored
    private var hostedPaneIDs: Set<UUID> = []
    private var hasPresentedMetalFailure = false
    private var recentFiles: [URL] = []

    public let preferences = IDEPreferences.shared
    let project = IDEProjectModel()

    var javaSupport: IDEJavaSupport { intelligenceServices.javaSupport }

    public init() {}

    var isSidebarVisible = true
    var chromeOpacity = 1.0
    private(set) var layoutEpoch: UInt64 = 0
    private(set) var activePaneID = UUID()
    var showsWelcome = true
    var showsFirstRunGuide = false

    var windowTitle = "Umbra"
    var headerContext = IDEHeaderContext()
    var statusLine = 1
    var statusColumn = 1
    var statusLanguage = ""
    var isMarkdownPreviewVisible = false
    var statusSelectionLength = 0
    var statusRenderer = "Core Graphics"
    var tabsByPane: [UUID: [IDETabRow]] = [:]
    var isFindInFilesVisible = false
    var findInFilesQuery = ""
    var findInFilesHits: [ProjectSearchResult] = []
    var findInFilesStatus = ""
    var isTerminalVisible = false
    var terminalHeight = IDEAppearance.Spacing.terminalDefaultHeight
    var terminalFocusRequestID: UInt64 = 0
    var terminalTabs: [IDETerminalTab] = []
    var selectedTerminalTabID: UUID?

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
        intelligenceServices.javaSupport.requestTrust = { [weak self] url in
            guard let self else { return false }
            return await self.promptGradleTrust(for: url)
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

        Task {
            await workspaceBridge.syncWorkbench(workbench)
            await workspaceBridge.workspace.connect(to: adapter)
            await intelligenceServices.indexingService.connect(to: workspaceBridge.workspace)
            await intelligenceServices.javaSupport.connect(to: workspaceBridge.workspace)
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
            self.applyProjectRoot(url)
            self.showsWelcome = false
            self.refreshPresentation()
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

    public func toggleTerminal() {
        isTerminalVisible.toggle()
        if isTerminalVisible {
            if terminalTabs.isEmpty {
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
            hideTerminal()
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
        selectedTerminalTabID = id
        requestTerminalFocus()
        saveSession()
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
                    applyProjectRoot(url)
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

    func makeSession(sidebarWidth: Double, terminalHeight: Double? = nil) -> AppSession {
        AppSession(
            restoration: hasOpenDocuments ? workbench.makeRestorationState() : nil,
            projectRootBookmark: project.makeBookmarkData(),
            recentFiles: recentFiles,
            preferences: preferences.snapshot(),
            sidebarWidth: sidebarWidth,
            isSidebarVisible: isSidebarVisible,
            isTerminalVisible: isTerminalVisible,
            terminalHeight: terminalHeight ?? self.terminalHeight,
            terminalTabs: terminalTabs.isEmpty ? nil : terminalTabs,
            selectedTerminalTabID: selectedTerminalTabID
        )
    }

    func saveSession(
        sidebarWidth: Double = IDEAppearance.Spacing.sidebarWidth,
        terminalHeight: Double? = nil
    ) {
        IDESessionStore.save(makeSession(sidebarWidth: sidebarWidth, terminalHeight: terminalHeight))
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
        isSidebarVisible = session.isSidebarVisible
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
        host.wireMarkdownPreview()
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

    func openDocument(from url: URL, selecting range: NSRange? = nil) async {
        do {
            let document: WorkbenchDocument
            if ImageContentDetector.isImageFile(url) {
                document = WorkbenchDocument.loadImage(from: url)
            } else {
                let identifier = LanguageIdentifier.identifier(for: url)
                let language = IDELanguageSupport.language(forIdentifier: identifier)
                document = try await WorkbenchDocument.load(
                    contentsOf: url,
                    theme: IDEEditorTheme.shared.current,
                    language: language,
                    languageIdentifier: identifier,
                    languageProvider: Self.languageProvider
                )
                document.language = language
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
            EditorCommand(id: "app.splitDown", title: "Split Editor Down", group: "View",
                          action: { [weak self] in self?.splitDown() }),
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
            EditorCommand(id: "app.toggleDistractionFree", title: "Toggle Distraction Free", group: "View",
                          action: { [weak self] in self?.toggleDistractionFreeMode() }),
            EditorCommand(id: "app.toggleFocusMode", title: "Toggle Focus Mode", group: "View",
                          action: { [weak self] in self?.toggleFocusMode() }),
            EditorCommand(id: "app.toggleMetalRendering", title: "Use Metal Renderer", group: "View",
                          action: { [weak self] in self?.toggleMetalRendering() }),
            EditorCommand(id: "app.toggleTerminal", title: "Toggle Terminal", group: "View",
                          action: { [weak self] in self?.toggleTerminal() }),
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
            EditorCommand(id: "app.java.reloadGradleProject", title: "Java: Reload Gradle Project", group: "Java",
                          action: { [weak self] in self?.reloadGradleProject() }),
            EditorCommand(id: "app.java.showGradleOutput", title: "Java: Show Gradle Output", group: "Java",
                          action: { [weak self] in self?.showGradleOutput() })
        ])
    }

    func reloadGradleProject() {
        javaSupport.reloadGradleProject()
    }

    func showGradleOutput() {
        IDEGradleOutputPanel.shared.show(javaSupport.gradleOutputText())
    }

    func dismissGradleReloadBanner() {
        javaSupport.dismissGradleBuildFileChanges()
    }

    private func applyProjectRoot(_ url: URL?) {
        project.setRoot(url)
        syncTerminalWorkingDirectory()
        intelligenceServices.javaSupport.setProjectRoot(url)
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
