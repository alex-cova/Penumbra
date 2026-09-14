import AppKit
import Combine
import Runestone
import SwiftUI
import RunestoneLanguages
import RunestoneMarkdownLanguage

enum IDEActivityItem: String, CaseIterable, Identifiable {
    case explorer
    case search
    case commands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .search: "Search"
        case .commands: "Commands"
        }
    }

    var symbolName: String {
        switch self {
        case .explorer: "sidebar.leading"
        case .search: "magnifyingglass"
        case .commands: "command"
        }
    }
}

struct IDEDocumentRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let languageIdentifier: String?
    let isDirty: Bool
    let isSelected: Bool
}

struct IDETabRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isDirty: Bool
    let isSelected: Bool
}

@MainActor
final class IDEWorkspace: ObservableObject {
    let layoutHost = IDEEditorLayoutHostView()

    private static let languageCache = TreeSitterLanguageCache<String>()
    private static let languageProvider = BundledLanguageProvider()

    private let workbench = EditorWorkbench()
    private let workspaceBridge = RunestoneWorkbenchWorkspaceBridge()
    private var adapter: RunestoneWorkbenchEditorAdapter!
    private var paneHosts: [UUID: IDEEditorPaneHost] = [:]

    @Published var isSidebarVisible = true
    @Published var selectedActivity: IDEActivityItem = .explorer
    @Published var chromeOpacity = 1.0

    @Published var windowTitle = "Runestone"
    @Published var statusLine = 1
    @Published var statusColumn = 1
    @Published var statusLanguage = ""
    @Published var statusSelectionLength = 0
    @Published var statusRenderer = "Core Graphics"

    /// Host-side Metal preference. Independent of the library `RunestoneMetalRendering` kill switch;
    /// this sets `TextView.isMetalRenderingEnabled` on every pane. Persisted across launches.
    /// Override at launch with `--metal` or `--no-metal`.
    @Published var isMetalRenderingEnabled: Bool = IDEWorkspace.storedMetalRenderingEnabled {
        didSet {
            guard oldValue != isMetalRenderingEnabled else { return }
            UserDefaults.standard.set(isMetalRenderingEnabled, forKey: Self.metalRenderingDefaultsKey)
            applyMetalRenderingPreference()
        }
    }

    @Published var sidebarDocuments: [IDEDocumentRow] = []
    @Published var activePaneTabs: [IDETabRow] = []

    private static let metalRenderingDefaultsKey = "MacExampleMetalRendering"

    private static var storedMetalRenderingEnabled: Bool {
        UserDefaults.standard.object(forKey: metalRenderingDefaultsKey) as? Bool ?? true
    }

