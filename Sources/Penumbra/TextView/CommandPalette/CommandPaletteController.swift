@preconcurrency import AppKit
import EditorIntelligence

/// Drives the Search Everywhere / Find Action / Recent Files / Go-to-file palette over a
/// `TextView`. Self-contained: it installs its own overlay and chains
/// `TextView.editorActionHandler`, so it works with or without `EditorIntelligence`.
///
/// Wire the data sources you have — `fileEntriesProvider`, `recentFileEntriesProvider`,
/// `symbolIndex`, `onOpenFile`, `extraProviders` — then bind the keymap actions (they arrive
/// automatically once this controller is constructed with `bindActions: true`).
///
/// By default the overlay is pinned to `textView`. Pass `overlayContainer` (or call
/// ``installOverlay(in:)`` later) to present it in a window-level host instead; ``attach(to:)``
/// and ``bindActions(to:)`` retarget a shared controller at additional editors.
@MainActor
public final class CommandPaletteController {
    public let commandRegistry = CommandRegistry()
    public let paletteModel = EditorPaletteModel()
    public let engine = SearchEverywhereEngine()

    /// Opens a file chosen from the Files / Recent Files sections.
    public var onOpenFile: ((URL) -> Void)?
    /// Invoked when a workspace symbol row is chosen.
    public var onSelectSymbol: ((EditorIntelligence.Symbol) -> Void)?
    /// Supplies the candidate file list for the Files section (Penumbra has no on-disk index).
    public var fileEntriesProvider: (@MainActor @Sendable () -> [PaletteFileEntry])?
    /// Supplies most-recently-used documents for ⌘E and the Recent Files section.
    public var recentFileEntriesProvider: (@MainActor @Sendable () -> [PaletteFileEntry])?
    /// Tool-window shortcuts for the Recent Files / Go to File sidebar (Project, Terminal, …).
    public var navigationDestinationsProvider: (@MainActor @Sendable () -> [RecentFilesDestination])?
    /// The file in the focused editor. When it leads Recent Files, ⌘E selects the second row so
    /// ⌘E ↩ flips between the last two files, as in IntelliJ.
    public var activeDocumentURLProvider: (@MainActor @Sendable () -> URL?)?
    /// Removes a file from the recent list (⌫ on a Recent Files row); the host also closes its
    /// editor. Rows are only removable when this is set.
    public var onRemoveRecentFile: ((URL) -> Void)? {
        didSet { recentFilesProvider = nil }
    }
    /// Supplies Recent Locations (⌘⇧E), newest first. Rows open through ``onOpenFileAtLine``.
    public var recentLocationsProvider: (@MainActor @Sendable () -> [PaletteLocationEntry])?
    /// A prebuilt, host-maintained file index. When set it replaces ``fileEntriesProvider`` for the
    /// Files section: nothing is enumerated per keystroke, rows get icons / module / path columns,
    /// and the Text tab reuses its file list instead of walking the disk.
    public var fileIndex: PaletteFileIndex?
    /// Recently used / open files (most recent first) that lead an empty query and win ties.
    public var fileBoostsProvider: (@MainActor @Sendable () -> [URL])?
    /// Supplies the Classes tab. When `nil` the tab falls back to type symbols from ``symbolIndex``.
    public var classesProvider: SearchEverywhereProvider?
    /// Opens a file beside the current editor (⇧↩ / "Open In Right Split"). File rows only offer
    /// the alternate action when this is set.
    public var onOpenFileInSplit: ((URL) -> Void)? {
        didSet {
            indexedFilesProvider = nil
            recentFilesProvider = nil
        }
    }
    /// Opens a file at a 1-based line (and column) typed after its name: `Foo.java:42`
    /// (IntelliJ's Go to File suffix). Without it the suffix is matched as part of the name.
    public var onOpenFileAtLine: ((URL, PaletteLineTarget) -> Void)? {
        didSet { indexedFilesProvider = nil }
    }
    /// Reopening a tabbed mode shows its previous query, selected so typing replaces it — as
    /// IntelliJ's Search Everywhere does.
    public var restoresLastQuery = true
    /// Whether ⌘⇧F (`.findInFiles`) opens the palette's Text tab. A host with its own Find in Files
    /// panel sets this to `false`; the Text tab stays reachable from the tab strip.
    public var handlesFindInFilesAction = true
    /// Shows IntelliJ's "Include non-project items" checkbox. Off by default: it only matters once
    /// a host supplies library classes.
    public var showsNonProjectToggle = false
    /// Current state of the "Include non-project items" checkbox.
    public private(set) var includeNonProjectItems = false
    /// Invoked when the user flips the "Include non-project items" checkbox.
    public var onIncludeNonProjectItemsChanged: ((Bool) -> Void)?
    /// Workspace root, used to show file paths relative to it.
    public var workspaceRoot: URL?
    /// Workspace symbol index for the Symbols section.
    public var symbolIndex: SymbolIndex?
    /// Disk-wide search engine backing `.findInFiles` / ⌘⇧F. With `workspaceRoot` unset, or this
    /// left `nil`, `.findInFiles` is left unhandled so a host-installed
    /// `EditorIntelligenceController.onRequestProjectSearch` (or another `editorActionHandler`
    /// link) can present its own UI instead.
    public var projectSearchEngine: ProjectSearchEngine?
    /// Invoked when a Find in Files row is chosen.
    public var onOpenProjectSearchResult: ((ProjectSearchResult) -> Void)?
    /// Extra host-supplied sections (settings, run configs, docs…).
    public var extraProviders: [SearchEverywhereProvider] = []
    /// Max rows when the palette browses a single source (a tab other than All, or a sigil scope).
    public var singleSourceLimit = 60
    /// Max rows per section in the mixed All / Search Everywhere view.
    public var perSectionLimit: Int {
        get { engine.perProviderLimit }
        set { engine.perProviderLimit = newValue }
    }

