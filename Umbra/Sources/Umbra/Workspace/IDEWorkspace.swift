import AppKit
import EditorIntelligence
import EditorIntelligenceLSP
import JavaIntelligence
import SwiftIntelligence
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
    /// An SF Symbol for tabs that are not files (diagrams); files get an icon from their name.
    var symbolName: String?
}

struct IDETerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var workingDirectory: URL
    var restartRequestID: UInt64 = 0
    /// Bumped to wipe the screen and scrollback of this tab's terminal.
    var clearRequestID: UInt64 = 0
    /// Set when this tab only displays an agent command. It never starts a login shell, and it is
    /// left out of the saved session: the text lives in the view until the window closes.
    var agentCommandID: UUID?
    /// Bumped when more output is waiting for this tab's view.
    var agentFeedGeneration: UInt64 = 0

    static func defaultTitle(for directory: URL) -> String {
        let base = directory.lastPathComponent
        return base.isEmpty ? "Terminal" : base
    }

    /// A tab title short enough for the terminal strip.
    static func commandTitle(for command: String) -> String {
        let flat = command.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 48
        guard flat.count > limit else { return flat.isEmpty ? "Command" : flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

extension IDETerminalTab: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory
    }
}

/// One segment in the status bar breadcrumb. A folder lists its contents and a file its
/// siblings, to switch files; a package lists the classes and subpackages inside it; a symbol
/// lists the enclosing type's members (Java) or jumps in-file.
struct IDEBreadcrumbItem: Equatable, Identifiable {
    enum Target: Equatable {
        case folder(URL)
        case file(URL)
        /// A Java or Kotlin package directory. The title may be a dotted name covering several folders.
        case package(URL)
        case symbol(EditorIntelligence.TextRange)
    }

    let id: String
    let title: String
    let target: Target
}

