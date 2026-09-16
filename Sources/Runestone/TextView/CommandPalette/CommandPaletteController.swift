@preconcurrency import AppKit
import EditorIntelligence

/// Drives the Search Everywhere / Find Action / Recent Files / Go-to-file palette over a
/// `TextView`. Self-contained: it installs its own overlay and chains
/// `TextView.editorActionHandler`, so it works with or without `EditorIntelligence`.
///
/// Wire the data sources you have — `fileEntriesProvider`, `recentFileEntriesProvider`,
/// `symbolIndex`, `onOpenFile`, `extraProviders` — then bind the keymap actions (they arrive
/// automatically once this controller is constructed with `bindActions: true`).
@MainActor
public final class CommandPaletteController {
    public let commandRegistry = CommandRegistry()
    public let paletteModel = EditorPaletteModel()
    public let engine = SearchEverywhereEngine()

    /// Opens a file chosen from the Files / Recent Files sections.
    public var onOpenFile: ((URL) -> Void)?
    /// Invoked when a workspace symbol row is chosen.
    public var onSelectSymbol: ((EditorIntelligence.Symbol) -> Void)?
    /// Supplies the candidate file list for the Files section (Runestone has no on-disk index).
    public var fileEntriesProvider: (@MainActor @Sendable () -> [PaletteFileEntry])?
    /// Supplies most-recently-used documents for ⌘E and the Recent Files section.
    public var recentFileEntriesProvider: (@MainActor @Sendable () -> [PaletteFileEntry])?
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
    /// Max rows per section.
    public var perSectionLimit: Int {
        get { engine.perProviderLimit }
        set { engine.perProviderLimit = newValue }
    }

    private weak var textView: TextView?
    private let paletteView = CommandPaletteView()
    private let backdrop = PaletteBackdropView()
    private var previousActionHandler: ((EditorActionID) -> Bool)?
    private var currentSections: [PaletteSection] = []
    /// Set while presenting a fixed list (`.locations` / surround templates) that bypasses the engine.
    private var isStaticList = false

    private var flatItems: [PaletteItem] { currentSections.flatMap(\.items) }

    public var isPresented: Bool { paletteModel.isPresented }

    public init(textView: TextView, bindActions: Bool = true) {
        self.textView = textView
        commandRegistry.registerBuiltInActions(for: textView)
        installOverlay(on: textView)
        wirePaletteView()
        if bindActions {
            let previous = textView.editorActionHandler
            previousActionHandler = previous
            textView.editorActionHandler = { [weak self] action in
                if self?.handle(action) == true { return true }
                return previous?(action) ?? false
            }
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
        present(mode: .recentFiles, placeholder: "Recent Files")
    }

    public func presentQuickOpen() {
        present(mode: .quickOpen, placeholder: "Go to File")
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
        showOverlay()
        paletteView.update(sections: currentSections, selectedItemIndex: 0)
    }

    public func dismiss() {
        guard paletteModel.isPresented else { return }
        engine.cancel()
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
        case .quickOpenFile: presentQuickOpen()
        case .goToSymbol: presentSymbols()
        case .surroundWith: presentSurroundWith()
        case .goToLine: presentGoToLine()
        case .findInFiles: return presentProjectSearch()
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
        engine.setProviders(providers(for: mode))
        paletteModel.mode = mode
        paletteModel.query = seed
        paletteModel.selectedIndex = 0
        paletteModel.isPresented = true
        paletteView.placeholder = placeholder
        paletteView.query = seed
        showOverlay()
        runQuery(seed)
    }

    private func showOverlay() {
        guard let container = backdrop.superview else { return }
        layoutPalette(in: container)
        backdrop.isHidden = false
        backdrop.superview?.addSubview(backdrop, positioned: .above, relativeTo: nil)
        paletteView.focusQueryField()
    }

    private func makeCommandsProvider() -> CommandsPaletteProvider {
        CommandsPaletteProvider(registry: commandRegistry)
    }

    private func makeFilesProvider() -> FilesPaletteProvider? {
        guard let entries = fileEntriesProvider else { return nil }
        let root = workspaceRoot
        return FilesPaletteProvider(files: entries, root: { root }) { [weak self] url in
            self?.onOpenFile?(url)
        }
    }

    private func makeRecentProvider() -> RecentFilesPaletteProvider? {
        guard let entries = recentFileEntriesProvider else { return nil }
        return RecentFilesPaletteProvider(entries: entries) { [weak self] url in
            self?.onOpenFile?(url)
        }
    }

    private func makeSymbolsProvider() -> SymbolsPaletteProvider? {
        guard let index = symbolIndex else { return nil }
        return SymbolsPaletteProvider(index: index) { [weak self] symbol in
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
        return ProjectSearchPaletteProvider(engine: engine, root: root) { [weak self] result in
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
        case .recentFiles:
            return [makeRecentProvider()].compactMap { $0 }
        case .searchEverywhere:
            return ([makeRecentProvider(), makeFilesProvider(), makeSymbolsProvider()] as [SearchEverywhereProvider?])
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
        engine.search(effectiveQuery) { [weak self] sections in
            guard let self else { return }
            self.currentSections = sections
            self.paletteModel.clampSelection(count: self.flatItems.count)
            self.paletteView.update(sections: sections, selectedItemIndex: self.paletteModel.selectedIndex)
        }
    }

    private func activateSelection() {
        let items = flatItems
        guard items.indices.contains(paletteModel.selectedIndex) else {
            dismiss()
            return
        }
        let action = items[paletteModel.selectedIndex].action
        dismiss()
        action()
    }

    private func wirePaletteView() {
        paletteView.onQueryChange = { [weak self] query in
            guard let self else { return }
            self.paletteModel.query = query
            self.runQuery(query)
        }
        paletteView.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.paletteModel.moveSelection(by: delta, count: self.flatItems.count)
            self.paletteView.update(sections: self.currentSections, selectedItemIndex: self.paletteModel.selectedIndex)
        }
        paletteView.onConfirm = { [weak self] in self?.activateSelection() }
        paletteView.onCancel = { [weak self] in self?.dismiss() }
        paletteView.onActivateItemAtIndex = { [weak self] index in
            guard let self, self.flatItems.indices.contains(index) else { return }
            self.paletteModel.selectedIndex = index
            self.activateSelection()
        }
        backdrop.onClickOutsidePalette = { [weak self] in self?.dismiss() }
    }

    private func installOverlay(on textView: TextView) {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isHidden = true
        backdrop.paletteView = paletteView
        backdrop.addSubview(paletteView)
        textView.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: textView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: textView.bottomAnchor)
        ])
    }

    private func layoutPalette(in container: NSView) {
        let width = min(640, max(360, container.bounds.width - 80))
        let height: CGFloat = min(440, max(180, container.bounds.height * 0.55))
        let originX = ((container.bounds.width - width) / 2).rounded()
        let originY = (container.bounds.height - height - 28).rounded()
        paletteView.frame = CGRect(x: originX, y: max(originY, 12), width: width, height: height)
        paletteView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }
}

/// Full-bounds backdrop that dismisses the palette on a click outside it. Dims the editor
/// while the palette is visible.
private final class PaletteBackdropView: NSView {
    var onClickOutsidePalette: (() -> Void)?
    weak var paletteView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
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
}