    private static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        guard let identifier else { return nil }
        return languageCache.language(for: identifier) {
            if identifier == "markdown" {
                return .markdown
            }
            return TreeSitterLanguage.bundled(forIdentifier: identifier)
        }
    }

    func focusActiveEditor() {
        if let textView = paneHosts[workbench.activePaneID]?.textView {
            _ = textView.focusTextInput()
        }
    }

    func bootstrap() {
        applyLaunchConfiguration()
        seedSampleDocuments()
        wireAdapter()
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()

        if let index = CommandLine.arguments.firstIndex(of: "--open"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await openDocument(from: url) }
        }

        Task {
            await workspaceBridge.syncWorkbench(workbench)
            await workspaceBridge.workspace.connect(to: adapter)
        }
    }

    // MARK: - Commands

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

    func saveActiveDocument() async {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument else { return }
        let textView = paneHosts[pane.id]?.textView
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
        paneHosts[workbench.activePaneID]?.paletteController.presentFindAction()
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
        let closingID = workbench.activePaneID
        workbench.closePane(closingID)
        paneHosts.removeValue(forKey: closingID)
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleMinimap() {
        adapter.textView?.showMinimap.toggle()
    }

    func toggleTypewriterScrolling() {
        guard let textView = adapter.textView else { return }
        textView.isTypewriterScrollingEnabled.toggle()
        if textView.isTypewriterScrollingEnabled {
            textView.isAutomaticScrollEnabled = true
        }
    }

    func toggleDistractionFreeMode() {
        adapter.textView?.isDistractionFreeModeEnabled.toggle()
    }

    func toggleMetalRendering() {
        isMetalRenderingEnabled.toggle()
    }

    func undo() {
        adapter.textView?.undoManager?.undo()
    }

    func redo() {
        adapter.textView?.undoManager?.redo()
    }

    func selectActivity(_ item: IDEActivityItem) {
        selectedActivity = item
        switch item {
        case .explorer:
            if !isSidebarVisible {
                isSidebarVisible = true
            }
        case .search:
            adapter.textView?.toggleFindPanel()
        case .commands:
            showCommandPalette()
        }
    }

    func selectSidebarDocument(_ id: UUID) {
        guard let pane = workbench.panes.first(where: { $0.documents.contains { $0.id == id } }),
              pane.selectedDocumentID != id else {
            return
        }
        workbench.activatePane(pane.id)
        pane.selectDocument(id)
        activatePane(pane.id)
        focusActiveEditor()
    }

    func selectTab(_ id: UUID) {
        let pane = workbench.activePane
        guard pane.selectedDocumentID != id else { return }
        pane.selectDocument(id)
        if let host = paneHosts[pane.id] {
            showDocument(in: pane, host: host)
            refreshPresentation()
            focusActiveEditor()
            Task { await workspaceBridge.syncPane(pane) }
        }
    }

    func closeTab(_ id: UUID) {
        closeDocument(id, in: workbench.activePane)
    }

    // MARK: - Private

    private func seedSampleDocuments() {
        let readme = WorkbenchDocument(
            displayName: "README.md",
            text: """
            # Runestone Demo

            Native macOS editor shell inspired by VS Code and Zed.

            - ⌘P: Quick Open
            - ⌘⇧P: Command Palette
            - ⌘\\: Split editor right
            """,
            language: Self.language(forIdentifier: "markdown"),
            languageIdentifier: "markdown"
        )
        let sampleJS = WorkbenchDocument(
            displayName: "sample.js",
            text: """
            function greet(name) {
              return `Hello, ${name}`;
            }

            const message = greet("Runestone");
            console.log(message);
            """,
            language: Self.language(forIdentifier: "javascript"),
            languageIdentifier: "javascript"
        )
        let contentView = WorkbenchDocument(
            displayName: "ContentView.swift",
            text: """
            import SwiftUI

            struct ContentView: View {
                @State private var count = 0

                var body: some View {
                    VStack {
                        Text("Count: \\(count)")
                        Button("Increment") { count += 1 }
                    }
                    .padding()
                }
            }
            """,
            language: Self.language(forIdentifier: "swift"),
            languageIdentifier: "swift"
        )
        workbench.openDocument(readme)
        workbench.openDocument(sampleJS)
        workbench.openDocument(contentView)
    }

    private func wireAdapter() {
        adapter = RunestoneWorkbenchEditorAdapter(workbench: workbench)
        adapter.forwardingDelegate = self
        adapter.onOpenHistoryEntry = { [weak self] entry in
            self?.openHistoryEntry(entry) ?? false
        }
        layoutHost.onPaneActivated = { [weak self] paneID in
            self?.activatePane(paneID)
        }
    }

    private func openDocument(from url: URL) async {
        do {
            let identifier = LanguageIdentifier.identifier(for: url)
            let document = try await WorkbenchDocument.load(
                contentsOf: url,
                language: nil,
                languageIdentifier: identifier,
                languageProvider: Self.languageProvider
            )
            document.language = Self.language(forIdentifier: identifier)
            workbench.openDocument(document)
            rebuildLayoutHosts()
            activatePane(workbench.activePaneID)
            await workspaceBridge.syncWorkbench(workbench)
            refreshPresentation()
        } catch {
            presentError(error)
        }
    }

    private func openHistoryEntry(_ entry: NavigationEntry) -> Bool {
        guard let documentID = entry.documentID,
              let pane = workbench.panes.first(where: { $0.documents.contains { $0.id == documentID } }),
              let host = paneHosts[pane.id] else {
            return false
        }
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
            closeActivePane()
            return
        }
        if let host = paneHosts[pane.id] {
            showDocument(in: pane, host: host)
        }
        refreshPresentation()
        Task { await workspaceBridge.syncPane(pane) }
    }

    private func rebuildLayoutHosts() {
        paneHosts = layoutHost.configure(
            layout: workbench.layout,
            existingHosts: paneHosts,
            makeHost: { pane in
                let host = IDEEditorPaneHost(pane: pane)
                host.textView.isMetalRenderingEnabled = self.isMetalRenderingEnabled
                host.onTabSelected = { [weak self] documentID in
                    guard let self, pane.id == self.workbench.activePaneID else {
                        pane.selectDocument(documentID)
                        self?.showDocument(in: pane, host: host)
                        self?.refreshPresentation()
                        return
                    }
                    self.selectTab(documentID)
                }
                host.onTabClosed = { [weak self] documentID in
                    self?.closeDocument(documentID, in: pane)
                }
                self.configurePalette(host.paletteController)
                return host
            }
        )
        for pane in workbench.panes {
            if let host = paneHosts[pane.id], pane.selectedDocument != nil {
                showDocument(in: pane, host: host, reloadOnlyIfNeeded: true)
            }
        }
        refreshPresentation()
    }

    private func configurePalette(_ palette: CommandPaletteController) {
        palette.recentFileEntriesProvider = { [weak self] in
            guard let self else { return [] }
            return self.workbench.recentDocuments(limit: 15).compactMap { document in
                document.url.map { PaletteFileEntry(url: $0, displayName: document.displayName) }
            }
        }
        palette.fileEntriesProvider = { [weak self] in
            guard let self else { return [] }
            return self.workbench.allDocuments().compactMap { document in
                document.url.map { PaletteFileEntry(url: $0, displayName: document.displayName) }
            }
        }
        palette.onOpenFile = { [weak self] url in
            guard let self else { return }
            Task { await self.openDocument(from: url) }
        }
        palette.commandRegistry.register([
            EditorCommand(id: "demo.splitRight", title: "Split Editor Right", group: "View",
                          action: { [weak self] in self?.splitRight() }),
            EditorCommand(id: "demo.toggleSidebar", title: "Toggle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleSidebar() }),
            EditorCommand(id: "demo.toggleMinimap", title: "Toggle Minimap", group: "View",
                          action: { [weak self] in self?.toggleMinimap() }),
            EditorCommand(id: "demo.toggleTypewriter", title: "Toggle Typewriter Scrolling", group: "View",
                          action: { [weak self] in self?.toggleTypewriterScrolling() }),
            EditorCommand(id: "demo.toggleMetalRendering", title: "Use Metal Renderer", group: "View",
                          action: { [weak self] in self?.toggleMetalRendering() })
        ])
    }

    private func activatePane(_ paneID: UUID) {
        workbench.activatePane(paneID)
        guard let host = paneHosts[paneID] else { return }
        let sameEditor = adapter.textView === host.textView
        let sameDocument = host.loadedDocumentID == workbench.activePane.selectedDocumentID
        if sameEditor && sameDocument {
            updateActivePaneChrome()
            return
        }
        adapter.textView = host.textView
        host.textView.editorDelegate = adapter
        showDocument(in: workbench.activePane, host: host)
        updateActivePaneChrome()
        adapter.refreshCachedDocuments()
        updateStatus(from: host.textView)
        refreshPresentation()
        Task { await workspaceBridge.syncPane(workbench.activePane) }
    }

    private func updateActivePaneChrome() {
        for (paneID, host) in paneHosts {
            host.setActive(paneID == workbench.activePaneID)
        }
    }

    private func refreshDirtyIndicators() {
        let selectedID = workbench.activePane.selectedDocumentID
        sidebarDocuments = workbench.allDocuments().map { document in
            IDEDocumentRow(
                id: document.id,
                title: document.displayName,
                languageIdentifier: document.languageIdentifier,
                isDirty: document.isDirty,
                isSelected: document.id == selectedID
            )
        }
        activePaneTabs = workbench.activePane.documents.map { document in
            IDETabRow(
                id: document.id,
                title: document.displayName,
                isDirty: document.isDirty,
                isSelected: document.id == selectedID
            )
        }
    }

    private func refreshPresentation() {
        let selectedID = workbench.activePane.selectedDocumentID
        sidebarDocuments = workbench.allDocuments().map { document in
            IDEDocumentRow(
                id: document.id,
                title: document.displayName,
                languageIdentifier: document.languageIdentifier,
                isDirty: document.isDirty,
                isSelected: document.id == selectedID
            )
        }
        activePaneTabs = workbench.activePane.documents.map { document in
            IDETabRow(
                id: document.id,
                title: document.displayName,
                isDirty: document.isDirty,
                isSelected: document.id == selectedID
            )
        }
        if let document = workbench.activePane.selectedDocument {
            windowTitle = "\(document.displayName) · Runestone"
        } else {
            windowTitle = "Runestone"
        }
        updateActivePaneChrome()
    }

    private func applyLaunchConfiguration() {
        let arguments = CommandLine.arguments
        if arguments.contains("--no-metal") {
            isMetalRenderingEnabled = false
        } else if arguments.contains("--metal") {
            isMetalRenderingEnabled = true
        }
    }

    private func applyMetalRenderingPreference() {
        for host in paneHosts.values {
            host.textView.isMetalRenderingEnabled = isMetalRenderingEnabled
        }
        if let textView = adapter?.textView {
            updateStatus(from: textView)
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
            theme: DefaultTheme(),
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
        }
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

extension IDEWorkspace: TextViewDelegate {
    func textViewDidChangeSelection(_ textView: TextView) {
        updateStatus(from: textView)
    }

    func textViewDidChange(_ textView: TextView) {
        refreshDirtyIndicators()
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