/// Folder path, filename and enclosing symbols for the active document. Empty when nothing is open.
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
    static let languageProvider = BundledLanguageProvider()

    let workbench = EditorWorkbench()
    let workspaceBridge = PenumbraWorkbenchWorkspaceBridge()
    let hostCache = EditorHostCache<UUID, IDEEditorPaneHost>(maxEntries: 16)
    /// Each diff tab's session, by its document's id (see `IDEWorkspace+Diff.swift`).
    @ObservationIgnored
    var diffSessions: [UUID: IDEDiffSession] = [:]
    /// Three-way merge tabs (a diff-kind document whose viewer is `IDEMergeViewerView`), by document.
    var mergeSessions: [UUID: IDEMergeSession] = [:]
    /// Each hex tab's session, by its document's id (see `IDEWorkspace+Hex.swift`).
    @ObservationIgnored
    var hexSessions: [UUID: IDEHexSession] = [:]
    /// Temporary `Inject language…` highlights, cleared when the document closes. Owned by
    /// `IDEIntelligenceServices` (which also feeds the ⌥↩ provider); providers are cached per
    /// document here so mode reconstructions keep feeding the same instance.
    var manualInjectionStore: IDEManualInjectionStore { intelligenceServices.manualInjectionStore }
    @ObservationIgnored
    var manualInjectionProviders: [UUID: IDEManualInjectionProvider] = [:]

    /// Per-document temporary-injection provider, stable across mode reconstructions.
    func manualInjectionProvider(for document: WorkbenchDocument) -> IDEManualInjectionProvider {
        if let provider = manualInjectionProviders[document.id] {
            return provider
        }
        let provider = IDEManualInjectionProvider(
            store: manualInjectionStore,
            key: IDEManualInjectionStore.key(url: document.url, displayName: document.displayName))
        manualInjectionProviders[document.id] = provider
        return provider
    }
    /// Paths opened as hex because the first 8 KB did not look like text. Consumed when the session starts.
    @ObservationIgnored
    var hexSniffedPaths: Set<String> = []
    var diagramSessions: [UUID: IDEDiagramSession] = [:]
    /// One per open Flight Recorder profile tab, by document id.
    var profileSessions: [UUID: IDEProfilerSession] = [:]
    /// Line costs of the profile being looked at, shown in the Java editors beside the code.
    let profileHints = IDEProfileLineHints()
    /// The profile tab that feeds ``profileHints``.
    weak var profileHintsSession: IDEProfilerSession?
    private let intelligenceServices = IDEIntelligenceServices()
    /// External language servers. Stopped in ``teardown()`` so a running server does not keep the window.
    let languageServerHost = IDELanguageServerHost()
    private let navigationBuffers = NavigationBufferBridge()
    private var adapter: PenumbraWorkbenchEditorAdapter!
    @ObservationIgnored
    var paletteController: CommandPaletteController?
    @ObservationIgnored
    private weak var paletteOverlayContainer: NSView?
    @ObservationIgnored
    private var hostedPaneIDs: Set<UUID> = []
    /// Ranged edits an editor reported since its last `textViewDidChange`, kept only while another
    /// pane shows the same document so they can be replayed there.
    @ObservationIgnored private var pendingMirrorChanges: [ObjectIdentifier: [TextContentChange]] = [:]
    /// Idle unambiguous-import insertion. A keystroke only cancels this; the buffer is read after the pause.
    @ObservationIgnored private let javaAutoImport = Debouncer()
    /// Set while the import edit itself is applied, so that edit does not schedule another pass.
    @ObservationIgnored private var javaAutoImportApplying = false
    /// The pasted text of the edit that is about to be reported, when it matches the pasteboard.
    @ObservationIgnored private var javaAutoImportPaste: String?
    @ObservationIgnored var hasPresentedMetalFailure = false
    /// The recent lists are shared by every window (`IDEAppState`), so what one window opens shows
    /// in all of them.
    private var appState: IDEAppState { IDEAppState.shared }
    private var recentFiles: [URL] {
        get { appState.recentFiles }
        set { appState.recentFiles = newValue }
    }
    /// Files edited in the editor, most recent first: the ⌘E "Show edited only" list (IntelliJ's
    /// recently edited files, not git's).
    private var recentlyEditedFiles: [URL] {
        get { appState.recentlyEditedFiles }
        set { appState.recentlyEditedFiles = newValue }
    }
    private var recentProjects: [URL] {
        get { appState.recentProjects }
        set { appState.recentProjects = newValue }
    }

    public let preferences = IDEPreferences.shared
    /// Which inspection profile this window analyses with (the project's own or a global one).
    let inspections = IDEWorkspaceInspections()
    /// Inspect Code results and which Problems tab shows.
    let inspectionRuns = IDEInspectionRunsStore()
    let project = IDEProjectModel()
    /// The Explorer's External Libraries section: the JDK and the project's dependency jars.
    let externalLibraries = IDEExternalLibrariesModel()
    let gitStatus = IDEGitStatusModel()
    /// Git blame in the editor gutter, per file.
    let blame = IDEBlameController()
    /// Lines that differ from `HEAD`, in the gutter next to the line numbers.
    let changeMarkers = IDEChangeMarkerController()
    let problems = IDEProblemsStore()
    /// The bell's list and the toast that announces finished Gradle and git work.
    let notifications = IDENotificationCenter()
    /// This window's coding agent. Reaches the window only through `IDEAgentHost`, weakly.
    let agent = IDEAgentController(
        store: IDEWorkspace.isSessionPersistenceEnabled ? IDEAgentController.appStore() : nil,
        appPermissionsFile: IDEWorkspace.isSessionPersistenceEnabled ? IDEAgentPermissionFiles.appFile() : nil,
        commandsHome: IDEWorkspace.isSessionPersistenceEnabled ? FileManager.default.homeDirectoryForCurrentUser : nil,
        commandsAppSupport: IDEWorkspace.isSessionPersistenceEnabled ? IDEAgentPermissionFiles.appFile()?.deletingLastPathComponent() : nil)
    /// AI mode's plain chats (no project), and the list of every project's saved Code sessions.
    /// A `var` so tests can give the window a chat controller that talks to a scripted client.
    var aiChat = IDEAIChatController(store: IDEWorkspace.isSessionPersistenceEnabled ? IDEAIChatController.appStore() : nil)
    let aiSessions = IDEAISessions(store: IDEWorkspace.isSessionPersistenceEnabled ? IDEAgentController.appStore() : nil)
    /// The Manage Models sheet of AI mode.
    var isAIModelsPresented = false
    /// The guided "Set up a model" sheet of AI mode, for the tab that asked.
    var aiModelSetup: IDEAITab?
    /// Set once the sheet has opened on its own, so it never opens by itself twice in a window.
    var hasOfferedAIModelSetup = false
    /// The Type Hierarchy tab's content; empty until ⌃H (or Java > Type Hierarchy) asks for one.
    let typeHierarchy = IDETypeHierarchyStore()
    /// Hierarchies kept with Pin Tab, and which one the tab shows (nil: the live one).
    var pinnedTypeHierarchies: [IDEPinnedHierarchy<IDETypeHierarchyStore>] = []
    var selectedTypeHierarchyPinID: UUID?
    /// The Structure tool window's member tree for the type at the caret.
    let structureStore = IDEStructureStore()
    let callHierarchy = IDECallHierarchyStore()
    var pinnedCallHierarchies: [IDEPinnedHierarchy<IDECallHierarchyStore>] = []
    var selectedCallHierarchyPinID: UUID?
    let debugSession = JavaDebugSession()
    /// Swift debugging through `lldb-dap`. The Debug tool window shows this while it is active.
    let dapDebugSession = DAPDebugSession()
    /// The Usages tab's content (Find Usages results); empty until a search runs.
    let usages = IDEUsagesStore()
    /// The Test Results tab's content; empty until a test run finishes.
    let testResults = IDETestResultsStore()
    /// What the last Run with Coverage measured: the report, which files it can still colour.
    let coverage = IDECoverageController()
    /// The programs Run started, shown in the Run tab of the bottom panel.
    let runs = IDERunSessions()
    /// Bumped by the Run tab's "Scroll to End" so the console jumps to the bottom.
    var runScrollToEndRequest = 0
    /// Umbra's one file-watching engine for this window; everything that reacts to disk changes
    /// subscribes to its batches.
    let projectWatcher = IDEProjectWatcher()
    /// Open text buffers against their files: reload, banner, save conflicts.
    let diskSync = IDEOpenDocumentDiskSync()
    /// Asks what to do when a save would write over a newer file. Tests replace it.
    @ObservationIgnored var saveConflictResolver: @MainActor (WorkbenchDocument) -> SaveConflictChoice = IDEWorkspace.askAboutSaveConflict
    /// Asks what to do with a buffer that closing its tab could not save. Tests replace it.
    /// Saves the unsaved files once typing pauses (Settings ▸ Saving).
    @ObservationIgnored let autosave = IDEAutosaveController()
    /// Files autosave could not write and already said so about, until they save again.
    @ObservationIgnored var autosaveReportedFailures: Set<String> = []
    /// A Build Project waiting for the saves of the last second (Settings ▸ Saving).
    @ObservationIgnored var buildOnSaveTask: Task<Void, Never>?
    @ObservationIgnored var closePromptResolver: @MainActor (WorkbenchDocument, IDEClosePrompt) -> IDEClosePromptChoice = IDEWorkspace.askAboutClosing
    /// Asks before File ▸ Close Folder throws away unsaved editors. Tests replace it.
    @ObservationIgnored var folderCloseResolver: @MainActor (String) -> IDEFolderCloseChoice = IDEWorkspace.askAboutClosingFolder
    @ObservationIgnored
    private let fileIndexer = IDEPaletteFileIndexer()
    /// Revisions of the project's files: saves, opens, agent writes.
    let localHistory = IDELocalHistoryRecorder()
    /// The project's files as Go to File sees them; the agent's `@` list uses it too.
    var paletteFileIndex: PaletteFileIndex { fileIndexer.index }

    var javaSupport: IDEJavaSupport { intelligenceServices.javaSupport }
    /// The window's project systems: what recognizes the open folder, syncs it and runs its tasks.
    var projectSystems: IDEProjectSystems { intelligenceServices.projectSystems }
    /// Gradle. The Java run and test code asks it for the synced model; everything generic asks
    /// `projectSystems`.
    var gradle: IDEGradleProjectSystem { intelligenceServices.gradle }
    /// Maven, registered after Gradle. A folder with both keeps Gradle.
    var maven: IDEMavenProjectSystem { intelligenceServices.maven }
    /// npm, registered after Maven. A folder with Gradle or Maven keeps those as `projectSystems.active`.
    var npm: IDENpmProjectSystem { intelligenceServices.npm }
    /// SwiftPM, registered after npm.
    var swiftPM: IDESwiftPMProjectSystem { intelligenceServices.swiftPM }
    /// Xcode projects, registered after SwiftPM.
    var xcode: IDEXcodeProjectSystem { intelligenceServices.xcode }
    /// The window's TypeScript index. The symbol palette reads it; the language service holds it weakly.
    var typescriptSupport: IDETypeScriptSupport { intelligenceServices.typescriptSupport }
    /// The window's Swift index. The symbol palette and the SwiftPM project system use it.
    var swiftSupport: IDESwiftSupport { intelligenceServices.swiftSupport }
    /// Where SourceKit-LSP's client appears once the host has started it for a trusted folder.
    var sourceKitConnection: LSPConnectionBox { intelligenceServices.sourceKitConnection }
    /// The run providers language modules contributed, one per window, made on first use.
    var runProviders: IDERunProviders {
        if let runProvidersStorage { return runProvidersStorage }
        let providers = IDERunProviders(IDELanguageModules.all.compactMap { $0.makeRunProvider(for: self) })
        runProvidersStorage = providers
        return providers
    }
    @ObservationIgnored private var runProvidersStorage: IDERunProviders?
    /// Java's Run and Test. The debugger is Java-only and asks it for the launch, the classpath and
    /// the JDK; everything generic goes through `runProviders`.
    var javaRun: IDEJavaRunProvider {
        guard let provider = runProviders.provider(IDEJavaRunProvider.self) else {
            preconditionFailure("The Java module contributes the Java run provider")
        }
        return provider
    }
    /// The provider for the language of the active document, if its language has one.
    var activeRunProvider: (any IDERunProvider)? {
        runProviders.provider(forLanguage: workbench.activePane.selectedDocument?.languageIdentifier)
    }
    /// The active document as run providers read it. Its text is copied only if a provider asks.
    func activeRunDocument() -> IDERunDocument? {
        guard let document = workbench.activePane.selectedDocument else { return nil }
        let paneID = workbench.activePaneID
        let textView = host(for: paneID).textView
        return IDERunDocument(
            url: document.url, languageIdentifier: document.languageIdentifier,
            caretUTF16Offset: textView.selectedRange.location, text: textView.text
        )
    }
    /// The status card's background line ("Indexing JDK 24…", "Resolving Gradle project…").
    var projectStatus: IDEProjectStatus { intelligenceServices.projectStatus }
    var indexActivity: IDEIndexActivity { intelligenceServices.indexActivity }
    /// Every language's intelligence, routed by the active document's language.
    var languages: LanguageServiceRegistry { intelligenceServices.languages }
    var navigationEngine: NavigationEngine { intelligenceServices.navigationEngine }

    /// The window this workspace is shown in, set by `IDEWindowConfiguratorView`. Sheets, alerts and
    /// first-responder changes target this window, not whichever one happens to be key.
    @ObservationIgnored
    weak var window: NSWindow?

    /// Names this window to `IDEOpenRouter` and the registry.
    let windowID = UUID()

    /// Off in tests that create workspaces, so they neither restore nor overwrite the developer's
    /// real `last-window.json` and `app.json`.
    static var isSessionPersistenceEnabled = true

    /// A weak handle for the menu bar; see `IDEWorkspaceRef`.
    let reference = IDEWorkspaceRef()

    /// Opened blank next to other windows instead of restoring the last one.
    @ObservationIgnored
    private var startedAsExtraWindow = false

    /// The project folder's name, or "Umbra": what tells this window apart in the Window menu and
    /// in the native tab bar.
    private var projectTitle: String {
        project.rootURL?.lastPathComponent ?? "Umbra"
    }

    /// No project and no documents: the Welcome screen.
    var isEmpty: Bool {
        !hasOpenProject && !hasOpenDocuments
    }

    /// A blank window opened next to others that has not been used: it never becomes the window
    /// that is restored at the next launch.
    var isPristine: Bool {
        startedAsExtraWindow && isEmpty
    }

    /// Kept current by `IDEWindowConfiguratorView`; the toolbar row lays out differently around the
    /// native tab bar in full screen (see `IDEWindowChrome`).
    var isFullScreen = false


    public init() {
        reference.workspace = self
        if Self.isSessionPersistenceEnabled { localHistory.enable(baseDirectory: IDELocalHistoryRecorder.defaultDirectory()) }
        agent.attach(host: self)
        agent.onPanelRequested = { [weak self] in
            // Settings only has to make room when the chat is going to cover the same area.
            if self?.agent.settings.opensAsPage == true { self?.dismissSettingsForAgent() }
        }
        agent.onLayoutChanged = { [weak self] in self?.saveSession() }
        agent.isUserWatching = { [weak self] in self?.window?.isKeyWindow == true }
        agent.onNotify = { [weak self] chat, title, detail, severity in
            self?.notifications.post(title, detail: detail, category: .agent, severity: severity, action: .showAgentChat(chat))
        }
        agent.onOpenSettings = { [weak self] in
            self?.requestedSettingsDomain = .agent
            self?.showSettings()
        }
        gitStatus.saveUnsavedEditors = { [weak self] in
            await self?.saveUnsavedEditorsInRepository() ?? []
        }
        gitStatus.hasUnsavedEditors = { [weak self] in
            self?.hasUnsavedEditorsInRepository() ?? false
        }
        gitStatus.onWorkingTreeChanged = { [weak self] in
            self?.reloadOpenEditorsAfterGitChange()
        }
        gitStatus.onShowComparison = { [weak self] in
            self?.showBottomTab(.sourceControl)
        }
        gitStatus.onRefreshed = { [weak self] in
            self?.refreshBlameInOpenEditors()
            self?.reloadDiffSessions()
            self?.changeMarkers.invalidateHeadCache()
            self?.refreshChangedLinesInOpenEditors(force: true, delay: .zero)
        }
    }

    var isSidebarVisible = false
    /// The left sidebar's tab. Read `activeSidebarTab`: this may name a tab that is unavailable now.
    var selectedSidebarTab = IDESidebarTab.explorer
    /// What the History tab lists: the active file, one folder, or every file's recent changes.
    var localHistoryScope = IDELocalHistoryScope.file
    /// A file to show instead of whichever editor is active. Cleared when the user picks This File or Recent Changes.
    var localHistoryFile: String?
    /// Tabs the user closed with ×; the sidebar's + menu brings them back.
    private(set) var closedSidebarTabs: Set<IDESidebarTab> = []
    /// The project's breakpoints, mirrored from `breakpointStore` (which is not observable) for the
    /// Breakpoints tab. Refreshed by `refreshBreakpoints()` after every change to the store.
    var breakpoints: [JavaBreakpoint] = []
    /// Mute Breakpoints: every breakpoint stays, none stops. Mirrors the store, per project.
    var breakpointsMuted = false
    /// The breakpoint the Breakpoints tab shows in its detail pane.
    var selectedBreakpointID: UUID?
    /// Expressions the Debug tab re-evaluates at every stop, per project (UserDefaults).
    var watches: [String] = []
    /// The Frames pane hides JDK frames when set.
    var hideLibraryFrames = false
    @ObservationIgnored let breakpointPopover = IDEBreakpointPopover()
    @ObservationIgnored let quickEvaluatePopover = IDEQuickEvaluatePopover()
    @ObservationIgnored var streamTraceWindow: IDEStreamTraceWindowController?
    var isProjectSidebarVisible = true
    /// The explorer sidebar's width. `IDERootView` owns the drag and mirrors it here so a save made
    /// from anywhere (`saveSession()`) writes the width on screen, not the default.
    var sidebarWidth = IDEAppearance.Spacing.sidebarWidth
    var projectSidebarWidth = IDEAppearance.Spacing.sidebarWidth
    /// The docked agent panel's width, kept with the window session.
    var agentPanelWidth = IDEAppearance.Spacing.agentPanelWidth
    var chromeOpacity = 1.0
    private(set) var layoutEpoch: UInt64 = 0
    /// Bumped when the shell UI color scheme changes so chrome views pick up new tokens.
    private(set) var uiColorSchemeEpoch: UInt64 = 0
    private(set) var activePaneID = UUID()
    /// Mirrors whether any document is open. `hasOpenDocuments` reads the workbench, which is
    /// not observable, so this stored flag is what refreshes the welcome-vs-editor switch.
    private(set) var showsWelcome = true
    var showsFirstRunGuide = false
    /// Settings open over the editor area, like a tab, instead of in their own window. The editor
    /// underneath stays mounted so its carets and scroll positions survive.
    private(set) var isSettingsVisible = false
    /// Editor, or AI mode over the whole window. The editor stays mounted underneath AI mode.
    var windowMode: IDEWindowMode = .editor {
        didSet { if oldValue != windowMode { noteAIModeChanged() } }
    }
    /// Which half of AI mode shows.
    var aiTab: IDEAITab = .code {
        didSet { if oldValue != aiTab { noteAIModeChanged() } }
    }
    /// Whether AI mode's list of chats is shown.
    var showsAISidebar = true
    /// Whether the Changes / Plan / Browser panel shows to the right of Code's conversation, and which tab.
    var showsAIInspector = false {
        didSet { if oldValue != showsAIInspector { noteAIModeChanged() } }
    }
    var aiInspectorTab: IDEAIInspectorTab = .changes {
        didSet { if oldValue != aiInspectorTab { noteAIModeChanged() } }
    }
    /// The panel's width; `IDERootView` owns the drag and mirrors it here, like `agentPanelWidth`.
    var aiInspectorWidth = IDEAIInspector.defaultWidth
    /// What the Changes tab has worked out per file (diffs are computed off the main actor and kept here).
    @ObservationIgnored let aiChanges = IDEAIChangesModel()
    /// The Browser tab's page, created when the tab first shows and dropped in `teardown()`. Observed, so
    /// the tab redraws once `ensureAIBrowser()` has made it.
    var aiBrowser: IDEAIBrowserModel?
    /// The Browser tab's address, readable from anywhere before the page object exists.
    @ObservationIgnored let aiBrowserPageInfo = IDEAIBrowserPageInfo()
    /// Settings were opened from AI mode, so closing them goes back there rather than to the editor.
    private var returnsToAIModeFromSettings = false
    /// Set while a saved window comes back, which is not a change worth saving.
    private var isRestoringAIMode = false
    /// What to do in AI mode once the folder being opened here is the project; see `applyAIOpen`.
    var pendingAIOpen: IDEAIOpenRequest?

    private func noteAIModeChanged() {
        guard !isRestoringAIMode else { return }
        saveSession()
    }

    /// A pane Settings should open on, set by whatever sent the user there; the settings view takes it.
    var requestedSettingsDomain: IDEPreferencesDomain?
    /// The intention Settings › Java › Intentions should scroll to, set by Edit intention settings.
    var focusedIntentionID: String?

    func showSettings() {
        guard !isSettingsVisible else { return }
        // Settings belong to the editor's side of the window; closing them returns to AI mode.
        returnsToAIModeFromSettings = windowMode == .ai
        if returnsToAIModeFromSettings { windowMode = .editor }
        isBottomPanelExpanded = false
        agent.dismissPage()
        isSettingsVisible = true
        // Otherwise keystrokes keep going to the editor hidden under the settings.
        window?.makeFirstResponder(nil)
    }

    /// AI mode covers the window: Settings and an expanded bottom panel belong to the editor, and
    /// keystrokes must not keep going to a text view that is no longer on screen.
    func prepareForAIMode() {
        isSettingsVisible = false
        returnsToAIModeFromSettings = false
        isBottomPanelExpanded = false
        window?.makeFirstResponder(nil)
    }

    /// The chat page takes the place Settings has; opening it closes Settings without moving focus.
    func dismissSettingsForAgent() {
        isSettingsVisible = false
    }

    func hideSettings() {
        guard isSettingsVisible else { return }
        isSettingsVisible = false
        if returnsToAIModeFromSettings {
            showAIMode()
            return
        }
        focusActiveEditor()
    }

    var windowTitle = "Umbra"
    var headerContext = IDEHeaderContext()
    /// Standardized paths of the open files with unsaved changes (Mark Modified in the Explorer).
    var unsavedPaths: Set<String> = []
    var statusLine = 1
    var statusColumn = 1
    var statusLanguage = ""
    /// The active text document's file encoding, shown (and changed) from the status bar.
    var statusEncoding = TextFileEncoding.utf8
    /// True when the active editor is a Java file with `public static void main` (either modifier
    /// order) and there is something to launch: the file itself, or a Gradle `run` task.
    var runFileCanRun = false
    /// True when the active editor is a Java test source file with discovered tests.
    var javaFileCanTest = false
    var runFileURL: URL?
    var activeJavaTestClass: JavaTestClass?
    /// Semantic colours, gutter markers and the name-index overlay painted over the editors.
    @ObservationIgnored private let overlays = IDEEditorOverlayController()
    /// The Java markers shown in each text view, with the buffer generation they were computed
    /// for; a click maps the engine marker's `id` back to its index here.
    /// The language the Type and Call Hierarchy tabs were last asked for (their items belong to it).
    @ObservationIgnored let javaRunAvailability = Debouncer()
    @ObservationIgnored private var structureRefreshTask: Task<Void, Never>?
    /// The last configuration Run launched in this project, restored across launches. Run Last
    /// Configuration reruns it, whatever file is active.
    var lastRunConfiguration: JavaRunConfiguration?
    /// Every run configuration of the project, for the toolbar picker.
    var runConfigurations: [JavaRunConfiguration] = []
    /// Bumped by Stop. A debug launch that is still building notices and gives up.
    @ObservationIgnored var launchEpoch = 0
    var gradleDebugActive = false
    /// The working copy behind the Edit Configurations dialog; the dialog shows while it is set.
    var runConfigurationsEditor: IDERunConfigurationsEditor?
    /// The configuration the Edit Configurations dialog is open on. Setting one opens the dialog
    /// on it (a gutter's Modify Run Configuration…, a launch that needs fixing); `nil` closes it.
    var runConfigurationDraft: JavaRunConfiguration? {
        get {
            guard let editor = runConfigurationsEditor, let id = editor.selectedConfigurationID else { return nil }
            return editor.configurations.first { $0.id == id }
        }
        set { runConfigurationsEditor = newValue.map { makeRunConfigurationsEditor(highlighting: $0) } }
    }
    /// Run or Debug was pressed in a Gradle module with neither `run` nor `bootRun`: the task
    /// picker shows while set.
    var gradleRunTaskPrompt: IDEGradleRunTaskPrompt?
    /// File ▸ New Project… is showing its sheet.
    var isNewProjectSheetPresented = false
    /// The workspace edit being previewed (rename, extract variable, …).
    var workspaceEditPreview: IDEWorkspaceEditPreviewModel?
    /// The JWT being read (Tools ▸ Encode / Decode ▸ Decode JWT…): its sheet shows while set.
    var jwtDecoding: IDEJWTDecoding?
    var renamePreview: IDEWorkspaceEditPreviewModel? {
        get { workspaceEditPreview }
        set { workspaceEditPreview = newValue }
    }
    @ObservationIgnored private let renamePrompt = IDERenamePrompt()
    @ObservationIgnored private let refactoringNamePrompt = IDERefactoringNamePrompt()
    @ObservationIgnored private let changeSignaturePrompt = IDEChangeSignaturePrompt()
    @ObservationIgnored private let swiftSignaturePrompt = IDESwiftSignaturePrompt()
    @ObservationIgnored private let generatePrompt = IDEGeneratePrompt()
    /// The app's shared stores (see `IDESharedServices`): every window reads and writes the same
    /// instances, so one window's change is neither lost nor missed by another.
    /// Replaceable so a test does not write to the real store.
    @ObservationIgnored var runConfigurationStore = IDESharedServices.shared.runConfigurations
    let breakpointStore = IDESharedServices.shared.breakpoints
    let bookmarkStore = IDESharedServices.shared.bookmarks
    /// The project's bookmarks and bookmark lists, mirrored from `bookmarkStore` (which is not
    /// observable) for the Bookmarks tab. Refreshed by `refreshBookmarks()` after every change.
    var bookmarks: [IDEBookmark] = []
    var bookmarkLists: [IDEBookmarkList] = []
    var defaultBookmarkListID: UUID?
    /// True when the active editor is an HTTP request file with a parsable request at the caret.
    var httpFileCanSend = false
    /// What the HTTP gutter's send buttons were last built for, so a caret move alone doesn't re-parse.
    struct HTTPGutterStamp: Equatable {
        let view: ObjectIdentifier
        let documentID: UUID?
        let generation: UInt64
    }
    @ObservationIgnored var httpGutterStamp: HTTPGutterStamp?
    struct DatabaseGutterStamp: Equatable {
        let view: ObjectIdentifier
        let documentID: UUID?
        let generation: UInt64
    }
    @ObservationIgnored var databaseGutterStamp: DatabaseGutterStamp?
    /// The `main` methods last found in a text view's buffer, so a caret move doesn't parse the
    /// file again for the gutter's run buttons.
    struct JavaMainLocations {
        let view: ObjectIdentifier
        let generation: UInt64
        let locations: [JavaMainMethodLocation]
    }
    @ObservationIgnored var javaMainLocations: JavaMainLocations?
    let httpSupport = IDEHTTPSupport()
    /// Connections, schema and query results for this window. The connection list is shared.
    let databaseSupport = IDEDatabaseSupport()
    var isMarkdownPreviewVisible = false
    /// The SwiftUI canvas is docked beside the editor (`IDEWorkspace+SwiftUIPreview.swift`).
    var isSwiftUIPreviewVisible = false
    var swiftUIPreview: IDESwiftUIPreviewSession?
    /// The document the canvas was last asked to show, so a tab switch is told from any other change.
    @ObservationIgnored var swiftUIPreviewDocumentID: UUID?
    @ObservationIgnored var swiftUIPreviewSwitchTask: Task<Void, Never>?
    var isJSONDiagramVisible = false
    var isCSVTableVisible = false
    var statusSelectionLength = 0
    var tabsByPane: [UUID: [IDETabRow]] = [:]
    /// Standardized paths of every open document, so the Explorer can mark files open in a tab.
    private(set) var openDocumentPaths: Set<String> = []
    @ObservationIgnored private var lastAutoRevealedDocumentID: UUID?
    /// The Find and Replace in Files drawer (query, scope, hits); the search itself is in `IDEWorkspace+FindInFiles.swift`.
    let findInFiles = IDEFindInFilesModel()
    /// The bottom panel: visibility, size, selected tab and the shell tabs (`IDEBottomPanelModel`). The
    /// properties below read through to it, so views and the session code keep their names.
    let bottomPanel = IDEBottomPanelModel()
    var isTerminalVisible: Bool {
        get { bottomPanel.isVisible }
        set { bottomPanel.isVisible = newValue }
    }
    private(set) var isBottomPanelExpanded: Bool {
        get { bottomPanel.isExpanded }
        set { bottomPanel.isExpanded = newValue }
    }
    var terminalHeight: Double {
        get { bottomPanel.height }
        set { bottomPanel.height = newValue }
    }
    var terminalFocusRequestID: UInt64 {
        get { bottomPanel.focusRequestID }
        set { bottomPanel.focusRequestID = newValue }
    }
    var terminalTabs: [IDETerminalTab] {
        get { bottomPanel.tabs }
        set { bottomPanel.tabs = newValue }
    }
    var selectedTerminalTabID: UUID? {
        get { bottomPanel.selectedTabID }
        set { bottomPanel.selectedTabID = newValue }
    }
    /// Which tab the bottom panel is showing. Not persisted in the session -- each launch starts on
    /// a shell (or no terminal at all).
    var selectedBottomTab: IDEBottomPanelTab {
        get { bottomPanel.selectedTab }
        set { bottomPanel.selectedTab = newValue }
    }
    /// The Run tab appears with the first program Run starts, and stays while any console is kept.
    var showsRunTab: Bool { runs.hasContent }
    /// The Type Hierarchy tab appears once a hierarchy (or a message about why there is none) has
    /// been requested, and goes when it is closed.
    var showsTypeHierarchyTab: Bool { typeHierarchy.hasContent || !pinnedTypeHierarchies.isEmpty }
    var showsCallHierarchyTab: Bool { callHierarchy.hasContent || !pinnedCallHierarchies.isEmpty }
    /// What the Type Hierarchy tab shows: the pinned hierarchy that is selected, else the live one.
    var visibleTypeHierarchy: IDETypeHierarchyStore {
        pinnedTypeHierarchies.first { $0.id == selectedTypeHierarchyPinID }?.store ?? typeHierarchy
    }
    var visibleCallHierarchy: IDECallHierarchyStore {
        pinnedCallHierarchies.first { $0.id == selectedCallHierarchyPinID }?.store ?? callHierarchy
    }
    var showsDebugTab: Bool {
        switch debugSession.state {
        case .idle: return false
        default: return true
        }
    }
    var showsUsagesTab: Bool { usages.hasContent }
    var showsTestResultsTab: Bool { testResults.hasContent }
    /// True when a terminal tab (rather than one of the read-only tabs) is showing.
    var isTerminalTabSelected: Bool { bottomPanel.isShellSelected }

    /// Whether `tab` is the bottom panel's selected tab (the stripe and the strip read this).
    func isBottomTabSelected(_ tab: IDEBottomPanelTab) -> Bool {
        selectedBottomTab == tab
    }

    /// Selects `tab` and reveals the bottom panel. Every tab, built in or contributed by a language
    /// module, is shown this way.
    func showBottomTab(_ tab: IDEBottomPanelTab) {
        selectedBottomTab = tab
        if !isTerminalVisible {
            isTerminalVisible = true
            saveSession()
        }
        if tab == .sourceControl {
            gitStatus.refresh()
        }
    }

    /// Takes `tab` out of the selection (it closed): back to the shell if it was the selected one.
    func deselectBottomTab(_ tab: IDEBottomPanelTab) {
        if selectedBottomTab == tab {
            selectedBottomTab = .terminal
        }
    }

    /// Whether the "Gradle" tab should appear at all: while a sync is running, or once one has
    /// produced output worth revisiting.
    var showsGradleConsoleTab: Bool {
        gradle.showsConsole
    }
    /// Whether the "Maven" tab should appear: while a read or a goal is running, or once one has
    /// produced output worth revisiting.
    var showsMavenConsoleTab: Bool {
        maven.showsConsole
    }
    /// Whether the "HTTP" tab should appear for the active `.http` file or after a request runs.
    var showsHTTPTab: Bool {
        statusLanguage == "http" || httpSupport.isSending || !httpSupport.responseLog.lines.isEmpty
    }
    /// The Problems tab is always offered; it shows an empty state when there is nothing to report.
    var showsProblemsTab: Bool { true }
    /// Whether the "Source Control" tab should appear for the open git repository.
    var showsSourceControlTab: Bool {
        gitStatus.isRepository
    }

    var editorLayout: EditorLayout { workbench.layout }
    var hasOpenDocuments: Bool { !workbench.allDocuments().isEmpty }
    var hasOpenProject: Bool { project.rootURL != nil }
    /// Whether the active document's syntax can be changed from the status bar or View > Syntax.
    var canChangeActiveLanguage: Bool {
        guard let document = workbench.activePane.selectedDocument else { return false }
        return !IDELanguageSupport.isLanguageLocked(for: document)
    }
    /// Whether the active tab is a text document, whose encoding the status bar can change.
    var canChangeActiveEncoding: Bool {
        guard let document = workbench.activePane.selectedDocument else { return false }
        return document.contentKind == .text
    }
    /// Whether the active text document has a file to decode again (an untitled buffer has not).
    var canReopenActiveWithEncoding: Bool {
        guard let document = workbench.activePane.selectedDocument else { return false }
        return document.contentKind == .text && document.url != nil
    }
    /// What `IDERootView` should actually render: the user's sidebar toggle, once a folder or a
    /// document is open (the stripe offers no Explorer button before that).
    var showsSidebar: Bool { isSidebarVisible && (hasOpenProject || hasOpenDocuments) }
    /// A tab is offered when it has something to show: Changes needs a git repository. Structure
    /// stays offered for any file (it explains itself outside Java) so the tab does not come and
    /// go as the active file changes.
    func isSidebarTabAvailable(_ tab: IDESidebarTab) -> Bool {
        IDESidebarTabs.descriptor(for: tab)?.isAvailable(self) ?? false
    }

    /// The tabs the sidebar's tab bar shows, in order.
    var sidebarTabs: [IDESidebarTab] {
        IDESidebarTabs.all.map(\.tab).filter { isSidebarTabAvailable($0) && !closedSidebarTabs.contains($0) }
    }

    /// Closed tabs the + menu can bring back.
    var reopenableSidebarTabs: [IDESidebarTab] {
        IDESidebarTabs.all.map(\.tab).filter { isSidebarTabAvailable($0) && closedSidebarTabs.contains($0) }
    }

    /// The tab the sidebar is actually showing: the selected one, or the Explorer when that tab is
    /// closed or gone (the repository was removed).
    var activeSidebarTab: IDESidebarTab {
        sidebarTabs.contains(selectedSidebarTab) ? selectedSidebarTab : .explorer
    }

    /// Left-hand Structure tab — members of the Java type at the caret.
    var showsStructureSidebar: Bool { showsSidebar && activeSidebarTab == .structure }
    /// Right-hand Gradle panel — modules and dependencies — only for Gradle project folders.
    var showsProjectSidebar: Bool { isProjectSidebarVisible && projectSystems.active != nil }

    func host(for paneID: UUID) -> IDEEditorPaneHost {
        hostedPaneIDs.insert(paneID)
        return hostCache.host(for: paneID) {
            makeHost(paneID: paneID)
        }
    }

    func focusActiveEditor() {
        let host = host(for: workbench.activePaneID)
        if workbench.activePane.selectedDocument?.contentKind == .binary {
            host.hexViewer.focus()
            return
        }
        if workbench.activePane.selectedDocument?.contentKind == .diff {
            host.diffViewer.focus()
            return
        }
        if workbench.activePane.selectedDocument?.contentKind == .diagram || host.isJSONDiagramVisible {
            host.diagramViewer.focus()
            return
        }
        if workbench.activePane.selectedDocument?.contentKind == .profile {
            host.profileViewer.focus()
            return
        }
        if host.isCSVTableVisible {
            host.csvTableView.focus()
            return
        }
        host.textView.focusTextInputWhenReady()
    }

    /// Used when ⌘Z / ⌘⇧Z is not delivered to the focused control (a SwiftUI host with no
    /// `undo:` implementation). The editor's own undo manager is the stack those shortcuts edit.
    func undoActiveEditor() {
        if workbench.activePane.selectedDocument?.contentKind == .binary {
            activeHexSession()?.undo()
            return
        }
        activeEditingTextView.undoManager?.undo()
    }

    func redoActiveEditor() {
        if workbench.activePane.selectedDocument?.contentKind == .binary {
            activeHexSession()?.redo()
            return
        }
        activeEditingTextView.undoManager?.redo()
    }

    /// The text view keyboard edits go to: a diff tab's working-tree side, else the pane's editor.
    private var activeEditingTextView: TextView {
        let host = host(for: workbench.activePaneID)
        return workbench.activePane.selectedDocument?.contentKind == .diff ? host.diffViewer.editingTextView : host.textView
    }

    func bootstrap() {
        // The blame column and the profiler's line hints share the annotation column; a file with
        // hints is theirs until the user turns them off.
        blame.yieldsAnnotations = { [weak self] url in self?.profileHintsOwnAnnotations(of: url) ?? false }
        inspections.onChange = { [weak self] in self?.javaInspectionPreferencesChanged() }
        gitStatus.codeAnalysisProvider = { [weak self] files in await self?.analyzeForCommit(files) }
        applyLaunchConfiguration()
        configureDiskSync()
        subscribeToProjectWatcher()
        configureDebugSession()
        problems.onShowTestResults = { [weak self] in
            self?.showBottomTab(.testResults)
        }
        intelligenceServices.markdownFileMentions.setSource { [weak self] query, limit in
            await MainActor.run { self?.agentFileSuggestions(query: query, limit: limit) ?? [] }
        }
        databaseSupport.sqlCompletionProvider = intelligenceServices.sqlCompletion
        let httpGlobals = httpSupport.globals
        intelligenceServices.httpCompletion.setGlobals { httpGlobals.snapshot() }
        intelligenceServices.httpCompletion.setSchemaStore(httpSupport.graphQLSchemas)
        intelligenceServices.httpSchemaHover.configure(store: httpSupport.graphQLSchemas) { httpGlobals.snapshot() }
        projectSystems.start(environment: IDEProjectEnvironment(
            requestTrust: { [weak self] url in
                guard let self else { return false }
                return await self.promptGradleTrust(for: url)
            },
            syncFailed: { [weak self] in
                self?.showGradleOutput()
            },
            syncFinished: { [weak self] outcome in
                self?.notifyGradleSync(outcome)
            },
            tasksFinished: { [weak self] report in
                self?.runProviders.projectTasksDidFinish(report)
            },
            prepareToRun: { [weak self] in
                await self?.saveAllBeforeRun()
            }
        ))
        runs.beforeLaunch = { [weak self] in
            await self?.saveAllBeforeRun()
        }
        autosave.canSaveNow = { [weak self] in self?.canAutosaveNow ?? false }
        autosave.save = { [weak self] in await self?.autosaveAll(reason: .autosaveIdle) }
        autosave.settings = { [weak self] in
            guard let preferences = self?.preferences else { return .init(isEnabled: false) }
            return .init(isEnabled: preferences.saveWhenIdle, idleDelay: .seconds(preferences.idleSaveSeconds))
        }
        // Maven ignores `environment.requestTrust` too: that closure is worded for Gradle, and
        // reading a POM does not run Maven. Goals and downloads ask with Maven's own words.
        maven.trustPrompt = { [weak self] url in
            guard let self else { return false }
            let name = url.lastPathComponent
            return await self.promptProjectTrust(
                message: "Trust and run Maven for “\(name)”?",
                detail: "Maven plugins and goals can run arbitrary code. Trust this folder only if you trust its contents."
            )
        }
        maven.environment.syncFailed = { [weak self] in
            self?.showMavenOutput()
        }
        maven.environment.syncFinished = { [weak self] outcome in
            self?.notifyMavenSync(outcome)
        }
        maven.environment.tasksFinished = { [weak self] report in
            self?.runProviders.projectTasksDidFinish(report)
        }
        // npm ignores `environment.requestTrust`: that closure is worded for Gradle build scripts,
        // and agreeing to Gradle does not agree to npm.
        npm.trustPrompt = { [weak self] url in
            guard let self else { return false }
            let name = url.lastPathComponent
            return await self.promptProjectTrust(
                message: "Trust and run npm scripts for “\(name)”?",
                detail: "npm scripts can run arbitrary code. Trust this folder only if you trust its contents."
            )
        }
        npm.onActivity = { [weak self] in
            self?.showBottomTab(.npm)
        }
        // SwiftPM is the same: its own trust, its own words. Compiler problems go to Problems
        // under their own source, so a Gradle build does not replace them or the reverse.
        swiftPM.trustPrompt = { [weak self] url in
            guard let self else { return false }
            let name = url.lastPathComponent
            return await self.promptProjectTrust(
                message: "Trust and run SwiftPM for “\(name)”?",
                detail: "Package.swift and build plugins run code when SwiftPM evaluates or builds the package. "
                    + "Trust this folder only if you trust its contents."
            )
        }
        swiftPM.onActivity = { [weak self] in
            self?.showBottomTab(.swiftPM)
        }
        swiftPM.bufferText = { [weak self] url in self?.openBufferText(for: url) }
        swiftPM.onBuildDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            self.problems.setBuildDiagnostics(diagnostics, source: IDEProblemsStore.swiftPMBuildSource)
            if diagnostics.values.contains(where: { $0.contains { $0.severity == .error } }) {
                self.showProblems()
            }
        }
        // Xcode: its own trust (build phases run scripts) and its own Problems source.
        xcode.trustPrompt = { [weak self] url in
            guard let self else { return false }
            let name = url.lastPathComponent
            return await self.promptProjectTrust(
                message: "Trust and run xcodebuild for “\(name)”?",
                detail: "Build phases and build tool plugins can run scripts when xcodebuild builds the project. "
                    + "Trust this folder only if you trust its contents."
            )
        }
        xcode.onActivity = { [weak self] in
            self?.showBottomTab(.xcode)
        }
        xcode.bufferText = { [weak self] url in self?.openBufferText(for: url) }
        xcode.onBuildDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            self.problems.setBuildDiagnostics(diagnostics, source: IDEProblemsStore.xcodeBuildSource)
            if diagnostics.values.contains(where: { $0.contains { $0.severity == .error } }) {
                self.showProblems()
            }
        }
        languageServerHost.documentWorkspace = workspaceBridge.workspace
        languageServerHost.requestTrust = { [weak self] definition, url in
            guard let self, self.window != nil else { return false }
            let name = url.lastPathComponent
            return await self.promptProjectTrust(
                message: "Trust and run \(definition.configuration.name) for “\(name)”?",
                detail: "\(definition.configuration.name) is an external program. It can read this folder and run the project's tools. Trust this folder only if you trust its contents."
            )
        }
        swiftPM.onModelChanged = { [weak self] manifest, root in
            guard let self else { return }
            let resolver = manifest.flatMap { manifest in root.map { manifest.moduleResolver(root: $0) } }
            self.swiftSupport.setModuleResolver(resolver)
        }
        // A package's targets win when a folder has both a package and a project.
        xcode.onModelChanged = { [weak self] model, _ in
            guard let self, !self.swiftPM.isActive else { return }
            self.swiftSupport.setModuleResolver(model?.moduleResolver())
        }
        xcode.onDefinitionReloaded = { [weak self] in
            guard let self, let root = self.project.rootURL else { return }
            self.languageServerHost.projectDidChange(root: root, connections: self.intelligenceServices.languageServerConnections)
        }
        gitStatus.onActionReport = { [weak self] message, isFailure in
            self?.notifications.post(
                isFailure ? "Git action failed" : "Git",
                detail: message,
                category: .git,
                severity: isFailure ? .error : .success,
                action: .showSourceControl
            )
        }
        externalLibraries.jdkProvider = { [weak self] in
            guard let self, self.javaSupport.isJavaBuildActive else { return nil }
            return self.javaSupport.jdk.current?.installation
        }
        gradle.onModelChanged = { [weak self] _ in
            guard let self else { return }
            let model = self.javaSupport.projectModel
            self.fileIndexer.setGradleModel(model)
            self.refreshExternalLibraries()
            if model != nil { self.reloadDiagramSessions(classes: false) }
        }
        maven.onModelChanged = { [weak self] _ in
            guard let self else { return }
            let model = self.javaSupport.projectModel
            self.fileIndexer.setGradleModel(model)
            self.refreshExternalLibraries()
            if model != nil { self.reloadDiagramSessions(classes: false) }
        }
        intelligenceServices.javaSupport.openJavaDocuments = { [weak self] in
            self?.openJavaDocuments() ?? []
        }
        intelligenceServices.javaSupport.onCompilerDiagnostics = { [weak self] url, diagnostics in
            self?.applyCompilerDiagnostics(diagnostics, for: url)
        }
        intelligenceServices.javaSupport.onInspectionDiagnostics = { [weak self] url, diagnostics in
            self?.applyInspectionDiagnostics(diagnostics, for: url)
        }
        intelligenceServices.javaSupport.onCompilerConfigured = { [weak self] in
            self?.compilerDidReconfigure()
        }
        intelligenceServices.javaSupport.onIndexSourcesPublished = { [weak self] in
            self?.javaGutterIconsPreferenceChanged()
        }
        intelligenceServices.javaSupport.onInspectionConfigurationChanged = { [weak self] in
            guard let self else { return }
            javaSupport.reanalyzeInspections(openJavaDocuments())
        }
        // First use restores the saved preferences and recent lists.
        _ = IDEAppState.shared
        // A window opened with none other open (launch, or Dock reopen after closing the last one)
        // restores the last window; one opened next to another starts empty.
        if IDEWindowRegistry.shared.shouldRestoreLastWindow, Self.isSessionPersistenceEnabled {
            loadSession(IDEWindowSessionStore.load())
        } else {
            startedAsExtraWindow = true
            // A window that does not restore still opens at the widths the user last used, which
            // is what `IDERootView` shows; the workspace must agree or its first save resets them.
            if Self.isSessionPersistenceEnabled {
                seedPanelWidths(from: IDEWindowSessionStore.load())
            }
        }
        wireAdapter()
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()
        showsWelcome = !hasOpenDocuments
        showsFirstRunGuide = !preferences.hasCompletedFirstRunGuide

        if IDEWindowRegistry.shared.consumeLaunchArguments() {
            openLaunchArgumentTargets()
        }

        navigationBuffers.workspace = self
        let languages = self.languages
        let environment = languageEnvironment()
        Task {
            await languages.start(environment: environment)
            await workspaceBridge.syncWorkbench(workbench)
            await workspaceBridge.workspace.connect(to: adapter)
            await intelligenceServices.indexingService.connect(to: workspaceBridge.workspace)
            await intelligenceServices.javaSupport.connect(to: workspaceBridge.workspace)
        }

        IDEWindowRegistry.shared.register(self)
    }

    /// `--open <file>` and `--open-folder <dir>`; only the first window of the process calls this.
    private func openLaunchArgumentTargets() {
        if let index = CommandLine.arguments.firstIndex(of: "--open"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await openDocument(from: url) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--open-folder"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            applyProjectRoot(url)
        }
    }

    /// The window is going away: stop being a target for menu commands and external opens, then
    /// stop everything it started.
    func windowWillClose() {
        IDEWindowRegistry.shared.unregister(self)
        teardown()
    }

    /// Set once `teardown()` has run. A torn-down workspace must not save: it no longer has its
    /// project, and its state is not the one to restore.
    private(set) var isTornDown = false

    /// Holds the project folder's security-scoped access, released when the project changes or the
    /// window closes.
    @ObservationIgnored
    private let projectAccess = IDESecurityScopedAccess()

    /// The window is closing: stop everything this workspace started, so a closed project leaves no
    /// file watcher, git or index work, Gradle run, debug session, `javac` configuration or held
    /// folder access behind, and nothing keeps the workspace alive. The layout was saved before the
    /// window closed (`IDEWindowCloseGuard`); this does not save. Safe to call twice.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        // The services drop what they took from the environment (open-buffer lookups, consent).
        Task { [languages] in await languages.stop() }
        breakpointPopover.dismiss()
        streamTraceWindow?.close()
        streamTraceWindow = nil
        aiBrowser?.teardown()
        aiBrowser = nil
        aiChanges.reset()
        stopProjectActivity()
        terminateTerminals()
        runs.stopAll()
        projectWatcher.onBatch = []
        projectWatcher.stop()
        gitStatus.setRoot(nil)
        fileIndexer.setRoot(nil)
        runProviders.stopAll()
        swiftUIPreviewSwitchTask?.cancel()
        swiftUIPreviewSwitchTask = nil
        swiftUIPreview?.stop()
        swiftUIPreview = nil
        projectSystems.stop()
        intelligenceServices.javaSupport.teardown()
        languageServerHost.stop()
        overlays.cancelAll()
        javaRunAvailability.cancel()
        javaAutoImport.cancel()
        structureRefreshTask?.cancel()
        structureRefreshTask = nil
        blame.cancelAll()
        changeMarkers.cancelAll()
        agent.teardown()
        aiChat.teardown()
        databaseSupport.closeAll()
        closeAllDiffSessions()
        closeAllDiagramSessions()
        closeAllProfileSessions()
        closeAllHexSessions()
        notifications.dismissToast()
        projectAccess.end()
        window = nil
    }

    private struct WeakTerminalHost {
        weak var host: IDETerminalHostView?
    }

    /// The terminal views SwiftUI created for this window's tabs, weakly. A running shell keeps its
    /// view alive, so closing the window has to end the shell itself rather than wait for SwiftUI to
    /// dismantle the view.
    @ObservationIgnored
    private var terminalHosts: [WeakTerminalHost] = []

    /// The terminal shown now, if any.
    func activeTerminalHost() -> IDETerminalHostView? {
        terminalHosts.compactMap(\.host).first { $0.isShownActive }
    }

    func registerTerminalHost(_ host: IDETerminalHostView) {
        host.onFocus = { [weak self] in self?.autosaveBecauseFocusMoved() }
        terminalHosts.removeAll { $0.host == nil }
        terminalHosts.append(WeakTerminalHost(host: host))
    }

    private func terminateTerminals() {
        for entry in terminalHosts {
            entry.host?.terminateProcess()
        }
        terminalHosts.removeAll()
    }

    /// Stops what the current project has running: the debug session and any Gradle task. Used when
    /// the project goes away, whether the window closes, the folder closes or another replaces it.
    private func stopProjectActivity() {
        debugSession.stop()
        for system in projectSystems.systems { system.cancelTasks() }
    }

    /// Open editors with unsaved changes, for the confirmation before quitting.
    var unsavedDocumentCount: Int {
        workbench.allDocuments().filter(\.isDirty).count
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
        openUntitled(displayName: "Untitled", text: "")
    }

    /// An unsaved editor tab with this text. `languageIdentifier` highlights it from the start
    /// (e.g. the GraphQL schema preview); `nil` keeps the plain-text default of `newFile()`.
    func openUntitled(displayName: String, text: String, inRightSplit: Bool = false, languageIdentifier: String? = nil) {
        if inRightSplit {
            activatePaneToTheRight()
        }
        let document = WorkbenchDocument(
            displayName: displayName,
            text: text,
            language: nil,
            languageIdentifier: nil
        )
        isSettingsVisible = false
        agent.dismissPage()
        workbench.openDocument(document)
        showsWelcome = false
        // Layout is unchanged — only the active pane's selected document is. Reloading every
        // pane here used to bump a file-backed document's `contentGeneration` and then rebuild
        // sibling split panes from empty `document.text`, blanking both editors.
        let pane = workbench.activePane
        showDocument(in: pane, host: host(for: pane.id))
        if let languageIdentifier {
            setLanguage(identifier: languageIdentifier, in: pane)
        }
        activatePane(workbench.activePaneID)
        layoutEpoch += 1
        refreshPresentation()
        Task { await workspaceBridge.syncWorkbench(workbench) }
    }

    /// Applies syntax highlighting inferred from a file's extension after save (e.g. untitled →
    /// `name.md` switches to markdown). Matches ``loadDocument(from:)`` / ``setLanguage``.
    func applyLanguageInferredFromURL(
        _ url: URL,
        document: WorkbenchDocument,
        in pane: EditorPane
    ) {
        guard document.contentKind == .text else { return }
        guard let identifier = LanguageIdentifier.identifier(for: url) else { return }
        document.languageIdentifier = identifier
        document.language = IDELanguageSupport.language(forIdentifier: identifier, fileURL: url)

        let languageMode: LanguageMode
        if let language = document.language {
            languageMode = TreeSitterLanguageMode(language: language,
                                                  languageProvider: Self.languageProvider,
                                                  manualInjectionProvider: manualInjectionProvider(for: document))
        } else {
            languageMode = PlainTextLanguageMode()
        }
        let host = host(for: pane.id)
        host.textView.languageIdentifier = identifier
        preferences.applySmartKeys(to: host.textView)
        host.textView.setLanguageMode(languageMode)
        host.markdownPreviewController.documentBaseURL = url
        host.markdownPreviewController.closeIfNotMarkdown()
        host.closeJSONDiagramIfNotJSON()
        host.closeCSVTableIfNotCSV()

        if pane.id == workbench.activePaneID {
            statusLanguage = identifier
            isMarkdownPreviewVisible = host.markdownPreviewController.isVisible
            isJSONDiagramVisible = host.isJSONDiagramVisible
            isCSVTableVisible = host.isCSVTableVisible
        }
        scheduleSemanticHighlighting(host: host, languageIdentifier: identifier, delay: 0)
        Task { await workspaceBridge.syncPane(pane) }
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
            languageMode = TreeSitterLanguageMode(language: language,
                                                  languageProvider: Self.languageProvider,
                                                  manualInjectionProvider: manualInjectionProvider(for: document))
        } else {
            languageMode = PlainTextLanguageMode()
        }
        let languageTextView = host(for: targetPane.id).textView
        languageTextView.languageIdentifier = identifier
        preferences.applySmartKeys(to: languageTextView)
        languageTextView.setLanguageMode(languageMode)
        host(for: targetPane.id).textView.reservedLineMarkerSlots = IDEEditorOverlayController.reservedLineMarkerSlots(
            languageIdentifier: identifier, hasMarkerProvider: languages.lineMarkers(for: identifier) != nil
        )

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

    /// Open Folder…: the chosen folder goes through the router, so it opens here when this window is
    /// empty, focuses the window that already has it, or asks whether to replace this project or
    /// open a new window.
    public func openFolder() {
        IDEWindowRegistry.shared.chooseFolder(from: .window(windowID))
    }

    /// Makes `url` this window's project. The router calls it for an empty window; `replaceProject`
    /// calls it after clearing the old one.
    func openProjectFolder(_ url: URL) {
        isSidebarVisible = true
        applyProjectRoot(url)
        showsWelcome = !hasOpenDocuments
        refreshPresentation()
        saveSession()
        if let request = pendingAIOpen {
            pendingAIOpen = nil
            applyAIOpen(request)
        }
        // A project the New Project wizard just made opens on its main file.
        if let file = IDENewProjectOpenRequests.take(for: url) {
            Task { await openDocument(from: file) }
        }
    }

    /// Replaces this window's project and tabs with `url`, after confirming if anything is unsaved.
    func replaceProject(with url: URL) {
        guard confirmDiscardingUnsavedChanges(
            messageText: "Open another folder in this window?",
            confirmButtonTitle: "Replace"
        ) else { return }
        closeAllOpenDocuments()
        dismissProjectChrome()
        stopProjectActivity()
        openProjectFolder(url)
    }

    /// This window already has a project: ask whether `url` replaces it or opens in a new window.
    /// "Remember my choice" writes the `Open folders in` setting.
    func askHowToOpenFolder(_ url: URL) {
        var alert = IDEAlert.choice(
            "Open “\(url.lastPathComponent)” in a new window?",
            detail: "This window already has “\(project.rootURL?.lastPathComponent ?? "a folder")” open.",
            style: .informational,
            buttons: [.init(title: "New Window"), .init(title: "Replace This Window's Project"), .init(title: "Cancel")])
        alert.suppressionTitle = "Remember my choice"
        Task { [weak self] in
            let choice = await alert.present(in: self?.window)
            guard let self else { return }
            let remember = alert.suppressionIsChecked
            switch choice {
            case 0:
                if remember { self.preferences.openFoldersIn = .newWindow }
                IDEWindowRegistry.shared.openNewWindow(urls: [url])
            case 1:
                if remember { self.preferences.openFoldersIn = .replace }
                self.replaceProject(with: url)
            default:
                break
            }
        }
    }

    /// Brings this window forward, selecting its tab when it is in a tab group.
    func focusWindow() {
        guard let window else { return }
        if let group = window.tabGroup, group.windows.count > 1 {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files and folders dropped on this window. Files open here as tabs, wherever they live; a
    /// folder is an open request made from this window.
    func openURLsDropped(_ urls: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }
        if !files.isEmpty {
            openDroppedURLs(files)
        }
        if !folders.isEmpty {
            IDEWindowRegistry.shared.open(urls: folders, origin: .window(windowID))
        }
    }

    public func openRecentFile(_ url: URL) {
        Task { await openDocument(from: url) }
    }

    public func openRecentProject(_ url: URL) {
        IDEWindowRegistry.shared.open(urls: [url], origin: .window(windowID))
    }

    public func removeRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentlyEditedFiles.removeAll { $0 == url }
        saveSession()
    }

    /// ⌫ in Recent Files: forgets the file and closes its tabs. A tab with unsaved changes stays
    /// open, since closing one discards the edits without asking.
    private func forgetRecentFile(_ url: URL) {
        removeRecentFile(url)
        let path = url.standardizedFileURL.path
        for pane in workbench.panes {
            for document in pane.documents where document.url?.standardizedFileURL.path == path && !document.isDirty {
                closeTab(document.id, in: pane.id)
            }
        }
    }

    /// Moves the active document to the front of the recently edited list. Runs per keystroke,
    /// so it returns early when the file already leads the list.
    private func recordRecentlyEdited() {
        guard let url = workbench.activePane.selectedDocument?.url, recentlyEditedFiles.first != url else { return }
        recentlyEditedFiles.removeAll { $0 == url }
        recentlyEditedFiles.insert(url, at: 0)
        if recentlyEditedFiles.count > 30 {
            recentlyEditedFiles.removeLast(recentlyEditedFiles.count - 30)
        }
    }

    private func paletteStatus(for url: URL) -> PaletteFileStatus? {
        switch gitStatus.status(for: url, isDirectory: false) {
        case .modified: .modified
        case .added: .added
        case .untracked: .untracked
        case .conflicted: .conflicted
        case .ignored: .ignored
        case nil: nil
        }
    }

    public func showRecentLocations() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentRecentLocations()
    }

    /// Back-stack caret positions (⌘[ history), newest first. Line text comes from an editor
    /// currently showing the file; other rows go without it.
    private func recentLocationEntries() -> [PaletteLocationEntry] {
        recentLocationEntries(from: workbench.navigationHistory.backEntries.reversed())
    }

    private func recentLocationEntries(from entries: [NavigationEntry]) -> [PaletteLocationEntry] {
        var textViews: [URL: TextView] = [:]
        for pane in workbench.panes {
            guard let url = pane.selectedDocument?.url, let host = hostCache.peek(pane.id) else { continue }
            textViews[url.standardizedFileURL] = host.textView
        }
        return entries.compactMap { entry in
            guard let url = entry.url else { return nil }
            let line = entry.location.lineNumber
            let text = textViews[url.standardizedFileURL].flatMap { Self.lineText(line, in: $0) }
            return PaletteLocationEntry(url: url, line: line + 1, column: entry.location.column + 1, lineText: text)
        }
    }

    /// The text of zero-based `line`, capped so a minified file's line stays cheap to read.
    private static func lineText(_ line: Int, in textView: TextView) -> String? {
        guard let start = textView.location(at: TextLocation(lineNumber: line, column: 0)),
              let next = textView.location(at: TextLocation(lineNumber: line + 1, column: 0)) else { return nil }
        let length = min(max(next - start, 0), 240)
        return textView.text(in: NSRange(location: start, length: length))?
            .trimmingCharacters(in: .newlines)
    }

    public func removeRecentProject(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentProjects.removeAll { $0.standardizedFileURL == standardized }
        saveSession()
    }

    /// Returns whether the main window may close. Saves what it can first and asks only about
    /// what is still unsaved (untitled buffers, files that changed on disk, failed writes).
    func confirmCloseWindow() async -> Bool {
        if hasUnsavedDocuments { _ = await saveAll(reason: .closingWindow) }
        return confirmDiscardingUnsavedChanges(
            messageText: "Close this window?",
            confirmButtonTitle: "Close Window"
        )
    }

    /// Closes the open project folder, all editor tabs, and project-scoped panels. An editor with
    /// unsaved changes asks first (Save, Don't Save, Cancel). Terminals leave the folder and start
    /// in the home directory, which is what a later reopen restores.
    public func closeFolder() {
        guard project.rootURL != nil else { return }
        guard hasUnsavedDocuments else {
            finishClosingFolder()
            return
        }
        Task { @MainActor [weak self] in
            guard let self, await self.confirmClosingFolder(), self.project.rootURL != nil else { return }
            self.finishClosingFolder()
        }
    }

    /// Save writes what it can (and asks again when a file cannot be saved). Don't Save drops the
    /// edits. Cancel leaves the folder open.
    private func confirmClosingFolder() async -> Bool {
        switch folderCloseResolver(unsavedPromptText()) {
        case .cancel:
            return false
        case .discard:
            return true
        case .save:
            return await saveForClosing(workbench.allDocuments().filter(\.isDirty))
        }
    }

    private func finishClosingFolder() {
        closeAllOpenDocuments()
        dismissProjectChrome()
        stopProjectActivity()
        applyProjectRoot(nil)
        resetTerminalsToDefaultDirectory()
        showsWelcome = true
        refreshPresentation()
        saveSession()
    }

    /// Points every shell at the directory a new tab would use (the home directory once the folder
    /// is closed) and restarts a shell that was somewhere else.
    private func resetTerminalsToDefaultDirectory() {
        bottomPanel.resetShells(to: defaultTerminalDirectory())
    }

    public var recentFileURLs: [URL] {
        recentFiles
    }

    public var recentProjectURLs: [URL] {
        recentProjects
    }

    /// Returns whether the document was written (false when there was nothing to save, the save
    /// panel was cancelled, or the write failed).
    @discardableResult
    public func saveActiveDocument() async -> Bool {
        guard let document = workbench.activePane.selectedDocument else { return false }
        return await saveDocument(document, reason: .explicit) == .saved
    }

    /// Converts the active document to `encoding` and saves it, asking for a file name first when
    /// it has none. The document keeps its old encoding if the save does not happen, for example
    /// when a character has no equivalent in `encoding`.
    public func saveActiveDocument(with encoding: TextFileEncoding) async {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .text else { return }
        let previous = document.encoding
        document.encoding = encoding
        if await saveActiveDocument() {
            statusEncoding = encoding
        } else {
            document.encoding = previous
            statusEncoding = previous
        }
    }

    /// Saves an open, unsaved text buffer to its own file, wherever it is shown, for the agent: its
    /// edits must be on disk before a command or build runs. Skips the import-optimizing on-save
    /// step, since that would rewrite what the agent wrote. Returns whether the file was saved.
    func saveBuffer(at url: URL) async -> Bool {
        guard let (_, document) = paneAndDocument(matching: url), document.isDirty, document.contentKind == .text,
              case .live = await editTarget(for: url)
        else { return false }
        return await saveDocument(document, reason: .agent) == .saved
    }

    /// Shows the quick-fix list at the caret of the active editor (⌥↩).
    func showContextActions() {
        _ = host(for: workbench.activePane.id).textView.perform(.showContextActions)
    }

    /// Shows the signatures of the call around the caret (⌘P in the IntelliJ keymap).
    func showParameterInfo() {
        _ = host(for: workbench.activePane.id).textView.perform(.showParameterInfo)
    }

    /// Jumps to the method the caret's method overrides, or a class's supertypes (⌘U in the IntelliJ keymap).
    func goToSuperMethod() {
        _ = host(for: workbench.activePane.id).textView.perform(.goToSuperMethod)
    }

    /// Jumps to the declaration of the type of the symbol at the caret (⌃⇧B in the IntelliJ keymap).
    func goToTypeDefinition() {
        _ = host(for: workbench.activePane.id).textView.perform(.goToTypeDefinition)
    }

    /// Reformats the selection, or the whole file when nothing is selected (⌥⌘L in the IntelliJ keymap).
    func reformatCode() {
        _ = host(for: workbench.activePane.id).textView.perform(.reformatCode)
    }

    /// "Format Document" in the editor's right-click menu, for the languages whose service has a
    /// formatter (Java and JSON). It formats the whole file even when text is selected.
    func formatDocumentContextMenuItems(textView: TextView, paneID: UUID) -> [NSMenuItem] {
        guard textView.isEditable, let language = textView.languageIdentifier,
              languages.services(for: language).contains(where: { $0.providers.formatting != nil }) else { return [] }
        let item = IDEClosureMenuItem(title: "Format Document") { [weak self] in
            self?.host(for: paneID).intelligenceController?.formatDocument()
        }
        return [.separator(), item]
    }

    /// Renames the symbol at the caret (⇧F6 in the IntelliJ keymap): prompt, preview, apply.
    func renameSymbol() {
        _ = host(for: workbench.activePane.id).textView.perform(.rename)
    }

    /// Extracts the selected expression into a local variable (⌥⌘V in the IntelliJ keymap).
    func extractVariable() {
        _ = host(for: workbench.activePane.id).textView.perform(.extractVariable)
    }

    /// Extracts the selected expression into an instance field (⌥⇧⌘F).
    func extractField() {
        _ = host(for: workbench.activePane.id).textView.perform(.extractField)
    }

    /// Extracts the selected expression into a static final constant (⌥⌘C).
    func extractConstant() {
        _ = host(for: workbench.activePane.id).textView.perform(.extractConstant)
    }

    /// Extracts the selection into a new private method (⌥⌘M).
    func extractMethod() {
        _ = host(for: workbench.activePane.id).textView.perform(.extractMethod)
    }

    /// Encapsulates the field at the caret (⌥⌘E).
    func encapsulateField() {
        _ = host(for: workbench.activePane.id).textView.perform(.encapsulateField)
    }

    /// Generates getter/setter methods for the field at the caret.
    func generateAccessors() {
        _ = host(for: workbench.activePane.id).textView.perform(.generateAccessors)
    }

    /// Generates a constructor, getters/setters or `toString()` in the class at the caret.
    func generate() {
        _ = host(for: workbench.activePane.id).textView.perform(.generate)
    }

    /// Runs a refactoring by id in the active editor (the language's own, from its service).
    func performRefactoring(_ id: RefactoringID) {
        _ = host(for: workbench.activePane.id).intelligenceController?.performRefactoring(id)
    }

    /// Inlines the local variable at the caret (⌥⌘N).
    func inlineVariable() {
        _ = host(for: workbench.activePane.id).textView.perform(.inlineVariable)
    }

    /// Inlines the private method at the caret or call site (Find Action / Java menu).
    func inlineMethod() {
        _ = host(for: workbench.activePane.id).textView.perform(.inlineMethod)
    }

    /// Changes the method signature at the caret (⌃F6): rename, add a parameter, or remove the last.
    func changeMethodSignature() {
        _ = host(for: workbench.activePane.id).textView.perform(.changeSignature)
    }

    /// Moves the top-level class at the caret to another package.
    func moveClass() {
        _ = host(for: workbench.activePane.id).textView.perform(.moveClass)
    }

    /// Deletes the symbol at the caret when it has no usages.
    func safeDelete() {
        _ = host(for: workbench.activePane.id).textView.perform(.safeDelete)
    }

    func presentWorkspaceEditPreview(
        _ plan: WorkspaceEditPlan,
        style: IDEWorkspaceEditPreviewStyle = .singleLine,
        apply: @escaping (WorkspaceEdit) async -> WorkspaceEditApplyResult
    ) {
        workspaceEditPreview = IDEWorkspaceEditPreviewModel(plan: plan, style: style) { [weak self] edit in
            let result = await apply(edit)
            self?.refreshAfterWorkspaceEdit(result)
            return result
        }
    }

    func dismissWorkspaceEditPreview() {
        workspaceEditPreview = nil
        focusActiveEditor()
    }

    func dismissRenamePreview() {
        dismissWorkspaceEditPreview()
    }

    private func presentRenamePreview(
        _ plan: RenamePlan,
        apply: @escaping (WorkspaceEdit) async -> WorkspaceEditApplyResult
    ) {
        presentWorkspaceEditPreview(plan, apply: apply)
    }

    func refreshAfterWorkspaceEdit(_ result: WorkspaceEditApplyResult) {
        let parents = Set(
            result.renamedFiles.flatMap { [$0.from, $0.to] }
                + result.deletedFiles
                + result.appliedFiles
        ).map { $0.deletingLastPathComponent().path }
        if !parents.isEmpty {
            Task {
                await project.refresh(directories: Set(parents))
                gitStatus.refresh()
            }
        } else if !result.appliedFiles.isEmpty {
            gitStatus.refresh()
        }
        refreshPresentation()
    }

    /// Removes unused imports from the active editor's Java file.
    func optimizeImports() {
        _ = host(for: workbench.activePane.id).textView.perform(.optimizeImports)
    }

    public func saveActiveDocumentAs() async {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .text else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.displayName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = await write(document, to: url, reason: .explicit)
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

    /// Lists the tool windows (Terminal, Problems, …) and opens the one chosen.
    public func showToolWindows() {
        _ = sharedPalette(for: host(for: workbench.activePaneID)).presentToolWindows()
    }

    /// The tool windows that exist right now, for Go to Tool Window. Choosing one opens it (never
    /// toggles it shut), so the list can be used to jump between windows.
    func toolWindowEntries() -> [ToolWindowEntry] {
        var entries: [ToolWindowEntry] = []
        func add(_ id: String, _ title: String, _ action: @escaping @MainActor @Sendable () -> Void) {
            entries.append(ToolWindowEntry(id: id, title: title, action: action))
        }
        add("explorer", "Project") { [weak self] in self?.showSidebarTab(.explorer) }
        add("structure", "Structure") { [weak self] in self?.showSidebarTab(.structure) }
        if showsSourceControlTab {
            add("changes", "Changes") { [weak self] in self?.showSidebarTab(.changes) }
        }
        add("breakpoints", "Breakpoints") { [weak self] in self?.showSidebarTab(.breakpoints) }
        if let system = projectSystems.active {
            add(system.id, system.displayName) { [weak self] in
                guard let self, !self.isProjectSidebarVisible else { return }
                self.toggleProjectSidebar()
            }
        }
        add("terminal", "Terminal") { [weak self] in
            guard let self, !self.isBottomToolWindowOpen(.terminal) else { return }
            self.toggleBottomToolWindow(.terminal)
        }
        add("problems", "Problems") { [weak self] in self?.showBottomTab(.problems) }
        if showsSourceControlTab {
            add("sourceControl", "History") { [weak self] in self?.showBottomTab(.sourceControl) }
        }
        if showsDebugTab {
            add("debug", "Debug") { [weak self] in self?.showBottomTab(.debug) }
        }
        if showsUsagesTab {
            add("usages", "Usages") { [weak self] in self?.showBottomTab(.usages) }
        }
        if showsTypeHierarchyTab {
            add("typeHierarchy", "Type Hierarchy") { [weak self] in self?.showBottomTab(.typeHierarchy) }
        }
        if showsCallHierarchyTab {
            add("callHierarchy", "Call Hierarchy") { [weak self] in self?.showBottomTab(.callHierarchy) }
        }
        if showsTestResultsTab {
            add("testResults", "Test Results") { [weak self] in self?.showBottomTab(.testResults) }
        }
        if showsRunTab {
            add("run", "Run Output") { [weak self] in self?.showBottomTab(.run) }
        }
        if showsGradleConsoleTab {
            add("gradleConsole", "Gradle Output") { [weak self] in self?.showBottomTab(.gradle) }
        }
        if showsMavenConsoleTab {
            add("mavenConsole", "Maven Output") { [weak self] in self?.showBottomTab(.maven) }
        }
        if showsHTTPTab {
            add("http", "HTTP Response") { [weak self] in self?.showBottomTab(.http) }
        }
        return entries
    }

    /// Lists the declarations of the focused file (⌘F12 in the IntelliJ keymap).
    public func showFileStructure() {
        _ = sharedPalette(for: host(for: workbench.activePaneID)).presentFileSymbols()
    }

    public func showGoToSymbol() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentSymbols()
    }

    public func showGoToPackage() {
        sharedPalette(for: host(for: workbench.activePaneID)).presentPackages()
    }

    public func showGoToLine() {
        if workbench.activePane.selectedDocument?.contentKind == .binary {
            showHexGoToOffset()
            return
        }
        sharedPalette(for: host(for: workbench.activePaneID)).presentGoToLine()
    }

    public func showFind() {
        if workbench.activePane.selectedDocument?.contentKind == .binary {
            showHexFind()
            return
        }
        // A read-only log with focus (the HTTP response) has its own find bar; the editor's
        // would open on a view the user is not looking at.
        if let log = NSApp.keyWindow?.firstResponder as? NSTextView, log.usesFindBar, !log.isEditable {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            log.performFindPanelAction(item)
            return
        }
        // A table preview has no editor find bar; ⌘F goes to the table's own search field.
        if let host = hostCache.peek(workbench.activePaneID), host.isCSVTableVisible {
            host.csvTableView.focusSearch()
            return
        }
        adapter.textView?.perform(.toggleFindPanel)
    }

    public func showReplace() {
        adapter.textView?.perform(.toggleReplacePanel)
    }

    /// Next to `session.json` and `gradle-trust.json`: launch settings shouldn't reset with a cache.
    static var defaultRunConfigurationsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("run-configurations.json")
    }

    public func sendActiveHTTPRequest() {
        guard httpFileCanSend else { return }
        let host = host(for: workbench.activePaneID)
        let textView = host.textView
        let fileURL = workbench.activePane.selectedDocument?.url
        showHTTPResponse()
        Task { @MainActor [weak self, weak textView] in
            await self?.saveHTTPFileBeforeSending(at: fileURL)
            guard let self, let textView else { return }
            self.httpSupport.send(
                text: textView.text,
                caretUTF16Offset: textView.selectedRange.location,
                fileURL: fileURL
            )
        }
    }

    /// Writes the `.http` file's unsaved edits before a request is sent, so the file on disk is the
    /// one that was sent. A file with no name yet is left alone: a save panel would interrupt the
    /// request. The request itself is read from the buffer, so it is sent even when the save is
    /// cancelled (the overwrite prompt) or fails.
    func saveHTTPFileBeforeSending(at url: URL?) async {
        guard let url, let (_, document) = paneAndDocument(matching: url),
              document.isDirty, document.contentKind == .text
        else { return }
        if document === workbench.activePane.selectedDocument {
            await saveActiveDocument()
        } else {
            _ = await saveBuffer(at: url)
        }
    }

    func showHTTPResponse() {
        showBottomTab(.http)
    }

    /// A hover window's action button. `###@scheme:` hovers offer opening the schema beside
    /// the `.http` file; anything else is ignored.
    func handleHoverAction(_ action: HoverAction) {
        guard action.id == HTTPSchemaHoverProvider.openActionID,
              let raw = action.arguments.first,
              let url = URL(string: raw)
        else { return }
        openGraphQLSchema(url)
    }

    /// Opens a `###@scheme:` schema in the editor to the right: a schema file opens as-is, a
    /// remote endpoint opens as a preview tab with the fetched schema's types.
    func openGraphQLSchema(_ url: URL) {
        if url.isFileURL {
            Task { await openDocument(from: url, inRightSplit: true) }
            return
        }
        let request = GraphQLSchemaRequest(url: url, headers: schemaHeaders(for: url))
        let title = "Schema — \(url.host ?? url.lastPathComponent)"
        let store = httpSupport.graphQLSchemas
        Task {
            if let schema = await store.schema(for: request) {
                openUntitled(
                    displayName: title,
                    text: GraphQLSchemaText.fullText(for: schema, source: url.absoluteString),
                    inRightSplit: true,
                    languageIdentifier: "graphql"
                )
                return
            }
            let text: String
            do {
                let schema = try await store.refresh(request)
                text = GraphQLSchemaText.fullText(for: schema, source: url.absoluteString)
            } catch {
                text = "# Could not load the schema from \(url.absoluteString).\n# \(error.localizedDescription)"
            }
            openUntitled(displayName: title, text: text, inRightSplit: true, languageIdentifier: "graphql")
        }
    }

    /// The headers of the first request below the `###@scheme:` line naming `url`, so an
    /// authenticated endpoint's preview sends what the endpoint expects. Empty when the caret
    /// is not under a matching directive.
    private func schemaHeaders(for url: URL) -> [String: String] {
        let textView = host(for: workbench.activePaneID).textView
        let text = textView.text
        guard let directive = HTTPGraphQLDirective.directive(in: text, caretUTF16: textView.selectedRange.location),
              case .success(let request) = GraphQLSchemaResolver.resolve(
                  directive,
                  in: text,
                  fileURL: workbench.activePane.selectedDocument?.url,
                  globals: httpSupport.globals.snapshot()
              ),
              request.url == url
        else { return [:] }
        return request.headers
    }

    /// HTTP: Refresh GraphQL Schema.
    func refreshGraphQLSchema() {
        let textView = host(for: workbench.activePaneID).textView
        showHTTPResponse()
        httpSupport.refreshSchema(
            text: textView.text,
            caretUTF16Offset: textView.selectedRange.location,
            fileURL: workbench.activePane.selectedDocument?.url
        )
    }

    func toggleBottomPanelExpanded() {
        guard isTerminalVisible else { return }
        isBottomPanelExpanded.toggle()
        if isBottomPanelExpanded {
            // Otherwise keystrokes keep going to the editor hidden under the panel.
            window?.makeFirstResponder(nil)
            requestTerminalFocus()
        }
    }

    public func toggleTerminal() {
        isTerminalVisible.toggle()
        if !isTerminalVisible { isBottomPanelExpanded = false }
        if isTerminalVisible {
            // Leave the Gradle console showing if that's what's already selected; only a shell
            // toggle (no tabs at all yet) needs a fresh tab created for it.
            if terminalTabs.isEmpty && isTerminalTabSelected {
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
        bottomPanel.append(makeTerminalTab(cwd: cwd))
        requestTerminalFocus()
        if saveSession {
            self.saveSession()
        }
    }

    /// Shows an agent command's output on a tab of its own, opened on the first line and not given
    /// the keyboard. The user's shell tabs are left alone. `nil` ends the command.
    func showAgentCommand(id: UUID, title: String, line: String?) {
        if bottomPanel.showAgentCommand(id: id, title: title, line: line, directory: defaultTerminalDirectory()) {
            saveSession()
        }
    }

    /// The output waiting for an agent command tab, consumed once by its view.
    func takeAgentCommandFeed(tabID: UUID) -> String {
        bottomPanel.takeAgentCommandFeed(tabID: tabID)
    }

    func closeTerminalTab(_ id: UUID) {
        switch bottomPanel.closeTab(id) {
        case .notFound:
            return
        case .lastClosed:
            if let tab = languageModuleBottomTabs().first(where: \.staysWhenLastShellCloses)?.tab {
                showBottomTab(tab)
            } else if showsSourceControlTab {
                showBottomTab(.sourceControl)
            } else {
                hideTerminal()
            }
        case .removed:
            requestTerminalFocus()
            saveSession()
        }
    }

    func selectTerminalTab(_ id: UUID) {
        guard bottomPanel.selectTab(id) else { return }
        requestTerminalFocus()
        saveSession()
    }

    /// Shows the Changes tab of the left sidebar (branch, commit and the changed files).
    func showSourceControl() {
        showSidebarTab(.changes)
    }

    /// The file behind the active editor, when it is inside the open git repository.
    private func activeFileInRepository() -> URL? {
        guard gitStatus.isRepository, let root = gitStatus.repositoryRootPath,
              let url = workbench.activePane.selectedDocument?.url?.standardizedFileURL,
              url.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    func showGitNotice(_ title: String, _ detail: String) {
        var alert = IDEAlert.notice(title, detail: detail)
        alert.runModal()
    }

    /// Lists the commits that touched the active file, in the bottom panel's History tab.
    func showFileHistory() {
        guard let url = activeFileInRepository() else {
            showGitNotice("No File History", "The active file is not in a git repository.")
            return
        }
        gitStatus.showFileHistory(path: url.path)
        showBottomTab(.sourceControl)
    }

    /// Whether the active file shows the blame column (drives the menu title).
    var isBlameShownForActiveFile: Bool {
        blame.isEnabled(for: workbench.activePane.selectedDocument?.url)
    }

    /// Shows or hides the blame column for the active file (Git ▸ Show Git Blame).
    func toggleGitBlame() {
        guard let url = activeFileInRepository() else {
            showGitNotice("No Git Blame", "The active file is not in a git repository.")
            return
        }
        blame.toggle(for: url)
        refreshBlame(in: workbench.activePane, force: true)
    }

    /// Whether the change stripe is on (Git ▸ Hide Changed Lines). On unless the user turned it off.
    var showsChangedLines: Bool { changeMarkers.isEnabled }

    /// Shows or hides the change stripe in every editor (Git ▸ Highlight Changed Lines).
    func toggleChangedLines() {
        changeMarkers.toggle()
        refreshChangedLinesInOpenEditors(force: true, delay: .zero)
    }

    /// Re-diffs the editors that are showing, or hides the stripe when the feature or the file is out.
    private func refreshChangedLinesInOpenEditors(force: Bool, delay: Duration) {
        for pane in workbench.panes {
            guard let host = hostCache.peek(pane.id) else { continue }
            guard pane.selectedDocument?.contentKind == .text else {
                changeMarkers.hide(on: host.textView)
                continue
            }
            changeMarkers.refresh(
                textView: host.textView,
                url: pane.selectedDocument?.url,
                git: gitStatus,
                force: force,
                delay: delay
            )
        }
    }

    /// Re-blames the editor of `pane` after a save, or hides the column after a toggle off.
    func refreshBlame(in pane: EditorPane, force: Bool = false) {
        guard pane.selectedDocument?.contentKind == .text else { return }
        let url = pane.selectedDocument?.url
        blame.refresh(textView: host(for: pane.id).textView, url: url, git: gitStatus, force: force) { [weak self] in
            self?.showGitNotice(
                "No Git Blame",
                "\(url?.lastPathComponent ?? "This file") has no committed history yet, so there is nothing to annotate."
            )
        }
    }

    /// The repository changed (a commit, a pull, another tool): refresh the columns that are showing.
    private func refreshBlameInOpenEditors() {
        guard !blame.enabledPaths.isEmpty else { return }
        for pane in workbench.panes where blame.isEnabled(for: pane.selectedDocument?.url) {
            refreshBlame(in: pane)
        }
    }

    /// Puts the active file back to its last commit (⌥⌘Z in the IntelliJ keymap), after asking.
    /// Staged and unstaged changes and unsaved edits are all discarded; nothing can bring them back.
    func revertActiveFile() {
        guard let url = activeFileInRepository() else {
            showGitNotice("Nothing to Revert", "The active file is not in a git repository.")
            return
        }
        let name = url.lastPathComponent
        let isDirty = workbench.activePane.selectedDocument?.isDirty == true
        let status = gitStatus.status(for: url, isDirectory: false)
        if status == nil, !isDirty {
            showGitNotice("Nothing to Revert", "\(name) has no changes since the last commit.")
            return
        }
        if status == .untracked {
            showGitNotice("Nothing to Revert", "\(name) is not under version control yet, so there is no earlier version to go back to.")
            return
        }
        var alert = IDEAlert.confirm(
            "Revert changes to \(name)?",
            detail: "This discards every change to \(name) since the last commit, including unsaved edits. It cannot be undone.",
            confirm: "Revert", isDestructive: true)
        guard alert.confirms() else { return }
        gitStatus.revert(
            path: url.path,
            then: { [weak self] in self?.reloadOpenEditorsAfterGitChange(discardingEditsIn: [url.path]) },
            onFailure: { [weak self] message in self?.showGitNotice("Could Not Revert", message) }
        )
    }

    /// Reverts several changed files (the Source Control panel's selection or "Revert All…") after
    /// one confirmation that names them. Files with no committed version are listed as skipped and
    /// left alone; unsaved edits in open editors are discarded with the rest.
    /// - Parameter paths: absolute paths of rows in `gitStatus.changes`.
    func revertChanges(_ paths: [String]) {
        let byPath = Dictionary(gitStatus.changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var revertable: [IDEGitChange] = []
        var skipped: [IDEGitChange] = []
        for path in paths where seen.insert(path).inserted {
            guard let change = byPath[path] else { continue }
            if change.unstaged == .untracked || change.staged == .added {
                skipped.append(change)
            } else {
                revertable.append(change)
            }
        }
        guard !revertable.isEmpty else {
            showGitNotice("Nothing to Revert", skipped.isEmpty
                ? "The selected files have no changes."
                : "The selected files are not in the last commit, so there is no earlier version to go back to.")
            return
        }
        let names = Self.nameList(revertable.map(\.relativePath))
        var detail = "This discards every change to \(revertable.count == 1 ? names : "these files") since the last commit, staged or not. It cannot be undone.\n\n\(revertable.count == 1 ? "" : names)"
        let revertablePaths = Set(revertable.map(\.path))
        var seenDocuments = Set<ObjectIdentifier>()
        let unsaved = workbench.panes.flatMap(\.documents).filter { document in
            guard document.isDirty, let path = document.url?.standardizedFileURL.path, revertablePaths.contains(path) else { return false }
            return seenDocuments.insert(ObjectIdentifier(document)).inserted
        }.count
        if unsaved > 0 {
            detail += "\n\n\(unsaved) of them \(unsaved == 1 ? "has" : "have") unsaved edits in an open editor; those are discarded too."
        }
        if !skipped.isEmpty {
            detail += "\n\nNot reverted (not in the last commit): \(Self.nameList(skipped.map(\.relativePath), limit: 5))"
        }
        var alert = IDEAlert.confirm(
            revertable.count == 1
                ? "Revert changes to \(revertable[0].relativePath)?"
                : "Revert changes to \(revertable.count) files?",
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            confirm: "Revert", isDestructive: true)
        guard alert.confirms() else { return }
        gitStatus.revert(
            paths: revertable.map(\.path),
            then: { [weak self] reverted in self?.reloadOpenEditorsAfterGitChange(discardingEditsIn: reverted) },
            onFailure: { [weak self] message in self?.showGitNotice("Could Not Revert", message) }
        )
    }

    /// The first `limit` names one per line, then "and N more".
    private static func nameList(_ names: [String], limit: Int = 10) -> String {
        var lines = names.prefix(limit).map { "• \($0)" }
        if names.count > limit { lines.append("and \(names.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    /// Update Project (⌘T in the IntelliJ keymap): fetches and merges or rebases the current branch
    /// from its upstream, after asking how unless the user chose not to be asked. The outcome shows
    /// in the sidebar's Changes tab.
    func pullProject() {
        guard gitStatus.isRepository else { return }
        gitStatus.requestUpdate()
        showSourceControl()
    }

    /// Opens the push dialog for the current branch (⇧⌘K in the IntelliJ keymap).
    func pushProject() {
        guard gitStatus.isRepository else { return }
        gitStatus.requestPush()
    }

    /// Fetches every remote (Git ▸ Fetch). Progress and the outcome show in the Changes tab.
    func fetchProject() {
        guard gitStatus.isRepository else { return }
        gitStatus.fetch()
        showSourceControl()
    }

    /// Switch and pull rewrite files on disk. An unsaved editor in the repository would be saved
    /// over that result, or reloaded out from under the user, so those actions wait for a save.
    private func hasUnsavedEditorsInRepository() -> Bool {
        !unsavedEditorsInRepository().isEmpty
    }

    private func unsavedEditorsInRepository() -> [WorkbenchDocument] {
        guard let root = gitStatus.repositoryRootPath else { return [] }
        return workbench.allDocuments().filter { document in
            guard document.isDirty,
                  document.contentKind == .text || document.contentKind == .binary,
                  let path = document.url?.standardizedFileURL.path else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// Writes the unsaved editors of the repository before a git operation reads or rewrites the
    /// working tree. Returns the names that could not be saved.
    private func saveUnsavedEditorsInRepository() async -> [String] {
        var failed: [String] = []
        for document in unsavedEditorsInRepository() {
            switch await saveDocument(document, reason: .beforeGit) {
            case .saved, .clean: break
            case .skippedUntitled, .conflict, .failed: failed.append(document.displayName)
            }
        }
        return failed
    }

    /// Reloads clean text tabs from disk after a branch switch or fast-forward pull, and closes
    /// tabs whose files the new tree removed. Dirty buffers are left untouched.
    /// - Parameter discardingEditsIn: paths whose unsaved edits were thrown away on purpose (a
    ///   revert), so those tabs reload too instead of being left as dirty buffers.
    private func reloadOpenEditorsAfterGitChange(discardingEditsIn forced: Set<String> = []) {
        guard let root = gitStatus.repositoryRootPath else { return }
        let open = workbench.panes.flatMap { pane in
            pane.documents.compactMap { document -> (EditorPane, WorkbenchDocument)? in
                guard let path = document.url?.standardizedFileURL.path else { return nil }
                guard path == root || path.hasPrefix(root + "/") else { return nil }
                return (pane, document)
            }
        }
        var seen = Set<ObjectIdentifier>()
        let documents = open.compactMap { pair -> WorkbenchDocument? in
            seen.insert(ObjectIdentifier(pair.1)).inserted ? pair.1 : nil
        }
        Task {
            var missing: [(EditorPane, WorkbenchDocument)] = []
            for document in documents {
                guard let url = document.url else { continue }
                guard workbench.panes.contains(where: { $0.documents.contains { $0 === document } }) else { continue }
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.append(contentsOf: open.filter { $0.1 === document })
                    continue
                }
                let discarded = forced.contains(url.standardizedFileURL.path)
                if document.contentKind == .binary {
                    guard !document.isDirty || discarded else { continue }
                    if let session = hexSessions[document.id], (try? session.refreshCleanKeepingViewport()) != nil {
                        session.publish(to: document)
                    } else {
                        await reloadHexFromDisk(document)
                    }
                    continue
                }
                guard document.contentKind == .text, !document.isDirty || discarded else { continue }
                try? await reloadDocumentFromDisk(document)
            }
            for (pane, document) in missing {
                guard workbench.panes.contains(where: { $0.id == pane.id }),
                      pane.documents.contains(where: { $0.id == document.id }) else { continue }
                closeDocument(document.id, in: pane)
            }
            refreshPresentation()
        }
    }

    func installReloaded(_ loaded: WorkbenchDocument, onto document: WorkbenchDocument) {
        document.pendingState = loaded.pendingState
        document.isFileBacked = loaded.isFileBacked
        document.rangeReader = loaded.rangeReader
        document.text = loaded.text
        document.encoding = loaded.encoding
        document.isDirty = false
    }

    func toggleSourceControl() {
        toggleSidebarTab(.changes)
    }

    func showProblems() {
        showBottomTab(.problems)
    }

    func toggleProblems() {
        if isTerminalVisible && isBottomTabSelected(.problems) {
            hideTerminal()
        } else {
            showProblems()
        }
    }

    func cancelGradleSync() {
        projectSystems.active?.cancelSync()
    }

    func cancelGradleOperation() {
        guard let system = projectSystems.active else { return }
        if system.syncState.isSyncing {
            system.cancelSync()
        } else if !system.runningTasks.isEmpty {
            system.cancelTasks()
        }
    }

    func runGradleTask(_ taskPath: String) {
        showGradleOutput()
        projectSystems.active?.runTasks([taskPath])
    }

    func restartTerminal() {
        restartTerminalTab(selectedTerminalTabID)
    }

    /// Wipes the visible terminal's screen and scrollback; the shell redraws its prompt.
    func clearTerminal() {
        bottomPanel.requestClear()
    }

    func restartTerminalTab(_ id: UUID?) {
        if bottomPanel.requestRestart(id) { requestTerminalFocus() }
    }

    func selectNextTerminalTab() {
        if let id = bottomPanel.nextTabID() { selectTerminalTab(id) }
    }

    func selectPreviousTerminalTab() {
        if let id = bottomPanel.previousTabID() { selectTerminalTab(id) }
    }

    func updateTerminalTabTitle(_ id: UUID, title: String) {
        bottomPanel.updateTitle(id, to: title)
    }

    func updateTerminalTabDirectory(_ id: UUID, url: URL) {
        bottomPanel.updateDirectory(id, to: url)
    }

    func requestTerminalFocus() {
        bottomPanel.requestFocus()
    }

    /// Opens a Go to Definition target. A file already open is focused without reloading it, so a
    /// dirty buffer keeps the user's edits. JDK and dependency sources extracted into the index
    /// cache are ordinary files the read-only check in ``applyState`` then locks.
    @discardableResult
    func openNavigationLocation(_ location: Location) -> Bool {
        switch location.target {
        case .source:
            break
        case .directory:
            if let url = location.url { revealInExplorer(url) }
            return true
        case .package(let name):
            showLibraryPackage(name)
            return true
        }
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
                // Through `selectTab`, so the tab strip and the active pane follow the jump.
                selectTab(document.id, in: pane.id)
                reveal(nsRange, of: document.id, in: host(for: pane.id))
                return true
            }
            Task { await openDocument(from: url, selecting: nsRange) }
            return true
        }
        current.textView.selectedRange = nsRange
        current.textView.scrollRangeToCenter(nsRange)
        _ = current.textView.focusTextInput()
        return true
    }

    /// Opens the file behind a Problems row with the problem selected. The range comes from the
    /// diagnostic's line and column resolved against the file's text, not its `utf16Offset`, which
    /// providers don't all fill in as an absolute offset.
    func openProblem(_ row: ProblemRow) {
        let text = openBufferText(for: row.url)
            ?? (try? String(contentsOf: row.url, encoding: .utf8))
            ?? ""
        let nsRange = ProblemLocator.nsRange(for: row.diagnostic.range, in: text)
        let start = TextPosition(line: row.diagnostic.range.start.line, column: row.diagnostic.range.start.column, utf16Offset: nsRange.location)
        let end = TextPosition(line: row.diagnostic.range.end.line, column: row.diagnostic.range.end.column, utf16Offset: nsRange.location + nsRange.length)
        let document = workbench.allDocuments().first { $0.url?.standardizedFileURL == row.url.standardizedFileURL }
        _ = openNavigationLocation(Location(
            documentID: document?.documentID ?? DocumentID(),
            url: row.url,
            range: EditorIntelligence.TextRange(start: start, end: end),
            displayName: row.url.lastPathComponent
        ))
    }

    /// Jumps to the next (or previous) error or warning after the caret, across files, wrapping
    /// around (F2 / ⇧F2 in the IntelliJ keymap). It walks the same list the Problems tab shows.
    func goToProblem(forward: Bool) {
        let host = host(for: workbench.activePane.id)
        let textView = host.textView
        let location = textView.textLocation(at: textView.selectedRange.location)
        let position = ProblemNavigator.Position(
            url: workbench.activePane.selectedDocument?.url?.standardizedFileURL,
            line: location?.lineNumber ?? 0,
            column: location?.column ?? 0
        )
        let severities = ProblemNavigator.severities(for: preferences.nextErrorScope, in: problems.files)
        guard let row = ProblemNavigator.step(from: position, forward: forward, in: problems.files, severities: severities) else {
            host.intelligenceController?.showHint(problems.errorCount + problems.warningCount == 0
                                                  ? "No problems" : "No more problems")
            return
        }
        openProblem(row)
    }

    /// A file's directory relative to the open project (or abbreviated home) for compact display.
    func displayDirectory(of url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        if let root = project.rootURL?.standardizedFileURL.path, directory.hasPrefix(root) {
            let relative = String(directory.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "" : relative
        }
        return (directory as NSString).abbreviatingWithTildeInPath
    }

    func presentNavigationChoices(_ locations: [Location], kind: NavigationKind = .definition) {
        if kind == .references, locations.contains(where: { $0.usage != nil }) {
            usages.show(locations)
            showBottomTab(.usages)
            return
        }
        guard let paletteController else {
            if let first = locations.first {
                _ = openNavigationLocation(first)
            }
            return
        }
        let items = locations.map { location -> (title: String, subtitle: String?) in
            // The file with its folder, so two classes named alike in different packages are told apart.
            let subtitle = location.target != .source ? nil : location.url.map { url in
                let folder = url.deletingLastPathComponent().lastPathComponent
                return folder.isEmpty ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
            }
            return (location.displayName, subtitle)
        }
        paletteController.presentList(title: Self.navigationChoicesTitle(for: kind), items: items) { [weak self] index in
            guard let self, locations.indices.contains(index) else { return }
            _ = self.openNavigationLocation(locations[index])
        }
    }

    private static func navigationChoicesTitle(for kind: NavigationKind) -> String {
        switch kind {
        case .definition: return "Go to Definition"
        case .implementation: return "Go to Implementation"
        case .superMethod: return "Go to Super Method"
        case .typeDefinition: return "Go to Type Declaration"
        case .siblings: return "Show Siblings"
        case .references: return "Find Usages"
        }
    }

    /// Selects and centers `range` in `document` once `host` shows it: now when it is loaded,
    /// otherwise when its text is applied.
    private func reveal(_ range: NSRange, of documentID: UUID, in host: IDEEditorPaneHost) {
        guard host.loadedDocumentID == documentID else {
            host.pendingReveal = (documentID, range)
            return
        }
        host.pendingReveal = nil
        host.textView.selectedRange = range
        host.textView.scrollRangeToCenter(range)
        _ = host.textView.focusTextInput()
    }

    /// The tab showing `url`, in the active pane first so a jump stays in the pane it started from.
    func paneAndDocument(matching url: URL) -> (EditorPane, WorkbenchDocument)? {
        let path = url.standardizedFileURL.path
        let panes = workbench.panes.sorted { lhs, _ in lhs.id == workbench.activePaneID }
        for pane in panes {
            if let document = pane.documents.first(where: { $0.url?.standardizedFileURL.path == path }) {
                return (pane, document)
            }
        }
        return nil
    }

    /// Focuses a file that is already open, without reloading it, so a dirty buffer keeps the
    /// user's edits. Selects `range` when given. Returns false when no tab shows `url`.
    @discardableResult
    func focusOpenDocument(_ url: URL, selecting range: NSRange?) -> Bool {
        guard let (pane, document) = paneAndDocument(matching: url) else { return false }
        if let range { document.selectedRange = range }
        let alreadyVisible = pane.id == workbench.activePaneID && pane.selectedDocumentID == document.id
        if alreadyVisible {
            isSettingsVisible = false
            agent.dismissPage()
            showsWelcome = false
        } else {
            selectTab(document.id, in: pane.id)
        }
        if let range {
            reveal(range, of: document.id, in: host(for: pane.id))
        } else if alreadyVisible {
            focusActiveEditor()
        }
        return true
    }

    /// Text of an open document, including unsaved edits. Nil when `url` is not open, so navigation
    /// reads the file from disk instead of an empty file-backed model.
    func openBufferText(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let document = workbench.allDocuments().first(where: { $0.url?.standardizedFileURL.path == path }) else {
            return nil
        }
        guard document.contentKind == .text else { return nil }
        let text = sourceText(for: document)
        return text.isEmpty ? nil : text
    }

    /// Open text files with edits not saved yet, by absolute path: what the agent reads and searches
    /// in place of the stale copy on disk. Clean files are left out, since disk already matches.
    func agentUnsavedBuffers() -> [String: String] {
        var buffers: [String: String] = [:]
        for document in workbench.allDocuments() where document.isDirty && document.contentKind == .text {
            guard let path = document.url?.standardizedFileURL.path else { continue }
            buffers[path] = sourceText(for: document)
        }
        return buffers
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

    /// Selects the tab after (or before) the active one in the active pane, wrapping around.
    func selectAdjacentTab(forward: Bool) {
        let pane = workbench.activePane
        let documents = pane.documents
        guard documents.count > 1,
              let current = documents.firstIndex(where: { $0.id == pane.selectedDocumentID }),
              let target = forward
                ? TabListEngine.nextIndex(after: current, count: documents.count)
                : TabListEngine.previousIndex(before: current, count: documents.count) else { return }
        selectTab(documents[target].id, in: pane.id)
    }

    /// Moves focus to the next (or previous) editor split, wrapping around, in layout order.
    func focusAdjacentPane(forward: Bool) {
        let panes = workbench.layout.flattenedPanes()
        guard panes.count > 1,
              let current = panes.firstIndex(where: { $0.id == workbench.activePaneID }),
              let target = forward
                ? TabListEngine.nextIndex(after: current, count: panes.count)
                : TabListEngine.previousIndex(before: current, count: panes.count) else { return }
        // Flush the pane being left so it keeps its caret and scroll position.
        let leaving = workbench.activePane
        if let document = leaving.selectedDocument {
            syncTextViewToDocument(host(for: leaving.id).textView, document: document, from: host(for: leaving.id))
        }
        workbench.activatePane(panes[target].id)
        activatePane(panes[target].id)
        focusActiveEditor()
    }

    /// ⌘5 in the IntelliJ keymap. There is no Debug window before a session has started.
    func toggleDebugToolWindow() {
        guard showsDebugTab else { return }
        toggleBottomToolWindow(.debug)
    }

    private struct HiddenToolWindows {
        var sidebar: Bool
        var gradle: Bool
        var bottomPanel: Bool
    }

    @ObservationIgnored private var hiddenToolWindows: HiddenToolWindows?

    /// IntelliJ's Hide All Tool Windows (⇧⌘F12): hides the sidebars and the bottom panel, and
    /// the next press brings back exactly the ones that were showing.
    func toggleAllToolWindows() {
        if let saved = hiddenToolWindows {
            isSidebarVisible = saved.sidebar
            isProjectSidebarVisible = saved.gradle
            isTerminalVisible = saved.bottomPanel
            hiddenToolWindows = nil
            saveSession()
            return
        }
        let saved = HiddenToolWindows(
            sidebar: isSidebarVisible,
            gradle: isProjectSidebarVisible,
            bottomPanel: isTerminalVisible
        )
        guard saved.sidebar || saved.gradle || saved.bottomPanel else { return }
        hiddenToolWindows = saved
        isSidebarVisible = false
        isProjectSidebarVisible = false
        isTerminalVisible = false
        isBottomPanelExpanded = false
        focusActiveEditor()
        saveSession()
    }

    public func toggleSidebar() {
        isSidebarVisible.toggle()
        focusActiveEditor()
    }

    public func toggleStructureSidebar() {
        toggleSidebarTab(.structure)
    }

    /// Shows the sidebar on `tab`, reopening it if it was closed.
    func showSidebarTab(_ tab: IDESidebarTab) {
        guard isSidebarTabAvailable(tab) else { return }
        closedSidebarTabs.remove(tab)
        selectedSidebarTab = tab
        isSidebarVisible = true
        IDESidebarTabs.descriptor(for: tab)?.onShow(self)
        saveSession()
    }

    /// Tool-window behavior (IntelliJ): the shortcut of the tab being shown hides the sidebar, the
    /// shortcut of any other tab switches to it.
    func toggleSidebarTab(_ tab: IDESidebarTab) {
        if showsSidebar && activeSidebarTab == tab {
            isSidebarVisible = false
            saveSession()
        } else {
            showSidebarTab(tab)
        }
        focusActiveEditor()
    }

    /// Reveal and create commands act on the Explorer, whatever tab the sidebar was on.
    private func showExplorer() {
        selectedSidebarTab = .explorer
        isSidebarVisible = true
    }

    func closeSidebarTab(_ tab: IDESidebarTab) {
        guard tab.isClosable else { return }
        closedSidebarTabs.insert(tab)
        if selectedSidebarTab == tab { selectedSidebarTab = .explorer }
        saveSession()
    }

    public func toggleProjectSidebar() {
        isProjectSidebarVisible.toggle()
        focusActiveEditor()
        saveSession()
    }

    /// Whether a tool-window stripe button for `tab` should read as open: the bottom panel is
    /// showing and that tab is the selected one.
    func isBottomToolWindowOpen(_ tab: IDEBottomPanelTab) -> Bool {
        isTerminalVisible && selectedBottomTab == tab
    }

    /// Tool-window stripe behavior (IntelliJ): clicking the open tab's button hides the bottom
    /// panel, clicking any other one shows the panel on that tab.
    func toggleBottomToolWindow(_ tab: IDEBottomPanelTab) {
        if isBottomToolWindowOpen(tab) {
            hideTerminal()
            return
        }
        switch tab {
        case .terminal:
            if let id = selectedTerminalTabID ?? terminalTabs.first?.id {
                selectedBottomTab = .terminal
                selectTerminalTab(id)
                if !isTerminalVisible {
                    isTerminalVisible = true
                    saveSession()
                }
            } else {
                selectedBottomTab = .terminal
                addTerminalTab()
            }
        case .sourceControl:
            showBottomTab(.sourceControl)
        case .gradle:
            showBottomTab(.gradle)
        case .http:
            showBottomTab(.http)
        default:
            selectedBottomTab = tab
            if !isTerminalVisible {
                isTerminalVisible = true
                saveSession()
            }
        }
    }

    /// Reveals a folder or file in the left Explorer, expanding ancestors as needed.
    func revealInExplorer(_ url: URL) {
        guard project.rootURL != nil else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        showExplorer()
        project.revealAndSelect(url: url, centered: false)
    }

    public func toggleMarkdownPreview() {
        // The titlebar button and ⌘B are the file's preview: a Swift file's is the SwiftUI canvas.
        if statusLanguage == "swift" {
            toggleSwiftUIPreview()
            return
        }
        adapter.textView?.perform(.toggleMarkdownPreview)
    }

    /// The play button changed on `host`. Updates the titlebar and moves the keyboard to the
    /// diagram, or back to the editor.
    private func notePreviewVisibility(of host: IDEEditorPaneHost) {
        guard hostCache.peek(workbench.activePaneID) === host else { return }
        isMarkdownPreviewVisible = host.markdownPreviewController.isVisible
        isJSONDiagramVisible = host.isJSONDiagramVisible
        isCSVTableVisible = host.isCSVTableVisible
        if host.isJSONDiagramVisible {
            host.diagramViewer.focus()
        } else if host.isCSVTableVisible {
            host.csvTableView.focus()
        } else {
            focusActiveEditor()
        }
    }

    /// Exports the currently visible markdown preview to a PDF the user picks a location for.
    /// The PDF is always light (white page, dark text), whatever the editor theme. No-op when the
    /// preview isn't shown (there's nothing rendered to export yet).
    public func exportMarkdownPreviewToPDF() {
        guard let host = hostCache.peek(workbench.activePaneID),
              host.markdownPreviewController.isVisible,
              let document = workbench.activePane.selectedDocument else { return }
        let controller = host.markdownPreviewController
        let name = (document.displayName as NSString).deletingPathExtension

        // The light diagrams are rendered before the panel opens; cached ones make this immediate.
        Task { @MainActor [weak self] in
            guard let data = await controller.exportPDFData() else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = name

            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self?.notifications.post(
                        "Could not save PDF",
                        detail: error.localizedDescription,
                        severity: .error
                    )
                    return
                }
                let folder = url.deletingLastPathComponent().lastPathComponent
                self?.notifications.post(
                    "PDF saved",
                    detail: "\(url.lastPathComponent) in \(folder)",
                    severity: .success,
                    action: .revealInFinder(url.path)
                )
            }
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

    public func toggleFocusModeToolbarFade() {
        preferences.isFocusModeToolbarFadeEnabled.toggle()
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

    public var isFocusModeToolbarFadeEnabledBinding: Binding<Bool> {
        preferenceBinding(\.isFocusModeToolbarFadeEnabled)
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

    /// A preference changed. They are shared by every window, so this repaints the editors of all of
    /// them, not only this window's: the Settings view that calls it lives in one window.
    func applyPreferencesToAllHosts() {
        IDEWindowRegistry.shared.applyPreferencesToAllWindows(including: self)
    }

    /// A Java inspection was switched or re-graded in Settings. Every window's analysis follows,
    /// without repainting any editor.
    func javaInspectionPreferencesChanged() {
        IDEWindowRegistry.shared.applyCodeInsightPreferencesToAllWindows(including: self)
    }

    /// The Swift inspection options changed (they are read when an analysis runs), so each open editor
    /// asks for its diagnostics again.
    func swiftInspectionPreferencesChanged() {
        for pane in workbench.panes {
            host(for: pane.id).intelligenceController?.refreshDiagnostics()
        }
    }

    /// Applies the preferences to the editors of this window.
    func applyPreferencesToOwnHosts() {
        for pane in workbench.panes {
            let host = host(for: pane.id)
            preferences.apply(to: host.textView, repaint: true)
            if let controller = host.intelligenceController {
                preferences.apply(to: controller)
            }
        }
        applyCodeInsightPreferences()
        if let textView = adapter?.textView {
            updateStatus(from: textView)
        }
    }

    /// The Markdown preview's light/dark look follows the stored choice in this window's open panes.
    func applyMarkdownPreviewAppearanceToOwnHosts() {
        let appearance = IDEMarkdownPreviewAppearance.stored
        for pane in workbench.panes {
            hostCache.peek(pane.id)?.markdownPreviewController.appearanceOverride = appearance
        }
    }

    /// The code-insight settings that live below the text views: how soon typing triggers a re-read
    /// of the document, and how Java's Suppress fixes silence a warning.
    /// Directories of the synced Gradle test source sets; files in them are tests for scoped
    /// inspection settings (without a model, a `src/test` path still counts).
    var javaTestSourceRoots: [URL] {
        (javaSupport.projectModel?.subprojects ?? []).flatMap(\.testSourceDirs)
    }

    func applyCodeInsightPreferences() {
        adapter?.contentRefreshDebounce = TimeInterval(preferences.autoreparseDelayMilliseconds) / 1000
        javaSupport.applyCodeInsightPreferences(
            autoreparseDelay: .milliseconds(preferences.autoreparseDelayMilliseconds),
            suppressionStyle: preferences.javaSuppressWithComment ? .comment : .annotation,
            inspectionProfile: inspections.activeProfile,
            projectRoot: project.rootURL,
            testRoots: javaTestSourceRoots,
            importPolicy: preferences.javaImportPolicy,
            postfix: preferences.javaPostfix
        )
        // The Swift choices of the same profile; open editors analyse again only when they changed.
        if swiftSupport.inspectionResolver.update(profile: inspections.activeSwiftProfile, root: project.rootURL) {
            swiftInspectionPreferencesChanged()
        }
    }

    /// The options the Swift inspections run with for the file at `url` under this window's active profile.
    func swiftInspectionOptions(for url: URL?) -> SwiftInspectionOptions {
        swiftSupport.inspectionResolver.options(for: url)
    }

    func refreshUIColorScheme() {
        uiColorSchemeEpoch += 1
        for pane in workbench.panes {
            let host = host(for: pane.id)
            host.textView.backgroundColor = IDEAppearance.NSToken.editor
            host.layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
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
                    openProjectFolder(url)
                } else {
                    await openDocument(from: url)
                }
            }
        }
    }

    func selectTab(_ id: UUID, in paneID: UUID? = nil) {
        isSettingsVisible = false
        agent.dismissPage()
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

    /// Replaces the tab's content with what is on disk. A tab with unsaved edits asks first,
    /// since they cannot be recovered. Every pane showing the document is refreshed.
    ///
    /// With `encoding` the file is read again in that encoding instead of the one it was opened in.
    func reloadTabFromDisk(_ id: UUID, in paneID: UUID, encoding: TextFileEncoding? = nil) {
        guard let pane = workbench.layout.findPane(id: paneID),
              let document = pane.documents.first(where: { $0.id == id }),
              document.url != nil else { return }
        if document.contentKind == .binary {
            if document.isDirty {
                var alert = IDEAlert.confirm(
                    "Reload \(document.displayName) from disk?",
                    detail: "This discards your unsaved changes to \(document.displayName). It cannot be undone.",
                    confirm: "Reload", isDestructive: true)
                guard alert.confirms() else { return }
            }
            Task { await reloadHexFromDisk(document) }
            return
        }
        guard document.contentKind == .text else { return }
        if document.isDirty {
            var alert = IDEAlert.confirm(
                encoding.map { "Reopen \(document.displayName) as \($0.displayName)?" } ?? "Reload \(document.displayName) from disk?",
                detail: "This discards your unsaved changes to \(document.displayName). It cannot be undone.",
                confirm: encoding == nil ? "Reload" : "Reopen", isDestructive: true)
            guard alert.confirms() else { return }
        }
        Task {
            do {
                try await reloadDocumentFromDisk(document, encoding: encoding)
            } catch DocumentLoadError.invalidEncoding where encoding != nil {
                presentError(IDEEncodingError.cannotDecode(document.displayName, encoding?.displayName ?? ""))
            } catch {
                presentError(error)
            }
        }
    }

    /// Reads the active file again in `encoding` ("Reopen with Encoding").
    func reopenActiveDocument(with encoding: TextFileEncoding) {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument else { return }
        reloadTabFromDisk(document.id, in: pane.id, encoding: encoding)
    }

    /// Renames the tab's underlying file on disk (or, for an unsaved document, just its
    /// in-memory display name) via a simple name-prompt alert.
    func renameTab(_ id: UUID, in paneID: UUID) {
        guard let pane = workbench.layout.findPane(id: paneID),
              let document = pane.documents.first(where: { $0.id == id }) else { return }

        guard let newName = IDEAlert.promptForText(
            "Rename File", initial: document.displayName, confirm: "Rename", width: 260) else { return }
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
        sidebarWidth: Double? = nil,
        projectSidebarWidth: Double? = nil,
        terminalHeight: Double? = nil
    ) -> IDEWindowSession {
        let shells = terminalTabs.filter { $0.agentCommandID == nil }
        let selectedShell = shells.contains { $0.id == selectedTerminalTabID } ? selectedTerminalTabID : shells.first?.id
        syncLiveTextForSession()
        return IDEWindowSession(
            restoration: hasOpenDocuments ? workbench.makeRestorationState() : nil,
            projectRootBookmark: project.makeBookmarkData(),
            sidebarWidth: sidebarWidth ?? self.sidebarWidth,
            isSidebarVisible: isSidebarVisible,
            projectSidebarWidth: projectSidebarWidth ?? self.projectSidebarWidth,
            isProjectSidebarVisible: isProjectSidebarVisible,
            isTerminalVisible: isTerminalVisible,
            terminalHeight: terminalHeight ?? self.terminalHeight,
            terminalTabs: shells.isEmpty ? nil : shells,
            selectedTerminalTabID: selectedShell,
            sidebarTab: selectedSidebarTab,
            closedSidebarTabs: closedSidebarTabs.sorted { $0.rawValue < $1.rawValue },
            isAgentPanelVisible: agent.isPanelVisible && !agent.settings.opensAsPage,
            agentPanelWidth: agentPanelWidth,
            agentChats: agent.restorableTabs.ids,
            agentSelectedChat: agent.restorableTabs.selected,
            windowMode: windowMode,
            aiTab: aiTab,
            isAIInspectorVisible: showsAIInspector,
            aiInspectorTab: aiInspectorTab,
            aiInspectorWidth: aiInspectorWidth
        )
    }

    /// A session stores a tab's text from `WorkbenchDocument.text`, which the live editor only
    /// refreshes after a debounce or when its tab is left. Quitting soon after an edit would
    /// otherwise restore the text the tab had before it. File-backed tabs store no text.
    ///
    /// Not gated on the buffer generation: other paths (mirroring edits to a split) advance
    /// `loadedBufferGeneration` without writing `document.text`, which hid stale text here.
    private func syncLiveTextForSession() {
        for pane in workbench.panes {
            guard let document = pane.selectedDocument,
                  document.contentKind == .text,
                  !document.isFileBacked,
                  let host = hostCache.peek(pane.id),
                  host.loadedDocumentID == document.id
            else { continue }
            syncTextViewToDocument(host.textView, document: document, from: host)
        }
    }

    func saveSession(
        sidebarWidth: Double? = nil,
        projectSidebarWidth: Double? = nil,
        terminalHeight: Double? = nil
    ) {
        // Recents and preferences are shared, so any window may write them; the window layout
        // goes to `last-window.json` only from the session window (see `IDEWindowRegistry`), or a
        // background window (a finished Gradle sync) would replace the one the user works in.
        guard !isTornDown, Self.isSessionPersistenceEnabled else { return }
        appState.save()
        guard IDEWindowRegistry.shared.isSessionWindow(self) else { return }
        IDEWindowSessionStore.save(makeSession(
            sidebarWidth: sidebarWidth,
            projectSidebarWidth: projectSidebarWidth,
            terminalHeight: terminalHeight
        ))
    }

    /// The window is closing. The last window that would be restored forgets its folder, so a Dock
    /// click opens the Welcome screen. While quitting, the session window writes that same session
    /// here, because it may already be gone by `applicationWillTerminate`.
    func saveSessionForWindowClose() {
        guard !isTornDown, Self.isSessionPersistenceEnabled else { return }
        let registry = IDEWindowRegistry.shared
        // Quit writes the closed-folder session from here too: the windows can finish closing
        // before `applicationWillTerminate`, and by then nothing is left to save.
        if registry.isTerminating {
            if registry.isSessionWindow(self) {
                saveSessionForgettingFolder()
            }
            return
        }
        if registry.forgetsFolderWhenClosing(self) {
            saveSessionForgettingFolder()
        } else {
            saveSession()
        }
    }

    /// Writes this window's layout with the folder closed. Used when the last window closes and when
    /// the app quits, so the next open does not bring the folder or its terminal directory back.
    func saveSessionForgettingFolder() {
        guard !isTornDown, Self.isSessionPersistenceEnabled else { return }
        appState.save()
        IDEWindowSessionStore.save(
            makeSession().closingFolder(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        )
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

    func seedPanelWidths(from session: IDEWindowSession) {
        sidebarWidth = session.sidebarWidth
        projectSidebarWidth = session.projectSidebarWidth
    }

    private func loadSession(_ session: IDEWindowSession) {
        isSidebarVisible = false
        selectedSidebarTab = session.sidebarTab ?? .explorer
        closedSidebarTabs = Set(session.closedSidebarTabs ?? []).subtracting([.explorer])
        seedPanelWidths(from: session)
        isProjectSidebarVisible = session.isProjectSidebarVisible
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
        // A bookmark that no longer resolves falls back to the most recent project. No bookmark
        // means the folder was closed, so nothing is reopened.
        var restoredRoot = project.rootURL(from: session.projectRootBookmark)
        if restoredRoot == nil, session.projectRootBookmark != nil {
            restoredRoot = recentProjects.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        applyProjectRoot(restoredRoot)
        if hasOpenProject {
            // A reopened project shows its Explorer, as Open Folder does.
            isSidebarVisible = true
            selectedSidebarTab = .explorer
        }
        agentPanelWidth = session.agentPanelWidth ?? IDEAppearance.Spacing.agentPanelWidth
        isRestoringAIMode = true
        windowMode = session.windowMode ?? .editor
        aiTab = session.aiTab ?? .code
        showsAIInspector = session.isAIInspectorVisible ?? false
        aiInspectorTab = session.aiInspectorTab ?? .changes
        aiInspectorWidth = session.aiInspectorWidth ?? IDEAIInspector.defaultWidth
        isRestoringAIMode = false
        if hasOpenProject {
            // Restoring is not a change worth saving: the rest of the window is not back yet.
            agent.withoutLayoutNotifications {
                agent.restoreTabs(session.agentChats ?? [], selected: session.agentSelectedChat)
                agent.isPanelVisible = session.isAgentPanelVisible == true && !agent.settings.opensAsPage
            }
        }

        if let restoration = session.restoration {
            workbench.restore(from: restoration, languageResolver: IDELanguageSupport.languageResolver)
            // Restored files were not opened through `openDocument`, so give each its starting point too.
            for document in workbench.allDocuments() where document.contentKind == .text {
                if let url = document.url { localHistory.recordBaseline(url) }
            }
            Task {
                try? await workbench.reloadFileBackedDocuments(
                    languageResolver: IDELanguageSupport.fileBackedLanguageResolver,
                    languageProvider: Self.languageProvider
                )
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
        host.intelligenceController?.inlayHintsEnabled = preferences.areInlayHintsEnabled
        host.intelligenceController?.onOpenInlineCompletionSettings = { [weak self] in
            self?.showSettings()
        }
        host.intelligenceController?.onOpenLocationInOtherDocument = { [weak self] location in
            self?.openNavigationLocation(location) ?? false
        }
        host.intelligenceController?.onPresentNavigationChoices = { [weak self] kind, locations in
            self?.presentNavigationChoices(locations, kind: kind)
        }
        host.intelligenceController?.onHoverAction = { [weak self] action in
            self?.handleHoverAction(action)
        }
        host.intelligenceController?.onNavigationSearchStarted = { [weak self] kind, cancel in
            guard kind == .references, let self else { return }
            self.usages.beginSearch(cancel: cancel)
            self.showBottomTab(.usages)
        }
        host.intelligenceController?.onNavigationSearchFinished = { [weak self] kind in
            guard kind == .references else { return }
            self?.usages.finishSearch()
        }
        // `host` must be weak: it owns the text view that stores this closure.
        host.textView.contextMenuItemsProvider = { [weak self, weak host] context in
            guard let self, let host else { return [] }
            let url = self.workbench.layout.findPane(id: paneID)?.selectedDocument?.url
            return self.editorContextMenuItems(context: context, paneID: paneID, url: url)
                + self.copyReferenceContextMenuItems(context: context, paneID: paneID, url: url)
                + self.diffContextMenuItems(url: url)
                + self.diagramContextMenuItems(url: url)
                + self.inspectionContextMenuItems(url: url)
                + self.formatDocumentContextMenuItems(textView: host.textView, paneID: paneID)
                + self.agentContextMenuItems(context: context, textView: host.textView, url: url)
                + self.textToolsContextMenuItems(context: context, textView: host.textView)
                + self.localHistoryContextMenuItems(url: url)
        }
        host.wireMarkdownPreview { [weak self, weak host] in
            guard let self, let host else { return }
            self.notePreviewVisibility(of: host)
        }
        host.markdownPreviewController.showsAppearanceToggle = true
        host.markdownPreviewController.appearanceOverride = IDEMarkdownPreviewAppearance.stored
        host.markdownPreviewController.onAppearanceOverrideChange = { [weak self] appearance in
            IDEMarkdownPreviewAppearance.stored = appearance
            guard let self else { return }
            IDEWindowRegistry.shared.applyMarkdownPreviewAppearanceToAllWindows(including: self)
        }
        host.onCSVTableClosed = { [weak self, weak host] in
            guard let self, let host else { return }
            self.notePreviewVisibility(of: host)
        }
        host.wireHTTPActions(sendRequest: { [weak self] in
            self?.sendActiveHTTPRequest()
        })
        host.wireProblemNavigation { [weak self] forward in
            self?.goToProblem(forward: forward)
        }
        host.wireSelectIn { [weak self] in
            self?.showSelectIn()
        }
        // Find in Files (⌘⇧F) gets Umbra's own bottom panel rather than the built-in palette
        // mode; Go to Line needs no host wiring at all — `CommandPaletteController` handles
        // `.goToLine` natively.
        host.intelligenceController?.onRequestProjectSearch = { [weak self] in
            self?.showFindInFiles()
            return true
        }
        host.intelligenceController?.onRequestTypeHierarchy = { [weak self] in
            self?.showTypeHierarchy() ?? false
        }
        host.intelligenceController?.onRequestMethodHierarchy = { [weak self] in
            self?.showMethodHierarchy() ?? false
        }
        host.intelligenceController?.onRequestCallHierarchy = { [weak self] in
            self?.showCallHierarchy() ?? false
        }
        host.intelligenceController?.onCodeActionCommand = { [weak self] command in
            self?.performCodeActionCommand(command)
        }
        host.intelligenceController?.diagnosticTitleProvider = { source, code in
            IDEWorkspace.diagnosticTitle(source: source, code: code)
        }
        host.intelligenceController?.onRequestRename = { [weak self, weak host] target, completion in
            guard let self, let textView = host?.textView else { return completion(nil) }
            self.renamePrompt.present(target: target, in: textView, completion: completion)
        }
        host.intelligenceController?.onPresentRenamePlan = { [weak self] plan, apply in
            self?.presentRenamePreview(plan, apply: apply)
        }
        host.intelligenceController?.onPresentWorkspaceEditPlan = { [weak self] plan, apply in
            self?.presentWorkspaceEditPreview(plan, apply: apply)
        }
        host.intelligenceController?.onRequestRefactoringName = { [weak self, weak host] title, suggested, validate, completion in
            guard let self, let textView = host?.textView else { return completion(nil) }
            self.refactoringNamePrompt.present(
                title: title, suggestedName: suggested, in: textView, validate: validate, completion: completion
            )
        }
        host.intelligenceController?.onRequestRefactoringParameters = { [weak self, weak host] descriptor, completion in
            guard let self, let textView = host?.textView else { return completion(nil) }
            // Swift edits a whole parameter list; Java's form adds or removes one.
            if descriptor.parameterKeys == ["parameters"] {
                self.swiftSignaturePrompt.present(descriptor: descriptor, in: textView, completion: completion)
            } else {
                self.changeSignaturePrompt.present(descriptor: descriptor, in: textView, completion: completion)
            }
        }
        host.intelligenceController?.onRequestGeneration = { [weak self, weak host] menu, completion in
            guard let self, let textView = host?.textView else { return completion(nil) }
            self.generatePrompt.present(menu: menu, in: textView, completion: completion)
        }
        host.intelligenceController?.onApplyWorkspaceEdit = { [weak self] edit in
            guard let self else { return WorkspaceEditApplyResult() }
            return await self.historyRecordingApplier(named: "Refactoring").apply(edit)
        }
        host.intelligenceController?.onBreadcrumbsUpdated = { [weak self] segments in
            self?.applySymbolBreadcrumbs(segments)
        }
        host.intelligenceController?.onDiagnosticsUpdated = { [weak self] report in
            self?.applyEditorDiagnostics(report)
        }
        host.intelligenceController?.onWorkspaceEditApplied = { [weak self] result in
            self?.refreshAfterWorkspaceEdit(result)
        }
        _ = sharedPalette(for: host)
        preferences.apply(to: host.textView)
        if let controller = host.intelligenceController {
            preferences.apply(to: controller)
        }
        applyCodeInsightPreferences()
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

    /// Loads `url` as an image, a hex document, or a text document, not yet attached to any pane.
    ///
    /// - Parameters:
    ///   - encoding: Read the file in exactly this encoding; bytes that do not fit are an error.
    ///   - preferredEncoding: The encoding the file was last read in. It is tried first, and a file
    ///     that no longer fits it (changed on disk) is detected afresh.
    ///   - openAsHex: Skip classification and open the bytes.
    ///   - openAsText: Skip classification and open as text, falling back to Latin-1.
    func loadDocument(
        from url: URL,
        encoding: TextFileEncoding? = nil,
        preferring preferredEncoding: TextFileEncoding? = nil,
        openAsHex: Bool = false,
        openAsText: Bool = false
    ) async throws -> WorkbenchDocument {
        let settings = IDEHexSettings.shared
        let classification = BinaryContentDetector.classify(url)
        let needsHead = !openAsHex && !openAsText
            && !ImageContentDetector.isImageFile(url)
            && classification == .unknown
            && settings.sniffUnknownFiles
        let head: Data? = needsHead ? IDEHexRouting.readHead(url) : nil
        switch IDEHexRouting.route(
            url: url, head: head, settings: settings, openAsHex: openAsHex, openAsText: openAsText
        ) {
        case .image:
            return WorkbenchDocument.loadImage(from: url)
        case .hex(let sniffed):
            if sniffed { hexSniffedPaths.insert(url.path) }
            return WorkbenchDocument.loadBinary(from: url)
        case .text:
            do {
                return try await loadTextDocument(from: url, encoding: encoding, preferring: preferredEncoding)
            } catch DocumentLoadError.invalidEncoding {
                if encoding != nil { throw DocumentLoadError.invalidEncoding }
                if openAsText {
                    guard let latin1 = TextFileEncoding.named("latin1") else { throw DocumentLoadError.invalidEncoding }
                    return try await loadTextDocument(from: url, encoding: latin1, preferring: nil)
                }
                let ext = url.pathExtension.lowercased()
                if !ext.isEmpty, settings.forceTextExtensions.contains(ext) {
                    throw DocumentLoadError.invalidEncoding
                }
                if classification == .binary, !settings.openBinaryAsHex {
                    throw DocumentLoadError.invalidEncoding
                }
                if classification == .unknown, !settings.sniffUnknownFiles {
                    throw DocumentLoadError.invalidEncoding
                }
                if classification == .unknown {
                    // The head looked like text (a BOM or low-control bytes) but the text loader
                    // still refused it. Keep the tab text, via Latin-1, which accepts every byte.
                    if let head, !BinaryContentDetector.looksBinary(head),
                       let latin1 = TextFileEncoding.named("latin1") {
                        return try await loadTextDocument(from: url, encoding: latin1, preferring: nil)
                    }
                    hexSniffedPaths.insert(url.path)
                }
                // A known text type that cannot be decoded opens as hex. No sniff banner: the
                // name already said text, and the bytes are what failed.
                return WorkbenchDocument.loadBinary(from: url)
            }
        }
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
        // A Flight Recorder file is only useful through the profiler. Reopen as Hex reaches the bytes
        // through `loadDocument(openAsHex:)`, which this does not intercept.
        if IDEWorkspace.isFlightRecording(url) {
            recordRecentFile(url)
            openProfile(file: url)
            return
        }
        do {
            let document = try await loadDocument(from: url)
            if inRightSplit {
                activatePaneToTheRight()
            }
            workbench.openDocument(document)
            if document.contentKind == .text { localHistory.recordBaseline(url) }
            if let range, document.contentKind == .text, let selected = workbench.activePane.selectedDocument {
                selected.selectedRange = range
            }
            recordRecentFile(url)
            isSettingsVisible = false
            agent.dismissPage()
            showsWelcome = false
            rebuildLayoutHosts()
            activatePane(workbench.activePaneID)
            if let range, document.contentKind == .text, let selectedID = workbench.activePane.selectedDocumentID {
                reveal(range, of: selectedID, in: host(for: workbench.activePaneID))
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
    /// The documents of open `.java` files: their members come from the project index, so the
    /// Symbols tab leaves their tree-sitter symbols out.
    private func openJavaDocumentIDs() -> Set<DocumentID> {
        Set(workbench.allDocuments().compactMap { $0.url?.pathExtension == "java" ? $0.documentID : nil })
    }

    /// Opens a member found by project-wide Go to Symbol. The index holds no positions, so the file
    /// as it is now (the editor's text when it is open) is searched by owner, name and parameter
    /// types; a member that has since gone opens its class instead.
    private func openJavaMember(_ member: JavaMemberMatch, inRightSplit: Bool) {
        let live = openBufferText(for: member.url)
        Task {
            let range = await Task.detached { Self.memberSelection(member, liveText: live) }.value
            await openDocument(from: member.url, selecting: range, inRightSplit: inRightSplit)
        }
    }

    nonisolated private static func memberSelection(_ member: JavaMemberMatch, liveText: String?) -> NSRange? {
        guard let source = liveText ?? (try? String(contentsOf: member.url, encoding: .utf8)),
              let bytes = JavaMemberLocator.nameRange(of: member, in: source) else { return nil }
        let utf8 = Array(source.utf8)
        guard bytes.upperBound <= utf8.count else { return nil }
        let location = String(decoding: utf8[..<bytes.lowerBound], as: UTF8.self).utf16.count
        let length = String(decoding: utf8[bytes], as: UTF8.self).utf16.count
        return NSRange(location: location, length: length)
    }

    /// Opens a declaration the TypeScript index reported, selecting its name. The byte range is UTF-8.
    func openIndexedDeclaration(in url: URL, utf8NameRange: Range<Int>, inRightSplit: Bool) {
        openClassDeclaration(in: url, utf8NameRange: utf8NameRange, inRightSplit: inRightSplit)
    }

    /// Opens `url` with the caret at a place a language server named: a zero-based line and a UTF-16
    /// offset in it, as `workspace/symbol` reports them.
    func openServerSymbol(in url: URL, line: Int, character: Int, inRightSplit: Bool) {
        Task {
            let range = await Task.detached { Self.utf16Range(ofLine: line + 1, column: character + 1, in: url) }.value
            await openDocument(from: url, selecting: range, inRightSplit: inRightSplit)
        }
    }

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

    /// An empty range at a 1-based line and column, clamped to the file's last line and to the
    /// line's end; `nil` when the file can't be read as text.
    nonisolated static func utf16Range(ofLine line: Int, column: Int, in url: URL) -> NSRange? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return utf16Range(ofLine: line, column: column, in: String(decoding: data, as: UTF8.self))
    }

    /// An empty range at a 1-based line and column of `text`, clamped to the last line and to that
    /// line's end. A line past the end lands on the last line.
    nonisolated static func utf16Range(ofLine line: Int, column: Int, in text: String) -> NSRange {
        let text = text as NSString
        var lineStart = 0
        var currentLine = 1
        while currentLine < line {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let next = NSMaxRange(lineRange)
            guard next < text.length, next > lineStart else { break }
            lineStart = next
            currentLine += 1
        }
        var contentEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentEnd, for: NSRange(location: lineStart, length: 0))
        let location = min(lineStart + max(column - 1, 0), contentEnd)
        return NSRange(location: location, length: 0)
    }

    func recordRecentFile(_ url: URL) {
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
        guard pane.selectedDocument?.contentKind == .text else {
            if pane.selectedDocument?.contentKind == .image {
                host.imageViewerController.focusForInteraction()
            } else if pane.selectedDocument?.contentKind == .diagram {
                host.diagramViewer.focus()
            } else if pane.selectedDocument?.contentKind == .profile {
                host.profileViewer.focus()
            } else if pane.selectedDocument?.contentKind == .binary {
                host.hexViewer.focus()
            } else {
                host.diffViewer.focus()
            }
            return true
        }
        if let location = host.textView.location(at: entry.location) {
            host.textView.selectedRange = NSRange(location: location, length: 0)
            host.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
        _ = host.textView.focusTextInput()
        return true
    }

    private func applyInspectionDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        problems.publish(DiagnosticPublication(source: .javaInspection, url: url, diagnostics: diagnostics))
        noteServiceResultFreshness(url: url, source: IDEProblemsStore.inspectionSource) { [service = javaSupport.inspectionService] document in
            await service.isFresh(document)
        }
        if workbench.activePane.selectedDocument?.url?.standardizedFileURL == url.standardizedFileURL {
            host(for: workbench.activePaneID).intelligenceController?.refreshDiagnostics()
        }
    }

    /// A build finished: list its problems and adopt them for the open editors, so a compile
    /// paints squiggles and the error stripe where the code is, not just rows in the Problems
    /// tab. Panes showing those files repaint once the rows are adopted.
    func noteBuildDiagnostics(_ diagnostics: [URL: [Diagnostic]], source: String, texts: [URL: String]) {
        problems.setBuildDiagnostics(diagnostics, source: source)
        Task {
            await javaSupport.buildDiagnostics.publish(texts: texts, diagnostics: diagnostics, source: source)
            let keys = Set(diagnostics.keys.map { $0.standardizedFileURL })
            for pane in workbench.panes {
                guard let url = pane.selectedDocument?.url?.standardizedFileURL, keys.contains(url) else { continue }
                host(for: pane.id).intelligenceController?.refreshDiagnostics()
            }
        }
    }

    /// A finished compile: list its problems, and redraw the squiggles if that file is showing.
    private func applyCompilerDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        problems.publish(DiagnosticPublication(source: .javac, url: url, diagnostics: diagnostics))
        noteServiceResultFreshness(url: url, source: IDEProblemsStore.compilerSource) { [service = javaSupport.compilerDiagnostics] document in
            await service.isFresh(document)
        }
        if workbench.activePane.selectedDocument?.url?.standardizedFileURL == url.standardizedFileURL {
            host(for: workbench.activePaneID).intelligenceController?.refreshDiagnostics()
        }
    }

    /// Records whether a just-published service result is already stale for the open file:
    /// a file edited mid-pass gets fresh diagnostics eventually, so the panel shows the
    /// published rows as pending rather than current. Only that source's flag moves; the
    /// other sources keep whatever the editor refresh last reported. A file that is not
    /// open leaves the flags alone.
    private func noteServiceResultFreshness(
        url: URL,
        source: String,
        isFresh: @escaping @Sendable (EditorIntelligence.Document) async -> Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let document = self.openJavaDocuments().first(where: {
                      $0.url?.standardizedFileURL == url.standardizedFileURL
                  })
            else { return }
            var stale = self.problems.staleSources(for: url)
            if await isFresh(document) {
                stale.remove(source)
            } else {
                stale.insert(source)
            }
            self.problems.setStaleSources(stale, for: url)
        }
    }

    /// A Gradle run ended: list the compiler errors in its output as Problems, for files open or
    /// not, and surface the tab when there are errors. Each stream is parsed on its own so a
    /// compiler message and its caret line are never split by interleaved task output.
    // MARK: Notifications

    /// Runs what clicking a notification (or its toast) points at, then closes the bell's list.
    func activate(_ notification: IDENotification) {
        notifications.setPanelPresented(false)
        notifications.dismissToast()
        switch notification.action {
        case .showGradleOutput: showGradleOutput()
        case .showMavenOutput: showMavenOutput()
        case .showSourceControl: showSourceControl()
        case .showProblems: showProblems()
        case .showCoverage: showCoverageTab()
        case .showAgentChat(let id):
            agent.select(id)
            agent.showPanel()
        case .openFile(let path):
            Task { await openDocument(from: URL(fileURLWithPath: path)) }
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case nil: break
        }
    }

    func showNotifications() {
        notifications.setPanelPresented(true)
    }

    private func notifyMavenSync(_ outcome: IDEProjectSyncOutcome) {
        switch outcome {
        case .synced(let modules, let jars):
            notifications.post(
                "Maven read finished",
                detail: "\(modules) module\(modules == 1 ? "" : "s"), \(jars) dependenc\(jars == 1 ? "y" : "ies")",
                category: .maven,
                severity: .success,
                action: .showMavenOutput
            )
        case .failed(let summary):
            notifications.post("Maven read failed", detail: summary, category: .maven, severity: .error, action: .showMavenOutput)
        case .cancelled:
            notifications.post("Maven read cancelled", category: .maven, severity: .info, action: .showMavenOutput)
        }
    }

    private func notifyGradleSync(_ outcome: IDEProjectSyncOutcome) {
        switch outcome {
        case .synced(let subprojects, let jars):
            notifications.post(
                "Gradle sync finished",
                detail: "\(subprojects) module\(subprojects == 1 ? "" : "s"), \(jars) dependenc\(jars == 1 ? "y" : "ies")",
                category: .gradle,
                severity: .success,
                action: .showGradleOutput
            )
        case .failed(let summary):
            notifications.post("Gradle sync failed", detail: summary, category: .gradle, severity: .error, action: .showGradleOutput)
        case .cancelled:
            notifications.post("Gradle sync cancelled", category: .gradle, severity: .info, action: .showGradleOutput)
        }
    }

    func showTestResults() {
        showBottomTab(.testResults)
        isTerminalVisible = true
    }

    func openTestResult(_ result: IDETestCaseResult) {
        guard let file = result.sourceFile else { return }
        Task {
            await openDocument(from: file)
            if let line = result.line {
                host(for: workbench.activePaneID).textView.goToLine(line - 1, select: .beginning)
            }
        }
    }

    func runActiveJavaTests() {
        javaRun.runActiveTests()
    }

    func runTestMethod(_ method: JavaTestMethod, taskPath: String) {
        javaRun.runTestMethod(method, taskPath: taskPath)
    }

    /// A project-level Problems row was clicked: the test summary shows the results, a message
    /// with a file opens it at its line.
    func openBuildMessage(_ message: GradleProblem) {
        if message.kind == .testFailures { problems.onShowTestResults?() }
        guard let url = message.file else { return }
        let position = TextPosition(line: max(0, (message.line ?? 1) - 1), column: 0, utf16Offset: 0)
        let document = workbench.allDocuments().first { $0.url?.standardizedFileURL == url.standardizedFileURL }
        _ = openNavigationLocation(Location(
            documentID: document?.documentID ?? DocumentID(),
            url: url,
            range: EditorIntelligence.TextRange(start: position, end: position),
            displayName: url.lastPathComponent
        ))
    }

    /// The compiler was pointed at a project (or turned off): earlier results no longer apply, so
    /// start over and check what is open.
    private func compilerDidReconfigure() {
        problems.clearCompilerDiagnostics()
        problems.clearBuildDiagnostics()
        Task { await javaSupport.buildDiagnostics.clearAll() }
        host(for: workbench.activePaneID).intelligenceController?.refreshDiagnostics()
        javaSupport.compileNow(openJavaDocuments())
    }

    /// Open Java documents with the active one first, so a save reports on what the user is
    /// looking at before the rest.
    private func openJavaDocuments() -> [EditorIntelligence.Document] {
        let activeURL = workbench.activePane.selectedDocument?.url?.standardizedFileURL
        let documents = adapter?.openDocuments.filter { $0.languageIdentifier == "java" && !$0.isDependencySource } ?? []
        return documents.sorted { lhs, _ in lhs.url?.standardizedFileURL == activeURL }
    }

    /// A save drops that file's build-output problems (the in-editor check takes over) and tells
    /// every language service. Java recompiles the open Java files from ``documentsDidSave``.
    func noteDocumentSaved(_ url: URL?) {
        if let url {
            problems.clearBuildDiagnostics(for: url)
            Task { await javaSupport.buildDiagnostics.clear(url: url) }
            diskSync.noteSaved(path: url.standardizedFileURL.path)
        }
        languages.documentsDidSave(url.map { [$0] } ?? [])
        noteSwiftUIPreviewDocumentSaved(url)
    }

    func javaInlayHintsPreferenceChanged() {
        for paneID in hostedPaneIDs {
            let controller = host(for: paneID).intelligenceController
            controller?.inlayHintsEnabled = preferences.areInlayHintsEnabled
            // The kinds shown changed, which `inlayHintsEnabled` alone does not notice.
            controller?.refreshInlayHints()
        }
    }

    func javaCompilerDiagnosticsPreferenceChanged() {
        javaSupport.refreshCompilerDiagnostics()
    }

    // MARK: - Editor overlays (semantic colours, gutter markers, name index)

    func semanticHighlightingPreferenceChanged() {
        for pane in workbench.panes {
            scheduleSemanticHighlighting(host: host(for: pane.id), languageIdentifier: pane.selectedDocument?.languageIdentifier, delay: 0)
        }
    }

    /// Recolours a pane's file once typing pauses, for a language with a semantic token provider.
    /// `delay` debounces typing; opening a file or switching to one passes 0 so the semantic colours
    /// land with the first frames instead of repainting the tree-sitter ones later.
    private func scheduleSemanticHighlighting(host: IDEEditorPaneHost, languageIdentifier: String?, delay: UInt64 = 250_000_000) {
        let provider = preferences.semanticHighlighting ? languages.semanticTokens(for: languageIdentifier) : nil
        overlays.scheduleSemanticHighlighting(for: host.textView, provider: provider, delay: .nanoseconds(delay))
    }

    /// Recomputes every pane's markers: after a preference change, or when the index changed so
    /// other files' subtypes and overrides may have too.
    func javaGutterIconsPreferenceChanged() {
        for pane in workbench.panes {
            scheduleLineMarkers(host: host(for: pane.id), languageIdentifier: pane.selectedDocument?.languageIdentifier, delay: 0)
        }
    }

    /// Refreshes a pane's gutter icons once typing pauses, for a language with a line marker provider.
    private func scheduleLineMarkers(host: IDEEditorPaneHost, languageIdentifier: String?, delay: UInt64 = 400_000_000) {
        overlays.scheduleLineMarkers(
            for: host.textView,
            provider: languages.lineMarkers(for: languageIdentifier),
            kinds: preferences.enabledJavaGutterIcons,
            languageIdentifier: languageIdentifier,
            delay: .nanoseconds(delay)
        ) { [weak self, weak host] marker in
            guard let self, let host else { return }
            self.lineMarkerClicked(marker, host: host)
        }
    }

    /// ↑ goes to the super method, ↓ lists the implementations, and a sibling marker lists the
    /// interface methods it implements.
    private func lineMarkerClicked(_ lineMarker: LineMarker, host: IDEEditorPaneHost) {
        let textView = host.textView
        switch lineMarker.kind {
        case .implementing, .overriding:
            host.intelligenceController?.navigate(kind: .superMethod, atUTF16Offset: lineMarker.anchorUTF16Offset)
        case .implemented, .overridden:
            host.intelligenceController?.navigate(kind: .implementation, atUTF16Offset: lineMarker.anchorUTF16Offset)
        case .siblingInherited:
            guard let provider = languages.lineMarkers(for: workbench.activePane.selectedDocument?.languageIdentifier) else { return }
            let source = textView.text
            let url = textView.documentURL
            Task { [weak self] in
                let locations = await provider.siblingTargets(of: lineMarker, source: source, fileURL: url, documentID: DocumentID())
                guard let self else { return }
                if locations.count == 1 {
                    _ = self.openNavigationLocation(locations[0])
                } else if !locations.isEmpty {
                    self.presentNavigationChoices(locations, kind: .superMethod)
                }
            }
        case .recursiveCall:
            break
        }
    }

    /// Keeps the name index's view of an open Java file in step with its buffer, so Find Usages
    /// sees unsaved edits. Debounced; the overlay is dropped when the file's last tab closes.
    private func scheduleNameIndexOverlay(for textView: TextView, delay: UInt64 = 300_000_000) {
        guard textView.documentURL?.pathExtension == "java" else { return }
        let index = javaSupport.nameIndex
        overlays.scheduleNameIndexOverlay(for: textView, delay: .nanoseconds(delay)) { url, text in
            await index.setOverlay(url, text: text)
        }
    }

    private func scheduleSemanticHighlighting(forEditedTextView textView: TextView) {
        for pane in workbench.panes {
            let paneHost = host(for: pane.id)
            if paneHost.textView === textView {
                scheduleSemanticHighlighting(host: paneHost, languageIdentifier: pane.selectedDocument?.languageIdentifier)
                scheduleLineMarkers(host: paneHost, languageIdentifier: pane.selectedDocument?.languageIdentifier)
            }
        }
    }

    private func applyEditorDiagnostics(_ report: DiagnosticReport) {
        guard let url = workbench.allDocuments().first(where: { $0.documentID == report.documentID })?.url else { return }
        problems.setEditorDiagnostics(report.diagnostics, for: url)
        problems.setStaleSources(report.staleSources, for: url)
    }

    private func closeDocument(_ documentID: UUID, in pane: EditorPane) {
        closeDiffSession(documentID, in: pane)
        closeDiagramSession(documentID, in: pane)
        closeProfileSession(documentID, in: pane)
        let closingDocument = pane.documents.first(where: { $0.id == documentID })
        let closingURL = closingDocument?.url
        pane.closeDocument(documentID)
        let stillOpen = workbench.panes.contains { $0.documents.contains { $0.id == documentID } }
        if !stillOpen {
            if let closingDocument {
                databaseSupport.closeConsole(workbenchID: documentID, documentID: closingDocument.documentID)
            }
            closeHexSession(documentID)
            // Temporary injections die with the tab; comment injections need no cleanup.
            if let closingDocument {
                manualInjectionStore.clear(forKey: IDEManualInjectionStore.key(
                    url: closingDocument.url, displayName: closingDocument.displayName))
            }
            manualInjectionProviders.removeValue(forKey: documentID)
        }
        if let closingURL, paneAndDocument(matching: closingURL) == nil {
            problems.clearEditorDiagnostics(for: closingURL)
            // Inspections only run on open files; a closed file's rows would be stale (use Inspect
            // Code to analyse files that are not open).
            problems.setInspectionDiagnostics([], for: closingURL)
            if closingURL.pathExtension == "java" {
                let index = javaSupport.nameIndex
                Task { await index.removeOverlay(closingURL) }
            }
        }
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

    private func closeAllOpenDocuments() {
        let snapshots = workbench.panes.map { pane in
            (pane.id, pane.documents.map(\.id))
        }
        for (paneID, documentIDs) in snapshots {
            guard let pane = workbench.layout.findPane(id: paneID) else { continue }
            for documentID in documentIDs {
                closeDocument(documentID, in: pane)
            }
        }
    }

    private func dismissProjectChrome() {
        isSidebarVisible = false
        findInFiles.isVisible = false
        closeUsages()
        closeTypeHierarchy()
        closeCallHierarchy()
        closeTestResults()
        problems.clearCompilerDiagnostics()
        problems.clearBuildDiagnostics()
        Task { await javaSupport.buildDiagnostics.clearAll() }
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

    /// Orders the palette's recent files: the window's open documents first, then the
    /// global closed recents scoped to the open project. The closed list is shared by every
    /// window, so without the project filter Search Everywhere's All tab lists files from
    /// other projects. Open documents belong to the window and are always kept.
    nonisolated static func paletteRecentFiles(open: [URL], closed: [URL], root: URL?) -> [URL] {
        var seen = Set<URL>()
        var ordered: [URL] = []
        ordered.reserveCapacity(open.count + closed.count)
        for url in open {
            guard seen.insert(url).inserted else { continue }
            ordered.append(url)
        }
        guard let root else {
            for url in closed where seen.insert(url).inserted {
                ordered.append(url)
            }
            return ordered
        }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        for url in closed {
            guard seen.insert(url).inserted else { continue }
            let path = url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(prefix) else { continue }
            ordered.append(url)
        }
        return ordered
    }

    func configurePalette(_ palette: CommandPaletteController) {
        palette.recentFileEntriesProvider = { [weak self] in
            guard let self else { return [] }
            let edited = Set(self.recentlyEditedFiles)
            let openDocs = self.workbench.recentDocuments(limit: 30)
            let openURLs = openDocs.compactMap(\.url)
            let ordered = Self.paletteRecentFiles(open: openURLs, closed: self.recentFiles, root: self.project.rootURL)
            let docsByURL = Dictionary(
                openDocs.compactMap { document in document.url.map { ($0, document) } },
                uniquingKeysWith: { first, _ in first }
            )
            return ordered.map { url in
                PaletteFileEntry(
                    url: url,
                    displayName: url.lastPathComponent,
                    isEdited: (docsByURL[url]?.isDirty ?? false) || edited.contains(url),
                    status: self.paletteStatus(for: url)
                )
            }
        }
        palette.activeDocumentURLProvider = { [weak self] in
            self?.workbench.activePane.selectedDocument?.url
        }
        palette.onRemoveRecentFile = { [weak self] url in
            self?.forgetRecentFile(url)
        }
        palette.recentLocationsProvider = { [weak self] in
            self?.recentLocationEntries() ?? []
        }
        palette.recentEditedLocationsProvider = { [weak self] in
            self?.recentLocationEntries(from: self?.workbench.navigationHistory.editEntries.reversed() ?? []) ?? []
        }
        palette.onRemoveRecentLocation = { [weak self] entry in
            self?.workbench.navigationHistory.forget(url: entry.url, line: entry.line - 1)
        }
        palette.navigationDestinationsProvider = { [weak self] in
            guard let self else { return [] }
            var destinations = self.toolWindows.map { window in
                let id = window.id
                return RecentFilesDestination(
                    id: id,
                    title: window.title,
                    shortcut: window.shortcut,
                    icon: PaletteIcon(systemName: window.systemImage, tint: window.tint),
                    action: { [weak self] in self?.setToolWindow(id, open: true) },
                    close: { [weak self] in self?.setToolWindow(id, open: false) }
                )
            }
            destinations.append(
                RecentFilesDestination(
                    id: "recentLocations",
                    title: "Recent Locations",
                    shortcut: self.preferences.keymap.stroke(for: .recentLocations)?.displayString,
                    icon: PaletteIcon(systemName: "clock.arrow.circlepath", tint: .secondary),
                    action: { [weak self] in self?.showRecentLocations() }
                )
            )
            destinations.append(
                RecentFilesDestination(
                    id: "goToFile",
                    title: "Go to File",
                    shortcut: "⌘P",
                    icon: PaletteIcon(systemName: "doc.text.magnifyingglass", tint: .accent),
                    action: { [weak self] in self?.showQuickOpen() }
                )
            )
            return destinations
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
        palette.onOpenFileAtLine = { [weak self] url, target in
            guard let self else { return }
            Task {
                let range = await Task.detached {
                    Self.utf16Range(ofLine: target.line, column: target.column ?? 1, in: url)
                }.value
                await self.openDocument(from: url, selecting: range)
            }
        }
        palette.classesProvider = IDEJavaClassesPaletteProvider(
            javaIndex: intelligenceServices.javaSupport.javaIndex,
            fileIndex: { [weak self] in self?.fileIndexer.index },
            onOpen: { [weak self] url, nameRange, inSplit in
                self?.openClassDeclaration(in: url, utf8NameRange: nameRange, inRightSplit: inSplit)
            }
        )
        palette.packagesProvider = IDEJavaPackagesPaletteProvider(
            packages: { [weak self] in self?.fileIndexer.packageIndex ?? IDEJavaPackageIndex.empty },
            onReveal: { [weak self] url in self?.revealPackage(url) }
        )
        palette.symbolIndex = intelligenceServices.symbolIndex
        let membersSource = IDEJavaMembersPaletteSource(
            javaIndex: intelligenceServices.javaSupport.javaIndex,
            fileIndex: { [weak self] in self?.fileIndexer.index },
            onOpen: { [weak self] member, inSplit in self?.openJavaMember(member, inRightSplit: inSplit) }
        )
        palette.symbolsAdditionalItems = { [weak self] query, limit in
            let members = await membersSource.items(matching: query, limit: limit)
            guard let workspace = self else { return members }
            let sources = await MainActor.run {
                IDELanguageModules.all.flatMap { $0.symbolPaletteSources(for: workspace) }
            }
            var items = members
            for source in sources {
                items.append(contentsOf: await source.items(matching: query, limit: limit))
            }
            items.append(contentsOf: await MainActor.run { workspace.gitPaletteItems(matching: query, limit: limit) })
            return items
        }
        palette.symbolsExcludedDocuments = { [weak self] in await MainActor.run { self?.openJavaDocumentIDs() ?? [] } }
        palette.toolWindowEntriesProvider = { [weak self] in self?.toolWindowEntries() ?? [] }
        palette.fileStructureEntriesProvider = { [weak self] in await self?.fileStructureEntries() }
        palette.activeDocumentIDProvider = { [weak self] in self?.workbench.activePane.selectedDocument?.documentID }
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
        palette.commandRegistry.register(textToolsPaletteCommands())
        palette.commandRegistry.register([
            EditorCommand(id: "go.package", title: "Go to Package…", group: "Go",
                          action: { [weak self] in self?.showGoToPackage() }),
            EditorCommand(id: "file.newProject", title: "New Project…", group: "File",
                          action: { [weak self] in self?.showNewProject() }),
            EditorCommand(id: "file.saveAll", title: "Save All", group: "File",
                          action: { [weak self] in Task { await self?.saveAllDocuments() } }),
            EditorCommand(id: "file.reloadFromDisk", title: "Reload from Disk", group: "File",
                          action: { [weak self] in self?.reloadActiveFromDisk() }),
            EditorCommand(id: "file.reloadAllFromDisk", title: "Reload All from Disk", group: "File",
                          action: { [weak self] in Task { await self?.reloadAllFromDisk() } }),
            EditorCommand(id: "app.splitRight", title: "Split Editor Right", group: "View",
                          action: { [weak self] in self?.splitRight() }),
            EditorCommand(id: "app.splitDown", title: "Split Editor Down", group: "View",
                          action: { [weak self] in self?.splitDown() }),
            EditorCommand(id: "app.toggleSidebar", title: "Toggle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleSidebar() }),
            EditorCommand(id: "app.toggleStructure", title: "Toggle Structure", group: "View",
                          shortcutDisplay: "⌘7",
                          action: { [weak self] in self?.toggleStructureSidebar() }),
            EditorCommand(id: "app.toggleGradleSidebar", title: "Toggle Gradle Sidebar", group: "View",
                          action: { [weak self] in self?.toggleProjectSidebar() }),
            EditorCommand(id: "app.toggleAgent", title: "Toggle Agent", group: "View",
                          action: { [weak self] in self?.toggleAgentPanel() }),
            EditorCommand(id: "app.toggleAIMode", title: "Toggle AI Mode", group: "View",
                          action: { [weak self] in self?.toggleAIMode() }),
            EditorCommand(id: "app.aiChat", title: "AI Mode: Chat", group: "View",
                          action: { [weak self] in self?.showAIMode(tab: .chat) }),
            EditorCommand(id: "app.aiCode", title: "AI Mode: Code", group: "View",
                          action: { [weak self] in self?.showAIMode(tab: .code) }),
            EditorCommand(id: "app.toggleAIInspector", title: "AI Mode: Toggle Changes, Plan and Browser Panel", group: "View",
                          action: { [weak self] in self?.toggleAIInspector() }),
            EditorCommand(id: "app.aiChanges", title: "AI Mode: Show Changes", group: "View",
                          action: { [weak self] in self?.toggleAIInspector(tab: .changes) }),
            EditorCommand(id: "app.aiPlan", title: "AI Mode: Show Plan", group: "View",
                          action: { [weak self] in self?.toggleAIInspector(tab: .plan) }),
            EditorCommand(id: "app.aiBrowser", title: "AI Mode: Show Browser", group: "View",
                          action: { [weak self] in self?.toggleAIInspector(tab: .browser) }),
            EditorCommand(id: "app.aiBrowserSelect", title: "AI Mode: Select an Element in the Browser", group: "View",
                          action: { [weak self] in self?.startAIBrowserSelecting() }),
            EditorCommand(id: "history.show", title: "Show Local History", group: "Local History",
                          action: { [weak self] in self?.showLocalHistory() }),
            EditorCommand(id: "history.recent", title: "Recent Changes", group: "Local History",
                          action: { [weak self] in self?.showLocalHistory(project: true) }),
            EditorCommand(id: "history.label", title: "Put Label on This Version…", group: "Local History",
                          action: { [weak self] in self?.putLocalHistoryLabel() }),
            EditorCommand(id: "agent.askAboutSelection", title: "Ask Agent About Selection", group: "Agent",
                          action: { [weak self] in self?.askAgentAboutActiveSelection() }),
            EditorCommand(id: "agent.runMarkdownFile", title: "Run Markdown with Agent", group: "Agent",
                          shortcutDisplay: "⌃⌘↩",
                          action: { [weak self] in self?.runActiveMarkdownWithAgent() }),
            EditorCommand(id: "agent.newConversation", title: "New Agent Chat", group: "Agent",
                          shortcutDisplay: "⌥⌘T",
                          action: { [weak self] in self?.newAgentChat() }),
            EditorCommand(id: "agent.nextChat", title: "Next Agent Chat", group: "Agent",
                          shortcutDisplay: "⌥⌘]",
                          action: { [weak self] in self?.selectAgentChat(1) }),
            EditorCommand(id: "agent.previousChat", title: "Previous Agent Chat", group: "Agent",
                          shortcutDisplay: "⌥⌘[",
                          action: { [weak self] in self?.selectAgentChat(-1) }),
            EditorCommand(id: "agent.clear", title: "Agent: Clear", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.clear) }),
            EditorCommand(id: "agent.resume", title: "Agent: Resume", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.resume) }),
            EditorCommand(id: "agent.rewind", title: "Agent: Rewind", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.rewind) }),
            EditorCommand(id: "agent.fork", title: "Agent: Fork", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.fork) }),
            EditorCommand(id: "agent.compact", title: "Agent: Compact", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.compact) }),
            EditorCommand(id: "agent.plan", title: "Agent: Plan", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.plan) }),
            EditorCommand(id: "agent.mode", title: "Agent: Mode", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.mode) }),
            EditorCommand(id: "agent.permissions", title: "Agent: Permissions", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.permissions) }),
            EditorCommand(id: "agent.model", title: "Agent: Model", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.model) }),
            EditorCommand(id: "agent.export", title: "Agent: Export", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.export) }),
            EditorCommand(id: "agent.init", title: "Agent: Init", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.initialize) }),
            EditorCommand(id: "agent.cost", title: "Agent: Cost", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.cost) }),
            EditorCommand(id: "agent.rename", title: "Agent: Rename", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.rename) }),
            EditorCommand(id: "agent.help", title: "Agent: Help", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.help) }),
            EditorCommand(id: "agent.history", title: "Agent: History", group: "Agent",
                          action: { [weak self] in self?.runAgentCommand(.history) }),
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
            EditorCommand(id: "app.toggleFocusModeToolbarFade", title: "Toggle Focus Mode Toolbar Fade", group: "View",
                          action: { [weak self] in self?.toggleFocusModeToolbarFade() }),
            EditorCommand(id: "app.showNotifications", title: "Show Notifications", group: "View",
                          action: { [weak self] in self?.showNotifications() }),
            EditorCommand(id: "app.toggleMetalRendering", title: "Use Metal Renderer", group: "View",
                          action: { [weak self] in self?.toggleMetalRendering() }),
            EditorCommand(id: "app.toggleTerminal", title: "Toggle Terminal", group: "View",
                          action: { [weak self] in self?.toggleTerminal() }),
            EditorCommand(id: "app.toggleProblems", title: "Toggle Problems", group: "View",
                          action: { [weak self] in self?.toggleProblems() }),
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
                          action: { [weak self] in self?.selectPreviousTerminalTab() })
        ])
        // Language modules add their own (Java, HTTP) where Java's used to be.
        palette.commandRegistry.register(languageModuleCommands())
        palette.commandRegistry.register([
            EditorCommand(id: "app.replaceInFiles", title: "Replace in Files…", group: "Edit",
                          action: { [weak self] in self?.showReplaceInFiles() }),
            EditorCommand(id: "app.git.pull", title: "Git: Update Project (Pull)", group: "Git",
                          action: { [weak self] in self?.pullProject() }),
            EditorCommand(id: "app.git.push", title: "Git: Push", group: "Git",
                          action: { [weak self] in self?.pushProject() }),
            EditorCommand(id: "app.git.fileHistory", title: "Git: Show History for File", group: "Git",
                          action: { [weak self] in self?.showFileHistory() }),
            EditorCommand(id: "app.run.inContext", title: "Run: Run in Context", group: "Run",
                          action: { [weak self] in self?.runInContext(debug: false) }),
            EditorCommand(id: "app.run.debugInContext", title: "Run: Debug in Context", group: "Run",
                          action: { [weak self] in self?.runInContext(debug: true) }),
            EditorCommand(id: "app.debug.evaluate", title: "Run: Evaluate Expression…", group: "Run",
                          action: { [weak self] in self?.showEvaluateExpression() }),
            EditorCommand(id: "app.debug.quickEvaluate", title: "Run: Quick Evaluate Expression", group: "Run",
                          action: { [weak self] in self?.quickEvaluate() }),
            EditorCommand(id: "app.git.blame", title: "Git: Toggle Blame (Annotate)", group: "Git",
                          action: { [weak self] in self?.toggleGitBlame() }),
            EditorCommand(id: "app.git.revert", title: "Git: Revert File…", group: "Git",
                          action: { [weak self] in self?.revertActiveFile() }),
            EditorCommand(id: "app.view.nextTab", title: "View: Next Tab", group: "View",
                          action: { [weak self] in self?.selectAdjacentTab(forward: true) }),
            EditorCommand(id: "app.view.previousTab", title: "View: Previous Tab", group: "View",
                          action: { [weak self] in self?.selectAdjacentTab(forward: false) }),
            EditorCommand(id: "app.view.nextSplit", title: "View: Next Editor Group", group: "View",
                          action: { [weak self] in self?.focusAdjacentPane(forward: true) }),
            EditorCommand(id: "app.view.previousSplit", title: "View: Previous Editor Group", group: "View",
                          action: { [weak self] in self?.focusAdjacentPane(forward: false) }),
            EditorCommand(id: "app.view.hideAllToolWindows", title: "View: Hide All Tool Windows", group: "View",
                          action: { [weak self] in self?.toggleAllToolWindows() }),
            EditorCommand(id: "app.view.zoomIn", title: "View: Zoom In", group: "View",
                          action: { [weak self] in self?.zoomIn() }),
            EditorCommand(id: "app.view.zoomOut", title: "View: Zoom Out", group: "View",
                          action: { [weak self] in self?.zoomOut() }),
            EditorCommand(id: "app.view.resetZoom", title: "View: Actual Size", group: "View",
                          action: { [weak self] in self?.resetZoom() }),
            EditorCommand(id: "app.terminal.clear", title: "Terminal: Clear", group: "View",
                          action: { [weak self] in self?.clearTerminal() }),
            EditorCommand(id: "app.debug.resume", title: "Debug: Resume", group: "Run",
                          action: { [weak self] in self?.debugResume() }),
            EditorCommand(id: "app.debug.pause", title: "Debug: Pause", group: "Run",
                          action: { [weak self] in self?.debugPause() }),
            EditorCommand(id: "app.debug.stepOver", title: "Debug: Step Over", group: "Run",
                          action: { [weak self] in self?.debugStepOver() }),
            EditorCommand(id: "app.debug.stepInto", title: "Debug: Step Into", group: "Run",
                          action: { [weak self] in self?.debugStepInto() }),
            EditorCommand(id: "app.debug.stepOut", title: "Debug: Step Out", group: "Run",
                          action: { [weak self] in self?.debugStepOut() }),
            EditorCommand(id: "app.debug.stop", title: "Debug: Stop", group: "Run",
                          action: { [weak self] in self?.stopDebugging() })
        ])
        syncHexPaletteCommands()
    }

    func reloadProject() {
        projectSystems.active?.reload()
    }

    /// Reloads the system the banner is about, which is the first active system whose build files
    /// changed. A Gradle-only project has one system, so this is the same reload as ``reloadProject``.
    func reloadPendingProject() {
        projectSystems.pendingReload?.reload()
    }

    func showGradleOutput() {
        showBottomTab(.gradle)
    }

    func showMavenOutput() {
        showBottomTab(.maven)
    }

    func dismissProjectReloadBanner() {
        projectSystems.pendingReload?.dismissConfigurationChanges()
    }

    /// Everything in the window that reacts to disk changes, as one subscriber list of the one
    /// watcher. Installed at bootstrap (a window with no folder still watches its open files) and
    /// again whenever the folder changes.
    private func subscribeToProjectWatcher() {
        projectWatcher.onBatch = [{ [weak self] batch in
            guard let self else { return }
            // Open files: text tabs and hex tabs, inside the folder or not.
            let openFiles = batch.paths.union(batch.openFilePaths)
            self.diskSync.handle(paths: openFiles)
            self.noteExternalChange(of: Array(openFiles))
            // The rest is about the folder; a batch of open files outside it leaves it alone.
            guard !batch.paths.isEmpty || batch.gitMetadataChanged
                || batch.gitRefsChanged || batch.gitOperationChanged
            else { return }
            self.project.applyChanges(in: batch.affectedDirectories)
            self.localHistory.recordExternalChanges(batch.paths)
            if batch.gitRefsChanged || batch.gitOperationChanged { self.gitStatus.noteRefsChanged() }
            self.gitStatus.refresh()
            self.fileIndexer.handle(batch)
            self.languages.filesDidChange(batch.paths.map { URL(fileURLWithPath: $0) })
            self.projectSystems.filesDidChange(batch.paths)
            // A teammate's change (a pull) or a hand edit of the shared inspection profile.
            if batch.paths.contains(where: { $0.hasSuffix("/" + IDEInspectionProfiles.projectRelativePath) }),
               self.inspections.reloadProjectFile() {
                self.javaInspectionPreferencesChanged()
            }
            // A teammate's change (a pull) or a hand edit of a shared run configuration.
            if batch.paths.contains(where: { $0.contains("/\(JavaProjectRunConfigurationFolder.relativePath)/") }) {
                self.refreshLastRunConfiguration()
            }
        }]
    }

    private func applyProjectRoot(_ url: URL?) {
        // One held access per window, released when the project changes or the window closes.
        projectAccess.begin(url)
        inspections.setRoot(url)
        project.setRoot(url)
        externalLibraries.clear()
        localHistory.setRoot(url)
        gitStatus.setRoot(url)
        fileIndexer.setRoot(url)
        subscribeToProjectWatcher()
        if let url { recordRecentProject(url) }
        projectWatcher.setRoot(url)
        syncTerminalWorkingDirectory()
        // The project systems first: a language reads what they decided (Java skips its whole-tree
        // index when Gradle starts from a cached model). Both are synchronous, so what follows sees them.
        projectSystems.projectDidChange(root: url)
        languages.projectDidChange(root: url)
        languageServerHost.projectDidChange(root: url, connections: intelligenceServices.languageServerConnections)
        refreshLastRunConfiguration()
        refreshBreakpoints()
        refreshBookmarks()
        loadWatches()
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
        if workbench.activePane.selectedDocument?.contentKind != .binary {
            host.intelligenceController?.refreshDiagnostics()
            host.intelligenceController?.refreshBreadcrumbs()
        }
        refreshStructure()
        updateStatus(from: host.textView)
        refreshPresentation()
        Task { await workspaceBridge.syncPane(workbench.activePane) }
    }

    func refreshPresentation() {
        activePaneID = workbench.activePaneID
        var tabs: [UUID: [IDETabRow]] = [:]
        for pane in workbench.panes {
            tabs[pane.id] = pane.documents.map { document in
                IDETabRow(
                    id: document.id,
                    title: document.displayName,
                    isDirty: document.isDirty,
                    isSelected: document.id == pane.selectedDocumentID,
                    symbolName: document.contentKind == .diagram
                        ? diagramSessions[document.id]?.request.symbolName
                        : (document.contentKind == .profile ? "flame" : nil)
                )
            }
        }
        tabsByPane = tabs
        updateUnsavedMarkers()
        let openPaths = Set(workbench.panes.flatMap(\.documents).compactMap { $0.url?.standardizedFileURL.path })
        if openPaths != openDocumentPaths { openDocumentPaths = openPaths }
        syncOpenFileRegistrations(openPaths: openPaths)
        autoRevealActiveDocumentIfNeeded()
        let activeHost = hostCache.peek(workbench.activePaneID)
        isMarkdownPreviewVisible = activeHost?.markdownPreviewController.isVisible ?? false
        isJSONDiagramVisible = activeHost?.isJSONDiagramVisible ?? false
        isCSVTableVisible = activeHost?.isCSVTableVisible ?? false
        if let document = workbench.activePane.selectedDocument, document.contentKind == .text {
            statusEncoding = document.encoding
        }
        syncHexPaletteCommands()
        noteSwiftUIPreviewActiveDocumentMayHaveChanged()
        if let document = workbench.activePane.selectedDocument {
            windowTitle = "\(document.displayName) · \(projectTitle)"
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
            windowTitle = projectTitle
            if headerContext != IDEHeaderContext() {
                headerContext = IDEHeaderContext()
            }
        }
    }

    /// Publishes the dirty dot the first time a document changes, and does nothing after that.
    private func noteActiveDocumentEdited() {
        guard let document = workbench.activePane.selectedDocument,
              var rows = tabsByPane[workbench.activePaneID],
              let index = rows.firstIndex(where: { $0.id == document.id }) else {
            return
        }
        let row = rows[index]
        let rowChanged = row.isDirty != document.isDirty
        let headerChanged = headerContext.documentID == document.id && headerContext.isDirty != document.isDirty
        guard rowChanged || headerChanged else { return }
        if rowChanged {
            rows[index] = IDETabRow(id: row.id, title: row.title, isDirty: document.isDirty, isSelected: row.isSelected, symbolName: row.symbolName)
            tabsByPane[workbench.activePaneID] = rows
            updateUnsavedMarkers()
        }
        if headerChanged {
            headerContext = IDEHeaderContext(
                documentID: headerContext.documentID,
                pathItems: headerContext.pathItems,
                symbolItems: headerContext.symbolItems,
                isDirty: document.isDirty
            )
        }
    }

    /// What a click on a breadcrumb segment opens: the folder's contents, the file's siblings, or
    /// the Java type around a symbol. `nil` means there is nothing to list, so the segment acts
    /// directly (`selectBreadcrumb`).
    func breadcrumbMenu(for item: IDEBreadcrumbItem) async -> NSMenu? {
        let open: (URL) -> Void = { [weak self] url in
            Task { await self?.openDocument(from: url) }
        }
        switch item.target {
        case .folder(let url):
            return IDEBreadcrumbMenu.directoryMenu(
                url,
                current: workbench.activePane.selectedDocument?.url,
                onOpen: open,
                onReveal: { [weak self] in self?.revealInSidebar(url) }
            )
        case .file(let url):
            return IDEBreadcrumbMenu.directoryMenu(
                url.deletingLastPathComponent(),
                current: url,
                onOpen: open,
                onReveal: { [weak self] in self?.revealInSidebar(url) }
            )
        case .package(let url):
            return IDEBreadcrumbMenu.packageMenu(
                url,
                current: workbench.activePane.selectedDocument?.url,
                node: project.node(at: url.path),
                onOpen: open,
                onReveal: { [weak self] directory in self?.revealInSidebar(directory) }
            )
        case .symbol(let range):
            return await structureBreadcrumbMenu(for: range)
        }
    }

    func selectBreadcrumb(_ item: IDEBreadcrumbItem) {
        switch item.target {
        case .folder(let url), .file(let url), .package(let url):
            revealInSidebar(url)
        case .symbol(let range):
            jumpToSymbol(range)
        }
    }

    /// The type a breadcrumb symbol names (or the type enclosing it) with all its members, the symbol
    /// checked. A language without a structure provider has no member outline here and returns `nil`.
    private func structureBreadcrumbMenu(for range: EditorIntelligence.TextRange) async -> NSMenu? {
        guard let provider = languages.structure(for: statusLanguage) else { return nil }
        let text = host(for: workbench.activePaneID).textView.text
        guard let roots = await provider.allStructure(forSource: text) else { return nil }
        let utf16Offset = min(max(range.start.utf16Offset, 0), text.utf16.count)
        // The path from a root to the segment's declaration, found by its name's start.
        guard let chain = StructureNode.path(toNameAt: utf16Offset, in: roots), let target = chain.last else { return nil }
        let container = target.kind == .type ? target : (chain.dropLast().last ?? target)
        return IDEBreadcrumbMenu.structureMenu(container, selectedID: target.id) { [weak self] node in
            self?.selectStructureNode(node)
        }
    }

    /// File Structure (⌘F12) rows for the focused file: every type and member in source order,
    /// `nil` for a language without a structure provider, so the symbol index answers.
    func fileStructureEntries() async -> [FileStructureEntry]? {
        guard let provider = languages.structure(for: statusLanguage) else { return nil }
        let textView = host(for: workbench.activePaneID).textView
        let text = textView.text
        guard let roots = await provider.allStructure(forSource: text) else { return nil }
        var entries: [FileStructureEntry] = []
        func visit(_ node: StructureNode) {
            let range = NSRange(location: node.nameRange.lowerBound, length: node.nameRange.count)
            entries.append(FileStructureEntry(
                id: node.id,
                title: node.title,
                subtitle: String(describing: node.kind),
                action: { [weak self] in self?.jumpToSymbol(range) }
            ))
            for child in node.children { visit(child) }
        }
        for root in roots { visit(root) }
        return entries
    }

    func selectStructureNode(_ node: StructureNode) {
        jumpToSymbol(NSRange(location: node.nameRange.lowerBound, length: node.nameRange.count))
    }

    func refreshStructure() {
        structureRefreshTask?.cancel()
        guard let provider = languages.structure(for: statusLanguage) else {
            if showsStructureSidebar {
                structureStore.show(message: "No outline for this file")
            }
            return
        }
        let textView = host(for: workbench.activePaneID).textView
        let text = textView.text
        let caret = textView.selectedRange.location
        structureRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard let root = await provider.structure(forSource: text, atUTF16Offset: caret) else {
                self.structureStore.show(message: "No type at the caret")
                return
            }
            self.structureStore.show(root: root, selectedID: root.deepestNode(containing: caret).id)
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
        showExplorer()
        createExplorerItem(in: directory, isDirectory: false)
    }

    /// Creates a new folder in the Explorer and starts inline rename. Shows the sidebar when hidden.
    func createExplorerFolder(in directory: URL? = nil) {
        guard let directory = directory ?? explorerCreationDirectory() else { return }
        showExplorer()
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
            finishFileRename(from: url, to: result)
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

    /// Bookkeeping after a file moved on disk: open tabs, the tree's expansion state, recents.
    private func finishFileRename(from url: URL, to result: URL) {
        retargetOpenDocuments(from: url, to: result)
        project.didMove(from: url.path, to: result.path)
        recentFiles = recentFiles.map { retargeted($0, from: url, to: result) }
        recentlyEditedFiles = recentlyEditedFiles.map { retargeted($0, from: url, to: result) }
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
        var details = "You can restore it from the Trash in Finder."
        let dirty = affected.filter { $0.document.isDirty }.count
        if dirty > 0 {
            details += " \(dirty) open editor\(dirty == 1 ? " has" : "s have") unsaved changes that will be lost."
        }
        var alert = IDEAlert.confirm(
            "Move “\(url.lastPathComponent)” to the Trash?", detail: details, confirm: "Move to Trash")
        guard alert.confirms() else { return }
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
        showExplorer()
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

    /// Go to Package lands here: the Explorer selects the directory, including a flattened package row.
    private func revealPackage(_ url: URL) {
        showExplorer()
        project.revealAndSelect(url: url, centered: true)
    }

    private func revealInSidebar(_ url: URL) {
        if project.rootURL != nil {
            showExplorer()
            project.reveal(url: url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func jumpToSymbol(_ range: EditorIntelligence.TextRange) {
        jumpToSymbol(TextEditApplicator.nsRange(for: range, in: host(for: workbench.activePaneID).textView))
    }

    private func jumpToSymbol(_ nsRange: NSRange) {
        let textView = host(for: workbench.activePaneID).textView
        textView.recordNavigationCheckpoint()
        textView.selectedRanges = [nsRange]
        textView.scrollRangeToCenter(nsRange)
        _ = textView.focusTextInput()
    }

    /// Folder crumbs leading to the active file, then the file itself. Under a Java or Kotlin
    /// source root the directories below that root collapse into dotted package crumbs.
    /// Project-relative when a folder is open; otherwise the last few parent directories.
    private func pathBreadcrumbItems(for document: WorkbenchDocument) -> [IDEBreadcrumbItem] {
        guard let url = document.url?.standardizedFileURL else { return [] }
        let directory = url.deletingLastPathComponent()
        if let rootURL = project.rootURL {
            let root = rootURL.standardizedFileURL
            let directoryPath = directory.path
            let rootPath = root.path
            if directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") {
                return IDEJavaPackages.pathItems(
                    file: url,
                    projectRoot: root,
                    knownSourceRoots: gradle.sourceRootPaths.union(maven.sourceRootPaths),
                    tree: project.rootNode
                )
            }
        }
        let fileItem = IDEBreadcrumbItem(id: "file:\(url.path)", title: url.lastPathComponent, target: .file(url))
        return ancestorFolderItems(from: directory) + [fileItem]
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
        if arguments.contains("--no-metal-deferred-present") {
            UserDefaults.standard.set(false, forKey: MetalDeferredPresent.defaultsKey)
        } else if arguments.contains("--metal-deferred-present") {
            UserDefaults.standard.set(true, forKey: MetalDeferredPresent.defaultsKey)
        }
        if arguments.contains("--sync-keystroke-parse") {
            UserDefaults.standard.set(true, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        } else if arguments.contains("--no-sync-keystroke-parse") {
            UserDefaults.standard.set(false, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        }
    }

    private func updateStatus(from textView: TextView) {
        if let document = workbench.activePane.selectedDocument, document.contentKind != .text {
            statusLine = 1
            statusColumn = 1
            switch document.contentKind {
            case .image: statusLanguage = "Image"
            case .diagram: statusLanguage = "Diagram"
            case .profile: statusLanguage = "Profile"
            case .binary: statusLanguage = "Hex"
            case .diff: statusLanguage = "Diff"
            case .text: break
            }
            statusSelectionLength = 0
            runFileCanRun = false
            runFileURL = nil
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
        statusEncoding = workbench.activePane.selectedDocument?.encoding ?? .utf8
        statusSelectionLength = range.length
        refreshJavaRunAvailability(from: textView)
        refreshHTTPSendAvailability(from: textView)
    }

    /// Writes `textView`'s live content back into `document` and bumps `document.contentGeneration`
    /// when the content actually changed, so another pane showing the same document (from a split)
    /// can tell its own loaded content is now stale. `host` is the pane host `textView` belongs to:
    /// its own content already reflects this generation, so it needs no reload for itself.
    func syncTextViewToDocument(_ textView: TextView, document: WorkbenchDocument, from host: IDEEditorPaneHost) {
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

    /// Keeps the other panes showing this document in step with an edit made in `textView`:
    /// replays the ranged edits there, or reloads them from this pane when the edit had no single
    /// range (replace all, undo of a batch) or a pane no longer matches.
    private func mirrorEdits(from textView: TextView) {
        let changes = pendingMirrorChanges.removeValue(forKey: ObjectIdentifier(textView)) ?? []
        guard hostedPaneIDs.count > 1 else { return }
        let hosts = workbench.panes.compactMap { pane in hostCache.peek(pane.id).map { (pane: pane, host: $0) } }
        guard let source = hosts.first(where: { $0.host.textView === textView }),
              let documentID = source.host.loadedDocumentID,
              let document = source.pane.selectedDocument, document.id == documentID else { return }
        let siblings = hosts.filter { $0.host !== source.host && $0.host.loadedDocumentID == documentID }
        guard !siblings.isEmpty else { return }

        var needsReload: [(pane: EditorPane, host: IDEEditorPaneHost)] = []
        for sibling in siblings {
            let applied = !changes.isEmpty && changes.allSatisfy {
                sibling.host.textView.applyMirroredEdit($0.range, replacementText: $0.replacementText)
            }
            if applied, sibling.host.textView.documentLength == textView.documentLength {
                sibling.host.markdownPreviewController.refresh()
                sibling.host.noteJSONDiagramEdited()
                sibling.host.noteCSVTableEdited()
                scheduleSemanticHighlighting(host: sibling.host, languageIdentifier: document.languageIdentifier)
            } else {
                needsReload.append(sibling)
            }
        }
        if needsReload.isEmpty {
            // Every pane holds the same buffer now, so none of them is stale: without this, the
            // next focus switch would see a newer generation and rebuild the other pane.
            document.contentGeneration &+= 1
            for entry in [source] + siblings {
                entry.host.loadedGeneration = document.contentGeneration
                entry.host.loadedBufferGeneration = entry.host.textView.contentGeneration
            }
            return
        }
        syncTextViewToDocument(textView, document: document, from: source.host)
        for sibling in needsReload {
            showDocument(in: sibling.pane, host: sibling.host)
        }
    }

    /// The freshest known text for `document`: the live content of whichever open pane's host is
    /// currently caught up with `document.contentGeneration`, then any host still showing this
    /// document (its buffer is valid even if a sibling just bumped generation), then
    /// `document.text`. File-backed documents keep `text` empty, so the host fallbacks are what
    /// stop a tab/split switch from rebuilding an empty editor.
    func sourceText(for document: WorkbenchDocument) -> String {
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

    func showDocument(
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        guard let document = pane.selectedDocument else { return }
        if document.contentKind != .profile { host.profileViewer.hide() }
        if document.contentKind == .profile {
            showProfileDocument(document, in: pane, host: host)
            return
        }
        if document.contentKind == .binary {
            showHexDocument(document, in: pane, host: host)
            return
        }
        host.hexViewer.hide()
        if document.contentKind == .image {
            host.diffViewer.hide()
            host.diagramViewer.hide()
            showImageDocument(document, in: pane, host: host)
            return
        }
        if document.contentKind == .diff {
            host.diagramViewer.hide()
            showDiffDocument(document, in: pane, host: host)
            return
        }
        if document.contentKind == .diagram {
            host.diffViewer.hide()
            showDiagramDocument(document, in: pane, host: host)
            return
        }
        host.diffViewer.hide()
        host.imageViewerController.hide()
        host.textView.languageIdentifier = document.languageIdentifier
        host.markdownPreviewController.documentBaseURL = document.url
        host.markdownPreviewController.closeIfNotMarkdown()
        host.closeJSONDiagramIfNotJSON()
        host.closeCSVTableIfNotCSV()
        if host.isJSONDiagramVisible {
            host.revealJSONDiagramIfVisible()
        } else {
            host.diagramViewer.hide()
        }
        if host.isCSVTableVisible {
            host.revealCSVTableIfVisible()
        }
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
            lineHeightMultiplier: CGFloat(preferences.lineHeightMultiplier),
            language: document.language,
            languageProvider: Self.languageProvider,
            manualInjectionProvider: manualInjectionProvider(for: document),
            generation: generation,
            isCurrent: { [host] gen in host.applyGate.matches(gen) },
            apply: { [weak self, weak host] state in
                guard let self, let host else { return }
                self.applyState(state, for: document, in: pane, host: host)
            }
        )
    }

    /// Puts a diff tab's viewer over the pane's editor, keeping the text document it replaces.
    private func showDiffDocument(
        _ document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        if let merge = mergeSessions[document.id] {
            showMergeDocument(merge, document: document, in: pane, host: host)
            return
        }
        guard let session = diffSessions[document.id] else { return }
        changeMarkers.hide(on: host.textView)
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram()
        host.hideCSVTable()
        host.imageViewerController.hide()
        host.diffViewer.onJumpToSource = { [weak self] path, line in
            self?.openDiffSource(path: path, line: line)
        }
        host.diffViewer.show(session, preferences: preferences)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            host.diffViewer.focus()
        }
    }

    /// Puts a merge tab's viewer over the pane's editor, keeping the text document it replaces.
    private func showMergeDocument(
        _ session: IDEMergeSession,
        document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        changeMarkers.hide(on: host.textView)
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram()
        host.hideCSVTable()
        host.imageViewerController.hide()
        host.diffViewer.show(session, preferences: preferences)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            host.diffViewer.focus()
        }
    }

    /// Puts a diagram tab's viewer over the pane's editor, keeping the text document it replaces.
    private func showDiagramDocument(
        _ document: WorkbenchDocument,
        in pane: EditorPane,
        host: IDEEditorPaneHost
    ) {
        guard let session = diagramSessions[document.id] else { return }
        changeMarkers.hide(on: host.textView)
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram(hidingViewer: false)
        host.hideCSVTable()
        host.imageViewerController.hide()
        host.diffViewer.hide()
        host.diagramViewer.show(session)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            host.diagramViewer.focus()
        }
    }

    /// Opens a diagram tab (already set up with its session) in the active pane.
    func presentDiagramDocument(_ document: WorkbenchDocument) {
        presentDiffDocument(document)
    }

    /// Opens a diff tab (already set up with its session) in the active pane.
    func presentDiffDocument(_ document: WorkbenchDocument) {
        workbench.openDocument(document)
        isSettingsVisible = false
        agent.dismissPage()
        showsWelcome = false
        rebuildLayoutHosts()
        activatePane(workbench.activePaneID)
        refreshPresentation()
    }

    /// Re-shows the tab bar after a diff tab's title changed.
    func refreshTabPresentation() {
        refreshPresentation()
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
        host.hideJSONDiagram()
        host.hideCSVTable()
        changeMarkers.hide(on: host.textView)
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
        let readOnlySource = document.url.map {
            JavaAttachedSources.isExtractedSource($0) || DependencySourceLocation.isGeneratedInterface($0)
        } ?? false
        host.textView.isEditable = !readOnlySource
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        host.loadedBufferGeneration = host.textView.contentGeneration
        host.textView.layoutSubtreeIfNeeded()
        if let pending = host.pendingReveal, pending.documentID == document.id {
            host.pendingReveal = nil
            host.textView.selectedRange = pending.range
            host.textView.scrollRangeToCenter(pending.range)
        }
        // `setState` above does not route through `textViewDidChange`, so a preview left open
        // from the previous document in this pane would otherwise keep showing stale content
        // until the next keystroke.
        host.markdownPreviewController.refresh()
        host.refreshJSONDiagram()
        host.refreshCSVTable()
        scheduleSemanticHighlighting(host: host, languageIdentifier: document.languageIdentifier, delay: 0)
        scheduleLineMarkers(host: host, languageIdentifier: document.languageIdentifier, delay: 0)
        scheduleNameIndexOverlay(for: host.textView, delay: 0)
        // `setState` cleared the blame column and the change spans; bring both back.
        blame.refresh(textView: host.textView, url: document.url, git: gitStatus, force: true)
        applyProfileLineHints(to: host.textView, url: document.url)
        applyBookmarkGutter(to: host, document: document)
        changeMarkers.refresh(textView: host.textView, url: document.url, git: gitStatus, force: true, delay: .zero)
        if pane.id == workbench.activePaneID {
            adapter.refreshCachedDocuments()
            if host.isJSONDiagramVisible {
                host.diagramViewer.focus()
            } else if host.isCSVTableVisible {
                host.csvTableView.focus()
            } else {
                host.textView.focusTextInputWhenReady()
            }
            host.intelligenceController?.refreshDiagnostics()
        }
    }

    /// What every language service reads from this window: the buffers the user has open, the editor's
    /// indentation, and the user's agreements. The closures hold the workspace weakly.
    private func languageEnvironment() -> LanguageEnvironment {
        LanguageEnvironment(
            openBufferText: { [navigationBuffers] url in
                await MainActor.run { navigationBuffers.workspace?.openBufferText(for: url) }
            },
            indentUnit: { await IDEPreferences.currentIndentUnit() },
            hasConsent: { [navigationBuffers] topic in
                await MainActor.run { navigationBuffers.workspace?.hasConsent(to: topic) ?? false }
            },
            requestConsent: { [navigationBuffers] topic in
                await navigationBuffers.workspace?.requestConsent(to: topic) ?? false
            }
        )
    }

}

extension IDEWorkspace: IDEWorkspaceEditHost {
    var editProjectRoot: URL? { project.rootURL }

    func editTarget(for url: URL) async -> IDEWorkspaceEditTarget {
        guard let (pane, document) = paneAndDocument(matching: url) else { return .closed }
        guard document.contentKind == .text else { return .unavailable("The file is open in a viewer, not a text editor.") }
        func liveHost() -> IDEEditorPaneHost? {
            for candidate in workbench.panes {
                if let host = hostCache.peek(candidate.id), host.loadedDocumentID == document.id { return host }
            }
            return nil
        }
        if let host = liveHost() { return .live(host.textView) }
        // Open in a background tab: bring it forward so the edit lands in its buffer and undo stack.
        pane.selectDocument(document.id)
        showDocument(in: pane, host: host(for: pane.id))
        for _ in 0..<40 {
            if let host = liveHost() { return .live(host.textView) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return .unavailable("The open tab couldn't be loaded; save or close it and try again.")
    }

    func renameFile(from url: URL, to newURL: URL) throws {
        guard let operations = fileOperations else { throw IDEWorkspaceEditApplier.Failure.noProject }
        let result = try operations.rename(url, to: newURL.lastPathComponent)
        finishFileRename(from: url, to: result)
    }

    func moveFile(from url: URL, to newURL: URL) throws {
        guard let operations = fileOperations else { throw IDEWorkspaceEditApplier.Failure.noProject }
        let result = try operations.move(url, to: newURL)
        finishFileRename(from: url, to: result)
    }

    func createFile(at url: URL, contents: String) throws {
        guard fileOperations != nil else { throw IDEWorkspaceEditApplier.Failure.noProject }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
        // Like any new file: the Explorer lists it and git status picks it up.
        Task {
            await project.refresh(directories: [url.deletingLastPathComponent().path])
            gitStatus.refresh()
        }
    }

    func deleteFile(at url: URL) throws {
        guard let operations = fileOperations else { throw IDEWorkspaceEditApplier.Failure.noProject }
        let affected = openDocuments(at: url)
        for (pane, document) in affected { closeDocument(document.id, in: pane) }
        if project.selectedPath == url.path { project.selectedPath = nil }
        project.removeExpanded(under: url.path)
        try operations.trash(url)
        Task {
            await project.refresh(directories: [url.deletingLastPathComponent().path])
            gitStatus.refresh()
        }
    }
}

extension IDEWorkspace: TextViewDelegate {
    public func textViewDidChangeSelection(_ textView: TextView) {
        updateStatus(from: textView)
        refreshStructure()
    }

    public func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
        noteJavaAutoImportPaste(change)
        guard hostedPaneIDs.count > 1 else { return }
        pendingMirrorChanges[ObjectIdentifier(textView), default: []].append(change)
    }

    public func textViewDidChange(_ textView: TextView) {
        scheduleJavaAutoImport(for: textView)
        mirrorEdits(from: textView)
        if let pane = workbench.panes.first(where: { hostCache.peek($0.id)?.textView === textView }) {
            hostCache.peek(pane.id)?.noteJSONDiagramEdited()
            hostCache.peek(pane.id)?.noteCSVTableEdited()
        }
        scheduleSemanticHighlighting(forEditedTextView: textView)
        scheduleNameIndexOverlay(for: textView)
        noteCoverageEdit(in: textView)
        refreshJavaRunAvailability(from: textView)
        refreshStructure()
        recordRecentlyEdited()
        // The tab dot and window chrome do not change on the second character. Rebuilding every
        // tab row here re-renders the SwiftUI shell, which lays the editor out again.
        noteActiveDocumentEdited()
        autosave.noteEdit()
        changeMarkers.refresh(textView: textView, url: textView.documentURL, git: gitStatus)
    }

    /// A multi-character replacement that equals the pasteboard is a paste. One character never
    /// reads the pasteboard. The planner runs later, from ``textViewDidChange(_:)``.
    private func noteJavaAutoImportPaste(_ change: TextContentChange) {
        guard change.replacementText.utf16.count > 1,
              change.replacementText == NSPasteboard.general.string(forType: .string) else { return }
        javaAutoImportPaste = change.replacementText
    }

    /// After a pause, import the one class that resolves a name in this Java buffer. The keystroke
    /// itself only cancels the previous pause. Parsing and `textView.text` happen once it has elapsed.
    private func scheduleJavaAutoImport(for textView: TextView) {
        if javaAutoImportApplying {
            javaAutoImportPaste = nil
            return
        }
        let paste = javaAutoImportPaste
        javaAutoImportPaste = nil
        guard textView.languageIdentifier == "java" else { return }
        let policy = preferences.javaImportPolicy
        let pasting = paste != nil && policy.insertImportsOnPaste == .always
        guard policy.addUnambiguousImportsOnTheFly || pasting else { return }
        let delay = preferences.autoreparseDelayMilliseconds
        let documentID = textView.documentIdentifier
        let url = textView.documentURL
        javaAutoImport.schedule(after: .milliseconds(delay)) { [weak self, weak textView] in
            guard let self, let textView else { return }
            guard textView.languageIdentifier == "java",
                  textView.documentIdentifier == documentID,
                  textView.documentURL == url else { return }
            let text = textView.text
            let edits: [TextEdit]
            if pasting, let paste {
                edits = await self.javaSupport.importEdits(forPastedText: paste, in: text, file: url, policy: policy)
            } else {
                edits = await self.javaSupport.importEdits(
                    in: text, caretUTF16: textView.selectedRange.location, file: url, policy: policy
                )
            }
            guard !Task.isCancelled, textView.text == text, textView.documentURL == url, !edits.isEmpty else { return }
            self.javaAutoImportApplying = true
            TextEditApplicator.apply(edits, in: textView)
            self.javaAutoImportApplying = false
        }
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

/// Why a file could not be read in an encoding the user picked.
enum IDEEncodingError: LocalizedError {
    case cannotDecode(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotDecode(let file, let encoding):
            "\(file) can't be read as \(encoding). Some of its bytes are not valid in that encoding."
        }
    }
}