    private weak var textView: TextView?
    private weak var overlayContainer: NSView?
    let paletteView = CommandPaletteView()
    private let backdrop = PaletteBackdropView()
    private let boundTextViews = NSHashTable<TextView>.weakObjects()
    private var currentSections: [PaletteSection] = []
    /// Set while presenting a fixed list (`.locations` / surround templates) that bypasses the engine.
    private var isStaticList = false
    private var indexedFilesProvider: FilesPaletteProvider?
    private var recentFilesProvider: RecentFilesPaletteProvider?
    private var recentFilesEditedOnly = false
    private var selectedDestinationIndex = 0
    /// Every sidebar destination; the view shows the ones matching the query.
    private var allNavigationDestinations: [RecentFilesDestination] = []
    /// Set by ⌘E until the first results arrive or the user moves, types or filters.
    private var pendingInitialRecentSelection = false
    private var lastQueries: [EditorPaletteMode: String] = [:]

    var flatItems: [PaletteItem] { currentSections.flatMap(\.items) }

    public var isPresented: Bool { paletteModel.isPresented }

    /// Tabs the strip currently offers — only those whose source the host has wired.
    public var availableTabs: [PaletteTab] {
        PaletteTab.allCases.filter { tab in
            switch tab {
            case .all, .actions: true
            case .classes: classesProvider != nil || symbolIndex != nil
            case .files: fileIndex != nil || fileEntriesProvider != nil
            case .symbols: symbolIndex != nil
            case .text: projectSearchEngine != nil && workspaceRoot != nil
            }
        }
    }

    /// The tab of the mode being shown, or `nil` for the tab-less modes.
    public var currentTab: PaletteTab? {
        isStaticList ? nil : PaletteTab(mode: paletteModel.mode)
    }

    /// Switches to `tab`, keeping the query text.
    public func selectTab(_ tab: PaletteTab) {
        guard paletteModel.isPresented, !isStaticList, availableTabs.contains(tab) else { return }
        paletteModel.mode = tab.mode
        paletteModel.selectedIndex = 0
        paletteView.placeholder = tab.placeholder
        paletteView.selectedTab = tab
        paletteView.syncChromeLayout()
        runQuery(paletteModel.query)
    }

    public init(textView: TextView, overlayContainer: NSView? = nil, bindActions: Bool = true) {
        self.textView = textView
        commandRegistry.registerBuiltInActions(for: textView)
        wirePaletteView()
        let container = overlayContainer ?? textView
        self.overlayContainer = container
        installOverlay(in: container)
        if bindActions {
            self.bindActions(to: textView)
        }
    }

    /// Points go-to-line, in-buffer search, surround-with, and dismiss-restore-focus at
    /// `textView`. Re-registers Find Action commands so they run on this editor.
    public func attach(to textView: TextView) {
        guard self.textView !== textView else { return }
        self.textView = textView
        commandRegistry.registerBuiltInActions(for: textView)
    }

    /// Chains this controller into `textView.editorActionHandler`. Safe to call more than once
    /// for the same view. The triggering editor becomes the attached target before the action
    /// runs, so a shared controller stays aimed at the pane that invoked it.
    public func bindActions(to textView: TextView) {
        guard !boundTextViews.contains(textView) else { return }
        boundTextViews.add(textView)
        let previous = textView.editorActionHandler
        textView.editorActionHandler = { [weak self, weak textView] action in
            guard let self else { return previous?(action) ?? false }
            if let textView {
                self.attach(to: textView)
            }
            if self.handle(action) == true { return true }
            return previous?(action) ?? false
        }
    }

    /// Moves the dimmed backdrop + palette onto `container` (full bounds). No-op when the
    /// overlay is already installed there.
    public func installOverlay(in container: NSView) {
        overlayContainer = container
        if backdrop.superview === container { return }
        backdrop.removeFromSuperview()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isHidden = !paletteModel.isPresented
        backdrop.paletteView = paletteView
        if paletteView.superview !== backdrop {
            paletteView.removeFromSuperview()
            backdrop.addSubview(paletteView)
        }
        container.addSubview(backdrop, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        if paletteModel.isPresented {
            layoutPalette(in: container)
            paletteView.syncChromeLayout()
            paletteView.layoutSubtreeIfNeeded()
            paletteView.focusQueryField()
        }
    }

    // MARK: - Presentation

    public func presentSearchEverywhere() {
        present(mode: .searchEverywhere, placeholder: "Search Everywhere")
    }

    public func presentFindAction() {
        present(mode: .commands, placeholder: "Find Action")
    }

    public func presentRecentFiles() {
        selectedDestinationIndex = 0
        recentFilesEditedOnly = false
        pendingInitialRecentSelection = true
        present(mode: .recentFiles, placeholder: "Search recent files")
    }

    /// Presents Recent Locations. Returns `false` without presenting when no
    /// ``recentLocationsProvider`` / ``onOpenFileAtLine`` is wired.
    @discardableResult
    public func presentRecentLocations() -> Bool {
        guard recentLocationsProvider != nil, onOpenFileAtLine != nil else { return false }
        present(mode: .recentLocations, placeholder: "Search recent locations")
        return true
    }

    public func presentQuickOpen() {
        selectedDestinationIndex = 0
        present(mode: .quickOpen, placeholder: "Search by filename")
    }

    public func presentClasses() {
        present(mode: .classes, placeholder: "Go to Class")
    }

    public func presentSymbols() {
        present(mode: .symbols, placeholder: "Go to Symbol")
    }

    /// Presents Go to Line with the field pre-seeded with `:`, matching Sublime's Goto Anything.
    public func presentGoToLine() {
        present(mode: .goToLine, placeholder: "Go to Line", seed: ":")
    }

    /// Presents disk-wide Find in Files. Returns `false` without presenting when no
    /// ``projectSearchEngine`` / ``workspaceRoot`` is wired, so a host's own `.findInFiles`
    /// handling (e.g. a custom panel via `EditorIntelligenceController.onRequestProjectSearch`)
    /// gets first refusal.
    @discardableResult
    public func presentProjectSearch() -> Bool {
        guard projectSearchEngine != nil, workspaceRoot != nil else { return false }
        present(mode: .findInFiles, placeholder: "Find in Files")
        return true
    }

    /// Presents a fixed list — e.g. multiple "Go to Definition" targets, or the surround-with
    /// templates. `onChoose` runs for the picked item; the palette then dismisses.
    public func presentList(title: String, items: [(title: String, subtitle: String?)], onChoose: @escaping (Int) -> Void) {
        isStaticList = true
        let paletteItems = items.enumerated().map { index, entry in
            PaletteItem(
                id: "list:\(index)",
                title: entry.title,
                subtitle: entry.subtitle,
                sectionTitle: title,
                score: items.count - index,
                action: { onChoose(index) }
            )
        }
        currentSections = [PaletteSection(title: title, items: paletteItems)]
        paletteModel.showLocations()
        paletteView.placeholder = ""
        paletteView.query = ""
        configureTabs()
        showOverlay()
        paletteView.update(sections: currentSections, selectedItemIndex: 0)
    }

    public func dismiss() {
        guard paletteModel.isPresented else { return }
        if !isStaticList, currentTab != nil {
            lastQueries[paletteModel.mode] = paletteModel.query
        }
        engine.cancel()
        paletteView.isSearching = false
        isStaticList = false
        currentSections = []
        paletteModel.hide()
        backdrop.isHidden = true
        _ = textView?.focusTextInput()
    }

    // MARK: - Wiring

    private func handle(_ action: EditorActionID) -> Bool {
        switch action {
        case .searchEverywhere: presentSearchEverywhere()
        case .findAction: presentFindAction()
        case .recentFiles: presentRecentFiles()
        case .recentLocations: return presentRecentLocations()
        case .quickOpenFile: presentQuickOpen()
        case .goToSymbol: presentSymbols()
        case .surroundWith: presentSurroundWith()
        case .goToLine: presentGoToLine()
        case .findInFiles: return handlesFindInFilesAction && presentProjectSearch()
        default: return false
        }
        return true
    }

    private func presentSurroundWith() {
        guard let textView, textView.selectedRange.length > 0 else { return }
        let templates = textView.applicableSurroundTemplates()
        guard !templates.isEmpty else { return }
        presentList(
            title: "Surround With",
            items: templates.map { ($0.title, nil) }
        ) { [weak textView] index in
            guard let textView, templates.indices.contains(index) else { return }
            textView.surroundSelection(with: templates[index])
        }
    }

    private func present(mode: EditorPaletteMode, placeholder: String, seed: String = "") {
        isStaticList = false
        var seed = seed
        var restored = false
        if seed.isEmpty, restoresLastQuery, PaletteTab(mode: mode) != nil,
           let last = lastQueries[mode], !last.isEmpty {
            seed = last
            restored = true
        }
        engine.setProviders(providers(for: mode))
        paletteModel.mode = mode
        paletteModel.query = seed
        paletteModel.selectedIndex = 0
        paletteModel.isPresented = true
        paletteView.placeholder = placeholder
        paletteView.query = seed
        configureTabs()
        showOverlay()
        if restored {
            paletteView.selectAllQueryText()
        }
        runQuery(seed)
    }

    /// Shows the tab strip for the tabbed modes and hides it for go-to-line, recent files, and
    /// fixed lists. Go to File keeps the IntelliJ-style tab strip (All / Classes / Files / …).
    private func configureTabs() {
        switch paletteModel.mode {
        case .recentFiles:
            configureNavigationChrome(
                title: "Recent Files",
                showsEditedOnly: true,
                hint: ""
            )
        case .quickOpen:
            paletteView.showsNavigationChrome = false
            paletteView.tabs = availableTabs
            paletteView.selectedTab = currentTab
            paletteView.hint = "> actions   @ symbols   / files   # text   : line"
            paletteView.showsNonProjectToggle = showsNonProjectToggle
        default:
            if let tab = currentTab {
                paletteView.showsNavigationChrome = false
                paletteView.tabs = availableTabs
                paletteView.selectedTab = tab
                paletteView.hint = "> actions   @ symbols   : line"
                paletteView.showsNonProjectToggle = showsNonProjectToggle
            } else {
                paletteView.tabs = []
                paletteView.selectedTab = nil
                paletteView.hint = ""
                paletteView.showsNonProjectToggle = false
                paletteView.showsNavigationChrome = false
            }
        }
        paletteView.syncChromeLayout()
    }

    private func configureNavigationChrome(title: String, showsEditedOnly: Bool, hint: String) {
        paletteView.tabs = []
        paletteView.selectedTab = nil
        paletteView.hint = hint
        paletteView.showsNonProjectToggle = false
        paletteView.navigationChromeTitle = title
        paletteView.showsEditedOnlyInChrome = showsEditedOnly
        paletteView.showsNavigationChrome = true
        allNavigationDestinations = navigationDestinationsProvider?() ?? []
        paletteView.navigationDestinations = filteredDestinations(for: paletteModel.query)
        if showsEditedOnly {
            paletteView.editedOnly = recentFilesEditedOnly
        }
        paletteView.selectedDestinationIndex = selectedDestinationIndex
        paletteView.navigationPane = .files
    }

    private var usesNavigationChrome: Bool {
        paletteModel.mode == .recentFiles
    }

    private func showOverlay() {
        if backdrop.superview == nil, let container = overlayContainer {
            installOverlay(in: container)
        }
        guard let container = backdrop.superview else { return }
        layoutPalette(in: container)
        backdrop.isHidden = false
        backdrop.superview?.addSubview(backdrop, positioned: .above, relativeTo: nil)
        paletteView.syncChromeLayout()
        paletteView.layoutSubtreeIfNeeded()
        paletteView.focusQueryField()
    }

    private func makeCommandsProvider() -> CommandsPaletteProvider {
        CommandsPaletteProvider(registry: commandRegistry)
    }

    private func makeFilesProvider() -> FilesPaletteProvider? {
        if fileIndex != nil {
            // One long-lived provider: it reads the live `fileIndex` per query and keeps the
            // narrowing cache that makes each extra keystroke cheaper than the last.
            if let existing = indexedFilesProvider { return existing }
            let index: @MainActor @Sendable () -> PaletteFileIndex? = { [weak self] in self?.fileIndex }
            let boosts: @MainActor @Sendable () -> [URL] = { [weak self] in self?.fileBoostsProvider?() ?? [] }
            let open: @MainActor @Sendable (URL) -> Void = { [weak self] url in self?.onOpenFile?(url) }
            var openInSplit: (@MainActor @Sendable (URL) -> Void)?
            if onOpenFileInSplit != nil {
                openInSplit = { [weak self] url in self?.onOpenFileInSplit?(url) }
            }
            var openAtLine: (@MainActor @Sendable (URL, PaletteLineTarget) -> Void)?
            if onOpenFileAtLine != nil {
                openAtLine = { [weak self] url, target in self?.onOpenFileAtLine?(url, target) }
            }
            let provider = FilesPaletteProvider(
                index: index,
                boosts: boosts,
                onOpen: open,
                onOpenInSplit: openInSplit,
                onOpenAtLine: openAtLine
            )
            indexedFilesProvider = provider
            return provider
        }
        guard let entries = fileEntriesProvider else { return nil }
        let root = workspaceRoot
        return FilesPaletteProvider(files: entries, root: { root }) { [weak self] url in
            self?.onOpenFile?(url)
        }
    }

    private func makeRecentProvider() -> RecentFilesPaletteProvider? {
        guard let entries = recentFileEntriesProvider else { return nil }
        if let existing = recentFilesProvider { return existing }
        let root = workspaceRoot
        let index: @MainActor @Sendable () -> PaletteFileIndex? = { [weak self] in self?.fileIndex }
        let editedOnly: @MainActor @Sendable () -> Bool = { [weak self] in self?.recentFilesEditedOnly ?? false }
        var openInSplit: (@MainActor @Sendable (URL) -> Void)?
        if onOpenFileInSplit != nil {
            openInSplit = { [weak self] url in self?.onOpenFileInSplit?(url) }
        }
        var remove: (@MainActor @Sendable (URL) -> Void)?
        if onRemoveRecentFile != nil {
            remove = { [weak self] url in self?.onRemoveRecentFile?(url) }
        }
        let provider = RecentFilesPaletteProvider(
            entries: entries,
            root: { root },
            index: index,
            editedOnly: editedOnly,
            onOpen: { [weak self] url in self?.onOpenFile?(url) },
            onOpenInSplit: openInSplit,
            onRemove: remove
        )
        recentFilesProvider = provider
        return provider
    }

    private func makeRecentLocationsProvider() -> RecentLocationsPaletteProvider? {
        guard let entries = recentLocationsProvider else { return nil }
        let root = workspaceRoot
        return RecentLocationsPaletteProvider(entries: entries, root: { root }) { [weak self] url, target in
            self?.onOpenFileAtLine?(url, target)
        }
    }

    private func makeSymbolsProvider() -> SymbolsPaletteProvider? {
        guard let index = symbolIndex else { return nil }
        return SymbolsPaletteProvider(index: index) { [weak self] symbol in
            self?.onSelectSymbol?(symbol)
        }
    }

    private func makeClassesProvider() -> SearchEverywhereProvider? {
        if let classesProvider { return classesProvider }
        guard let index = symbolIndex else { return nil }
        return SymbolsPaletteProvider(index: index, kinds: [.type], sectionTitle: "Classes", sectionOrder: 15) { [weak self] symbol in
            self?.onSelectSymbol?(symbol)
        }
    }

    private func makeGoToLineProvider() -> GoToLinePaletteProvider {
        GoToLinePaletteProvider(
            lineCount: { [weak self] in self?.textView?.lineCount ?? 0 },
            onGoToLine: { [weak self] line in self?.textView?.goToLine(line - 1) }
        )
    }

    private func makeBufferTextProvider() -> BufferTextPaletteProvider {
        BufferTextPaletteProvider(
            text: { [weak self] in self?.textView?.text ?? "" },
            search: { [weak self] query in self?.textView?.search(for: query) ?? [] },
            onSelect: { [weak self] range in
                guard let textView = self?.textView else { return }
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
            }
        )
    }

    private func makeProjectSearchProvider() -> ProjectSearchPaletteProvider? {
        guard let engine = projectSearchEngine, let root = workspaceRoot else { return nil }
        return ProjectSearchPaletteProvider(
            engine: engine,
            root: root,
            files: { [weak self] in self?.fileIndex?.urls }
        ) { [weak self] result in
            self?.onOpenProjectSearchResult?(result)
        }
    }

    private func providers(for mode: EditorPaletteMode) -> [SearchEverywhereProvider] {
        switch mode {
        case .commands, .textActions:
            return [makeCommandsProvider()]
        case .quickOpen:
            return [makeFilesProvider()].compactMap { $0 }
        case .symbols:
            return [makeSymbolsProvider()].compactMap { $0 }
        case .classes:
            return [makeClassesProvider()].compactMap { $0 }
        case .recentFiles:
            return [makeRecentProvider()].compactMap { $0 }
        case .recentLocations:
            return [makeRecentLocationsProvider()].compactMap { $0 }
        case .searchEverywhere:
            return ([makeClassesProvider(), makeRecentProvider(), makeFilesProvider(), makeSymbolsProvider()] as [SearchEverywhereProvider?])
                .compactMap { $0 } + [makeCommandsProvider()] + extraProviders
        case .goToLine:
            return [makeGoToLineProvider()]
        case .findInFiles:
            return [makeProjectSearchProvider()].compactMap { $0 }
        case .locations:
            return []
        }
    }

    /// Provider set for a sigil-scoped query typed into any palette field (`>` commands,
    /// `@` symbols, `/` files, `#` in-buffer text, `:` go-to-line) — Sublime's Goto Anything.
    private func providers(forScope scope: PaletteQueryScope) -> [SearchEverywhereProvider] {
        switch scope {
        case .commands:
            return [makeCommandsProvider()] + extraProviders
        case .symbols:
            return ([makeSymbolsProvider()].compactMap { $0 } as [SearchEverywhereProvider]) + extraProviders
        case .files:
            return ([makeRecentProvider(), makeFilesProvider()] as [SearchEverywhereProvider?]).compactMap { $0 } + extraProviders
        case .text:
            return [makeBufferTextProvider()]
        case .line:
            return [makeGoToLineProvider()]
        case .textActions:
            return providers(for: .searchEverywhere)
        }
    }

    private func runQuery(_ rawQuery: String) {
        guard !isStaticList else { return }
        var effectiveQuery = rawQuery
        // A leading sigil narrows the sources for this keystroke, in every mode — not just
        // Search Everywhere — so ⌘P becomes one Sublime-style Goto Anything field. Without a
        // sigil, each mode keeps searching its own default provider set exactly as before.
        if let scope = PaletteQueryScope.explicitScope(in: rawQuery) {
            engine.setProviders(providers(forScope: scope))
            effectiveQuery = scope.query
        } else {
            engine.setProviders(providers(for: paletteModel.mode))
        }
        let isSingleSource = paletteModel.mode != .searchEverywhere && paletteModel.mode != .textActions
            || PaletteQueryScope.explicitScope(in: rawQuery) != nil
        let isDiskSearch = paletteModel.mode == .findInFiles
        // Index-backed sources are cheap enough to answer almost per keystroke; disk-wide text
        // search keeps a longer debounce so it isn't restarted for every character.
        let debounce: UInt64? = isDiskSearch ? 150 : (fileIndex != nil ? 10 : nil)
        let delay = debounce ?? engine.debounceMilliseconds
        paletteView.emptyStateMessage = emptyStateMessage(for: rawQuery)
        paletteView.isSearching = delay >= PaletteChromeMetrics.searchingIndicatorMinimumDebounce
        engine.search(
            effectiveQuery,
            debounceMilliseconds: debounce,
            limit: isSingleSource ? max(singleSourceLimit, perSectionLimit) : nil
        ) { [weak self] sections in
            guard let self else { return }
            self.paletteView.isSearching = false
            self.paletteView.emptyStateMessage = self.emptyStateMessage(for: rawQuery)
            self.currentSections = sections
            self.applyInitialRecentSelection(query: rawQuery)
            self.paletteModel.clampSelection(count: self.flatItems.count)
            self.paletteView.update(sections: sections, selectedItemIndex: self.paletteModel.selectedIndex)
            self.focusDestinationsIfNoFiles()
        }
    }

    /// ⌘E skips the file already in the focused editor, so ⌘E ↩ returns to the previous one.
    private func applyInitialRecentSelection(query: String) {
        guard pendingInitialRecentSelection, paletteModel.mode == .recentFiles else { return }
        pendingInitialRecentSelection = false
        let items = flatItems
        guard query.isEmpty, items.count > 1,
              let first = items[0].fileURL,
              let active = activeDocumentURLProvider?(),
              first.standardizedFileURL == active.standardizedFileURL else { return }
        paletteModel.selectedIndex = 1
    }

    /// With no file left to show, the arrow keys and ↩ act on the matching tool windows.
    private func focusDestinationsIfNoFiles() {
        guard usesNavigationChrome, flatItems.isEmpty,
              !paletteView.navigationDestinations.isEmpty,
              paletteView.navigationPane == .files else { return }
        selectedDestinationIndex = 0
        paletteView.selectedDestinationIndex = 0
        paletteView.navigationPane = .destinations
    }

    private func filteredDestinations(for query: String) -> [RecentFilesDestination] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allNavigationDestinations }
        return FuzzyMatcher.rankedWithMatches(
            query: trimmed,
            items: allNavigationDestinations,
            key: \.title,
            limit: allNavigationDestinations.count
        ).map(\.item)
    }

    /// ⌫ on an empty query: forgets the selected recent file (the host closes its editor), or
    /// hides the selected tool window. The row goes away in place, keeping the selection index.
    func removeSelection() {
        guard usesNavigationChrome else { return }
        if paletteView.navigationPane == .destinations {
            let destinations = paletteView.navigationDestinations
            guard destinations.indices.contains(selectedDestinationIndex),
                  let close = destinations[selectedDestinationIndex].close else { return }
            close()
            return
        }
        let items = flatItems
        guard items.indices.contains(paletteModel.selectedIndex),
              let remove = items[paletteModel.selectedIndex].removeAction else { return }
        let removedID = items[paletteModel.selectedIndex].id
        pendingInitialRecentSelection = false
        remove()
        currentSections = currentSections.compactMap { section in
            let kept = section.items.filter { $0.id != removedID }
            return kept.isEmpty ? nil : PaletteSection(title: section.title, items: kept)
        }
        paletteModel.clampSelection(count: flatItems.count)
        paletteView.update(sections: currentSections, selectedItemIndex: paletteModel.selectedIndex)
        focusDestinationsIfNoFiles()
    }

    private func emptyStateMessage(for rawQuery: String) -> String {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "No results" }
        switch paletteModel.mode {
        case .recentFiles: return "No recent files"
        case .recentLocations: return "No recent locations"
        case .goToLine: return "Type a line number"
        case .findInFiles: return "Type to search"
        default: return "No results"
        }
    }

    func activateSelection(alternate: Bool = false) {
        if usesNavigationChrome, paletteView.navigationPane == .destinations {
            activateDestination()
            return
        }
        // Results are debounced, so Return right after typing a line number would otherwise see
        // no rows (or the previous number's row). The line is fully determined by the query.
        if !isStaticList,
           case .line(let rawLine) = PaletteQueryScope.explicitScope(in: paletteModel.query)
               ?? PaletteQueryScope.resolve(query: paletteModel.query, mode: paletteModel.mode),
           let requested = GoToLinePaletteProvider.parse(rawLine) {
            let target = min(requested, max(textView?.lineCount ?? 0, 1))
            dismiss()
            textView?.goToLine(target - 1)
            return
        }
        let items = flatItems
        guard items.indices.contains(paletteModel.selectedIndex) else {
            // Nothing recent matches: carry the query over to Go to File, as IntelliJ does.
            let query = paletteModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alternate, paletteModel.mode == .recentFiles, !query.isEmpty,
               fileIndex != nil || fileEntriesProvider != nil {
                selectedDestinationIndex = 0
                present(mode: .quickOpen, placeholder: "Search by filename", seed: query)
                return
            }
            if !alternate { dismiss() }
            return
        }
        let item = items[paletteModel.selectedIndex]
        let action: (@MainActor @Sendable () -> Void)?
        if alternate {
            // Rows without a secondary action ignore ⇧↩ rather than doing something unexpected.
            action = item.alternateAction
        } else {
            action = item.action
        }
        guard let action else { return }
        dismiss()
        action()
    }

    private func activateDestination() {
        let destinations = paletteView.navigationDestinations
        guard destinations.indices.contains(selectedDestinationIndex) else { return }
        let action = destinations[selectedDestinationIndex].action
        dismiss()
        action()
    }

    private func moveDestinationSelection(by delta: Int) {
        let count = paletteView.navigationDestinations.count
        guard count > 0 else { return }
        selectedDestinationIndex = min(max(selectedDestinationIndex + delta, 0), count - 1)
        paletteView.selectedDestinationIndex = selectedDestinationIndex
    }

    @discardableResult
    private func navigateRecentFilesPane(by delta: Int) -> Bool {
        guard usesNavigationChrome else { return false }
        switch paletteView.navigationPane {
        case .files where delta < 0:
            guard !paletteView.navigationDestinations.isEmpty else { return false }
            paletteView.navigationPane = .destinations
        case .destinations where delta > 0:
            paletteView.navigationPane = .files
        default:
            return false
        }
        paletteView.refreshNavigationChrome()
        return true
    }

    private func wirePaletteView() {
        paletteView.onQueryChange = { [weak self] query in
            guard let self else { return }
            self.paletteModel.query = query
            self.pendingInitialRecentSelection = false
            if self.usesNavigationChrome {
                self.selectedDestinationIndex = 0
                self.paletteView.selectedDestinationIndex = 0
                self.paletteView.navigationDestinations = self.filteredDestinations(for: query)
                self.paletteView.navigationPane = .files
                self.paletteView.refreshNavigationChrome()
            }
            self.runQuery(query)
        }
        paletteView.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.pendingInitialRecentSelection = false
            if self.usesNavigationChrome, self.paletteView.navigationPane == .destinations {
                self.moveDestinationSelection(by: delta)
                return
            }
            self.paletteModel.moveSelection(by: delta, count: self.flatItems.count)
            self.paletteView.updateSelection(self.paletteModel.selectedIndex)
        }
        paletteView.onNavigatePane = { [weak self] delta in
            self?.navigateRecentFilesPane(by: delta) ?? false
        }
        paletteView.onToggleEditedOnly = { [weak self] in
            guard let self, self.paletteModel.mode == .recentFiles else { return }
            self.recentFilesEditedOnly.toggle()
            self.paletteView.editedOnly = self.recentFilesEditedOnly
            self.pendingInitialRecentSelection = false
            self.paletteModel.selectedIndex = 0
            self.runQuery(self.paletteModel.query)
        }
        paletteView.onEditedOnlyChanged = { [weak self] isOn in
            guard let self, self.paletteModel.mode == .recentFiles else { return }
            self.recentFilesEditedOnly = isOn
            self.pendingInitialRecentSelection = false
            self.paletteModel.selectedIndex = 0
            self.runQuery(self.paletteModel.query)
        }
        paletteView.onConfirm = { [weak self] in self?.activateSelection() }
        paletteView.onDeleteSelection = { [weak self] in
            guard let self, self.usesNavigationChrome else { return false }
            self.removeSelection()
            return true
        }
        paletteView.onConfirmAlternate = { [weak self] in self?.activateSelection(alternate: true) }
        paletteView.onSelectTab = { [weak self] tab in self?.selectTab(tab) }
        paletteView.onToggleNonProjectItems = { [weak self] isOn in
            guard let self else { return }
            self.includeNonProjectItems = isOn
            self.onIncludeNonProjectItemsChanged?(isOn)
            self.runQuery(self.paletteModel.query)
        }
        paletteView.onCancel = { [weak self] in self?.dismiss() }
        paletteView.onActivateItemAtIndex = { [weak self] index in
            guard let self, self.flatItems.indices.contains(index) else { return }
            self.paletteModel.selectedIndex = index
            self.activateSelection()
        }
        backdrop.onClickOutsidePalette = { [weak self] in self?.dismiss() }
        backdrop.onLayout = { [weak self, weak backdrop] in
            guard let self, let backdrop, !backdrop.isHidden, let container = backdrop.superview else {
                return
            }
            self.layoutPalette(in: container)
        }
    }

    private func layoutPalette(in container: NSView) {
        let width = min(760, max(360, container.bounds.width - 80))
        let height: CGFloat = min(560, max(220, container.bounds.height * 0.7))
        let originX = ((container.bounds.width - width) / 2).rounded()
        // AppKit Y grows upward. Extra leftover below the panel sits it slightly above center.
        let leftover = container.bounds.height - height
        let originY = max((leftover * 0.58).rounded(), 12)
        let frame = CGRect(x: originX, y: originY, width: width, height: height)
        if paletteView.frame != frame {
            paletteView.frame = frame
        }
        // The frame is recomputed on every container layout (`onLayout`), so it doesn't need
        // flexible margins -- and those leave the origin unpinned for Auto Layout to shift
        // (which then re-triggers this very layout pass).
        if !paletteView.autoresizingMask.isEmpty {
            paletteView.autoresizingMask = []
        }
    }
}

/// Full-bounds backdrop that dismisses the palette on a click outside it. Dims the editor
/// while the palette is visible.
private final class PaletteBackdropView: NSView {
    var onClickOutsidePalette: (() -> Void)?
    var onLayout: (() -> Void)?
    weak var paletteView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point)
        if let paletteView, hit != nil, hit!.isDescendant(of: paletteView) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClickOutsidePalette?()
    }

    override func scrollWheel(with event: NSEvent) {
        // Consume wheel events on the dimmed area so they don't reach the editor underneath.
    }
}
