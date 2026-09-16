@preconcurrency import AppKit
import EditorIntelligence

/// Optional LSP and workspace services wired into ``EditorIntelligenceController``.
public struct EditorIntelligenceServices {
    public var formattingProvider: LSPFormattingProvider?
    public var signatureHelpProvider: LSPSignatureHelpProvider?
    public var codeActionProvider: LSPCodeActionProvider?
    public var symbolIndex: SymbolIndex?
    public var workspace: Workspace?
    /// Backs ``EditorIntelligenceController/searchProject(_:in:matchWholeWord:useRegularExpression:)``.
    /// Defaults to a private instance when unset; inject a shared one to dedupe concurrent scans
    /// of the same root across multiple controllers.
    public var projectSearchEngine: ProjectSearchEngine?

    public init(
        formattingProvider: LSPFormattingProvider? = nil,
        signatureHelpProvider: LSPSignatureHelpProvider? = nil,
        codeActionProvider: LSPCodeActionProvider? = nil,
        symbolIndex: SymbolIndex? = nil,
        workspace: Workspace? = nil,
        projectSearchEngine: ProjectSearchEngine? = nil
    ) {
        self.formattingProvider = formattingProvider
        self.signatureHelpProvider = signatureHelpProvider
        self.codeActionProvider = codeActionProvider
        self.symbolIndex = symbolIndex
        self.workspace = workspace
        self.projectSearchEngine = projectSearchEngine
    }
}

/// Wires Editor Intelligence Platform services into a live `TextView`.
///
/// Owns the `RunestoneEditorAdapter`, mounts completion/hover/ghost-text UI, and drives
/// completion, hover, diagnostics, formatting, code actions, outline, breadcrumbs, and
/// workspace search from editor events.
@MainActor
public final class EditorIntelligenceController {
    public let adapter: EditorAdapter
    public let completionEngine: CompletionEngine
    public let hoverEngine: HoverEngine
    public let diagnosticEngine: DiagnosticEngine
    public let navigationEngine: NavigationEngine?
    /// Not currently invoked from anywhere in this controller — stored for callers who drive
    /// refactoring themselves. Whoever wires up a rename invocation: `RenameOperation`/
    /// `LSPRenameProvider` both take a single cursor position (EIP's `Cursor` is single-position
    /// by construction; there's no multi-position `textDocument/rename` request in LSP), so
    /// `collapseMultiSelectionToPrimary()` before requesting and apply the result through
    /// `TextEditApplicator` — don't attempt to extend rename itself to multiple sites.
    public let refactoringEngine: RefactoringEngine?

    public let breadcrumbBarView = BreadcrumbBarView()
    public let outlineSidebarView = OutlineSidebarView()
    public let codeActionView = CodeActionView()
    public let workspaceSearchPanelView = WorkspaceSearchPanelView()

    private weak var textView: TextView?
    private var eventTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var signatureHelpTask: Task<Void, Never>?
    private var outlineTask: Task<Void, Never>?
    private var breadcrumbTask: Task<Void, Never>?

    private let formattingProvider: LSPFormattingProvider?
    private let signatureHelpProvider: LSPSignatureHelpProvider?
    private let codeActionProvider: LSPCodeActionProvider?
    private let symbolIndex: SymbolIndex?
    private let workspace: Workspace?
    private let workspaceSearchEngine = WorkspaceSearchEngine()
    private let projectSearchEngine: ProjectSearchEngine

    private let overlayContainer = NSView()
    private let completionPanelView: CompletionPanelView
    private let hoverWindowView: HoverWindowView
    private let ghostTextView: GhostTextView
    private let parameterHintsView: ParameterHintsView

    private var completionItems: [CompletionItem] = []
    private var selectedCompletionIndex = 0
    private var isCompletionVisible = false
    private var currentReplacementRange: EditorIntelligence.TextRange?
    private var ghostTextModel: GhostTextModel?
    private var latestDiagnostics: [Diagnostic] = []
    private let forwardingDelegateBox: EditorIntelligenceForwardingDelegate

    /// Create a controller that connects EIP services to a text view.
    ///
    /// Pass an existing ``EditorAdapter`` (e.g. ``RunestoneWorkbenchEditorAdapter``) when the host
    /// already bridges documents with stable IDs. When `adapter` is nil, a per-view
    /// ``RunestoneEditorAdapter`` is created.
    public init(
        textView: TextView,
        context: EditorContext = EditorContext(),
        adapter: EditorAdapter? = nil,
        completionEngine: CompletionEngine,
        hoverEngine: HoverEngine,
        diagnosticEngine: DiagnosticEngine,
        navigationEngine: NavigationEngine? = nil,
        refactoringEngine: RefactoringEngine? = nil,
        services: EditorIntelligenceServices = EditorIntelligenceServices(),
        forwardingDelegate: TextViewDelegate? = nil
    ) {
        self.textView = textView
        self.completionEngine = completionEngine
        self.hoverEngine = hoverEngine
        self.diagnosticEngine = diagnosticEngine
        self.navigationEngine = navigationEngine
        self.refactoringEngine = refactoringEngine
        self.formattingProvider = services.formattingProvider
        self.signatureHelpProvider = services.signatureHelpProvider
        self.codeActionProvider = services.codeActionProvider
        self.symbolIndex = services.symbolIndex
        self.workspace = services.workspace
        self.projectSearchEngine = services.projectSearchEngine ?? ProjectSearchEngine()

        let placeholderRange = EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0),
            end: TextPosition(line: 0, column: 0, utf16Offset: 0)
        )
        completionPanelView = CompletionPanelView(
            model: CompletionPanelModel(items: [], replacementRange: placeholderRange)
        )
        hoverWindowView = HoverWindowView(
            model: HoverWindowModel(contents: "", anchorRange: placeholderRange)
        )
        ghostTextView = GhostTextView(
            model: GhostTextModel(text: "", anchorPosition: placeholderRange.start)
        )
        parameterHintsView = ParameterHintsView(
            model: ParameterHintsModel(signatures: [])
        )
        let forwarding = EditorIntelligenceForwardingDelegate(userDelegate: forwardingDelegate)
        forwardingDelegateBox = forwarding

        if let adapter {
            self.adapter = adapter
        } else {
            let runestoneAdapter = RunestoneEditorAdapter(textView: textView, context: context)
            runestoneAdapter.forwardingDelegate = forwarding
            self.adapter = runestoneAdapter
        }

        installOverlayViews(on: textView)
        configureAccessoryViews()
        textView.addKeyDownInterceptor { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        let previousActionHandler = textView.editorActionHandler
        textView.editorActionHandler = { [weak self] action in
            if self?.handleEditorAction(action) == true {
                return true
            }
            return previousActionHandler?(action) ?? false
        }
        forwarding.attach(controller: self)
        startObservingEvents()
    }

    /// Invoked with the candidates when "Go to Definition/Implementation" resolves to more than
    /// one location. Wire this to a picker (e.g. `CommandPaletteController.presentList`); if
    /// unset, the first location is used.
    public var onPresentNavigationChoices: (([Location]) -> Void)?
    /// Invoked when a navigation target is in a different document (`Location.url` set and
    /// different). Return `true` if the host opened it; otherwise the target is focused in the
    /// current text view.
    public var onOpenLocationInOtherDocument: ((Location) -> Bool)?
    /// Invoked for `.findInFiles` / ⌘⇧F. Present your own UI here (a dedicated panel, a sheet…)
    /// and call ``searchProject(_:in:matchWholeWord:useRegularExpression:)`` to run it; return
    /// `true` once handled. Left `nil`, the action falls through to the command palette's own
    /// `.findInFiles` handling instead.
    public var onRequestProjectSearch: (() -> Bool)?

    private func handleEditorAction(_ action: EditorActionID) -> Bool {
        switch action {
        case .reformatCode:
            guard formattingProvider != nil else { return false }
            formatDocument()
            return true
        case .goToDefinition:
            return navigate(kind: .definition)
        case .goToImplementation:
            return navigate(kind: .implementation)
        case .findUsages:
            return navigate(kind: .references)
        case .triggerCompletion:
            triggerCompletion()
            return true
        case .findInFiles:
            guard let onRequestProjectSearch else { return false }
            return onRequestProjectSearch()
        default:
            return false
        }
    }

    /// Runs the navigation engine for `kind` at the current cursor and focuses the result.
    @discardableResult
    public func navigate(kind: NavigationKind) -> Bool {
        guard let navigationEngine, let document = adapter.currentDocument else {
            return false
        }
        let context = NavigationContext(
            document: document,
            cursor: document.cursor,
            selection: document.selection,
            trigger: .manual,
            kind: kind
        )
        Task { [weak self] in
            let result = await navigationEngine.navigate(context: context)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .single(let location):
                    self.focus(location)
                case .multiple(let locations) where locations.count == 1:
                    self.focus(locations[0])
                case .multiple(let locations):
                    if let onPresentNavigationChoices = self.onPresentNavigationChoices {
                        onPresentNavigationChoices(locations)
                    } else if let first = locations.first {
                        self.focus(first)
                    }
                case .none:
                    break
                }
            }
        }
        return true
    }

    private func focus(_ location: Location) {
        guard let textView else { return }
        if let url = location.url, url != textView.documentURL,
           onOpenLocationInOtherDocument?(location) == true {
            return
        }
        textView.recordNavigationCheckpoint()
        let range = TextEditApplicator.nsRange(for: location.range, in: textView)
        textView.selectedRanges = [range]
        textView.scrollRangeToVisible(range)
    }

    deinit {
        eventTask?.cancel()
        hoverTask?.cancel()
        completionTask?.cancel()
        signatureHelpTask?.cancel()
        outlineTask?.cancel()
        breadcrumbTask?.cancel()
    }

    // MARK: - Public API

    /// Manually trigger a completion request at the current cursor.
    public func triggerCompletion() {
        requestCompletion(trigger: .manual)
    }

    /// Dismiss any visible completion UI.
    public func dismissCompletion() {
        hideCompletionPanel()
        completionTask?.cancel()
        Task { await completionEngine.cancel() }
    }

    /// Apply the currently selected completion item.
    public func acceptSelectedCompletion() {
        guard isCompletionVisible,
              completionItems.indices.contains(selectedCompletionIndex),
              let replacementRange = currentReplacementRange else {
            return
        }
        applyCompletion(completionItems[selectedCompletionIndex], replacementRange: replacementRange)
        hideCompletionPanel()
    }

    /// Request hover information for the current cursor position.
    public func requestHover() {
        guard let document = adapter.currentDocument else {
            return
        }
        hoverTask?.cancel()
        let context = HoverContext(
            document: document,
            cursor: document.cursor,
            selection: document.selection,
            trigger: .manual
        )
        hoverTask = Task { [weak self] in
            guard let self else { return }
            if let result = await hoverEngine.hover(context: context) {
                await MainActor.run {
                    self.showHover(result, document: document)
                }
            }
        }
    }

    /// Refresh diagnostics and apply squiggles to the text view.
    public func refreshDiagnostics() {
        guard let document = adapter.currentDocument, let textView else {
            return
        }
        Task {
            let report = await diagnosticEngine.diagnostics(for: document)
            await MainActor.run {
                self.latestDiagnostics = report.diagnostics
                textView.diagnostics = report.diagnostics.map { TextViewDiagnostic($0, in: textView) }
            }
        }
    }

    /// Format the entire document using the configured LSP formatting provider.
    public func formatDocument() {
        guard let document = adapter.currentDocument, let formattingProvider, let textView else {
            return
        }
        Task {
            let edits = await formattingProvider.formatDocument(document)
            await MainActor.run {
                TextEditApplicator.apply(edits, in: textView)
            }
        }
    }

    /// Format the current selection using the configured LSP formatting provider. With multiple
    /// selections active (multi-caret or block), every non-empty range is formatted individually
    /// and the results applied together.
    public func formatSelection() {
        guard let document = adapter.currentDocument, let formattingProvider, let textView else {
            formatDocument()
            return
        }
        let ranges = document.selection.allRanges.filter { $0.start != $0.end }
        guard !ranges.isEmpty else {
            formatDocument()
            return
        }
        Task {
            var allEdits: [EditorIntelligence.TextEdit] = []
            for range in ranges {
                let edits = await formattingProvider.formatSelection(in: document, range: range)
                allEdits.append(contentsOf: edits)
            }
            await MainActor.run {
                TextEditApplicator.apply(allEdits, in: textView)
            }
        }
    }

    /// Request code actions at the current cursor and show the action panel.
    public func requestCodeActions() {
        guard let document = adapter.currentDocument, let codeActionProvider else {
            return
        }
        Task {
            let actions = await codeActionProvider.codeActions(
                for: document,
                at: document.cursor.position,
                diagnostics: latestDiagnostics
            )
            await MainActor.run {
                guard !actions.isEmpty else {
                    self.hideCodeActions()
                    return
                }
                self.showCodeActions(actions, anchorRange: document.selection.range)
            }
        }
    }

    /// Apply a code action's edits to the current document.
    public func applyCodeAction(_ action: CodeAction) {
        guard let textView else {
            return
        }
        TextEditApplicator.apply(action.edits, in: textView)
        hideCodeActions()
    }

    /// Refresh the outline sidebar from the symbol index.
    public func refreshOutline() {
        guard let document = adapter.currentDocument, let symbolIndex else {
            return
        }
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            guard let self else { return }
            let symbols = await symbolIndex.symbols(in: document.id)
            let items = OutlineBuilder.build(from: symbols)
            let selectedID = self.selectedOutlineItemID(for: document.cursor.position, in: items)
            await MainActor.run {
                self.outlineSidebarView.update(model: OutlineModel(items: items, selectedItemID: selectedID))
            }
        }
    }

    /// Refresh breadcrumb segments for the current cursor.
    public func refreshBreadcrumbs() {
        guard let document = adapter.currentDocument, let symbolIndex else {
            return
        }
        guard textView?.languageConfiguration.showsBreadcrumbs ?? true else {
            breadcrumbBarView.update(model: BreadcrumbBarModel(segments: []))
            return
        }
        breadcrumbTask?.cancel()
        breadcrumbTask = Task { [weak self] in
            guard let self else { return }
            let symbols = await symbolIndex.symbols(in: document.id)
            let cursorOffset = document.cursor.position.utf16Offset
            // Share BreadcrumbProvider's logic rather than re-deriving it here.
            let locations = BreadcrumbProvider.breadcrumbLocations(from: symbols, cursorOffset: cursorOffset)
            let segments = locations.map { BreadcrumbSegment(title: $0.displayName, range: $0.range) }
            await MainActor.run {
                self.breadcrumbBarView.update(model: BreadcrumbBarModel(segments: segments))
            }
        }
    }

    /// Search all open workspace documents and present results.
    public func searchWorkspace(query: String, matchWholeWord: Bool = false, useRegularExpression: Bool = false) {
        guard let workspace else {
            return
        }
        let searchQuery = WorkspaceSearchQuery(
            text: query,
            matchWholeWord: matchWholeWord,
            useRegularExpression: useRegularExpression
        )
        Task {
            let results = await workspaceSearchEngine.search(searchQuery, in: workspace)
            await MainActor.run {
                self.presentWorkspaceSearch(query: query, results: results)
            }
        }
    }

    /// Disk-wide project search — the counterpart to ``searchWorkspace(query:matchWholeWord:useRegularExpression:)``,
    /// which only sees open documents. Runs off the main actor; call from an
    /// ``onRequestProjectSearch`` handler that presents its own results UI.
    public func searchProject(
        _ query: String,
        in root: URL,
        matchWholeWord: Bool = false,
        useRegularExpression: Bool = false
    ) async -> [ProjectSearchResult] {
        let searchQuery = WorkspaceSearchQuery(
            text: query,
            matchWholeWord: matchWholeWord,
            useRegularExpression: useRegularExpression
        )
        return await projectSearchEngine.search(searchQuery, in: root)
    }

    /// Mount the breadcrumb bar above the text view inside a container.
    public func installBreadcrumbBar(in container: NSView) {
        breadcrumbBarView.translatesAutoresizingMaskIntoConstraints = false
        if breadcrumbBarView.superview !== container {
            container.addSubview(breadcrumbBarView)
        }
        guard let textView else { return }
        NSLayoutConstraint.activate([
            breadcrumbBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            breadcrumbBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            breadcrumbBarView.topAnchor.constraint(equalTo: container.topAnchor),
            breadcrumbBarView.heightAnchor.constraint(equalToConstant: 24)
        ])
        if textView.superview === container {
            if !textView.translatesAutoresizingMaskIntoConstraints {
                // Autolayout host: pin the text view below the bar instead of nudging its frame.
                textView.topAnchor.constraint(equalTo: breadcrumbBarView.bottomAnchor).isActive = true
            } else {
                textView.frame.origin.y = 24
            }
        }
    }

    /// Mount the outline sidebar to the leading edge of a container.
    public func installOutlineSidebar(in container: NSView, width: CGFloat = 220) {
        outlineSidebarView.translatesAutoresizingMaskIntoConstraints = false
        if outlineSidebarView.superview !== container {
            container.addSubview(outlineSidebarView)
        }
        NSLayoutConstraint.activate([
            outlineSidebarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outlineSidebarView.topAnchor.constraint(equalTo: container.topAnchor),
            outlineSidebarView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            outlineSidebarView.widthAnchor.constraint(equalToConstant: width)
        ])
        refreshOutline()
    }

    // MARK: - Setup

    private func configureAccessoryViews() {
        breadcrumbBarView.onSelectSegment = { [weak self] segment in
            self?.focus(range: segment.range)
        }
        outlineSidebarView.onSelectItem = { [weak self] item in
            self?.focus(range: item.range)
        }
        codeActionView.onSelectAction = { [weak self] action in
            self?.applyCodeAction(action)
        }
        workspaceSearchPanelView.onSelectResult = { [weak self] result in
            self?.focusWorkspaceResult(result)
        }
    }

    private func installOverlayViews(on textView: TextView) {
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isHidden = true
        textView.addSubview(overlayContainer)

        for view in [completionPanelView, hoverWindowView, ghostTextView, parameterHintsView, codeActionView, workspaceSearchPanelView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            overlayContainer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            overlayContainer.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: textView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: textView.bottomAnchor)
        ])
    }

    private func startObservingEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in adapter.events {
                await MainActor.run {
                    self.handleEditorEvent(event)
                }
            }
        }
    }

    private func handleEditorEvent(_ event: EditorEvent) {
        guard adapterMatchesActiveTextView() else { return }
        switch event {
        case .documentChanged, .documentEdited:
            refreshDiagnostics()
            refreshOutline()
            if isCompletionVisible {
                requestCompletion(trigger: .idle)
            }
        case .cursorMoved, .selectionChanged:
            scheduleHoverRequest()
            refreshBreadcrumbs()
        case .documentOpened:
            refreshDiagnostics()
            refreshOutline()
            refreshBreadcrumbs()
        default:
            break
        }
    }

    // MARK: - Completion

    private func requestCompletion(trigger: RequestTrigger) {
        guard let document = adapter.currentDocument else {
            return
        }
        let context = makeCompletionContext(document: document, trigger: trigger)
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await completionEngine.complete(context: context)
                await MainActor.run {
                    self.presentCompletion(items, replacementRange: context.range)
                }
            } catch {
                await MainActor.run {
                    self.hideCompletionPanel()
                }
            }
        }
    }

    private func presentCompletion(_ items: [CompletionItem], replacementRange: EditorIntelligence.TextRange) {
        guard !items.isEmpty, let textView else {
            hideCompletionPanel()
            return
        }
        completionItems = items
        selectedCompletionIndex = 0
        currentReplacementRange = replacementRange
        isCompletionVisible = true

        let model = CompletionPanelModel(
            items: items,
            selectedIndex: selectedCompletionIndex,
            replacementRange: replacementRange
        )
        completionPanelView.update(model: model)
        positionPanel(completionPanelView, near: replacementRange.end.utf16Offset, in: textView)
        completionPanelView.isHidden = false
        overlayContainer.isHidden = false

        if let first = items.first, first.insertText != first.label {
            showGhostText(first.insertText, at: replacementRange.end)
        }
    }

    private func hideCompletionPanel() {
        isCompletionVisible = false
        completionItems = []
        selectedCompletionIndex = 0
        currentReplacementRange = nil
        completionPanelView.isHidden = true
        hideGhostText()
        updateOverlayVisibility()
    }

    private func applyCompletion(_ item: CompletionItem, replacementRange: EditorIntelligence.TextRange) {
        guard let textView else {
            return
        }
        let nsRange = NSRange(
            location: replacementRange.start.utf16Offset,
            length: replacementRange.end.utf16Offset - replacementRange.start.utf16Offset
        )
        if item.kind == .snippet {
            let parser = SnippetParser()
            let nodes = parser.parse(item.insertText)
            let expander = SnippetExpander(
                nodes: nodes,
                context: SnippetExpansionContext(selectedText: textView.text(in: nsRange) ?? "")
            )
            let expansion = expander.expand()
            if textView.isMultiCursorActive {
                // Multi-caret completion still collapses placeholders: there is no per-caret
                // tab-stop session, so every site gets the default snippet text.
                let primaryCaretLocation = textView.selectedRange.location
                let relativeStartOffset = nsRange.location - primaryCaretLocation
                textView.replaceAtAllSelections(
                    relativeStartOffset: relativeStartOffset,
                    length: nsRange.length,
                    with: expansion.text
                )
            } else {
                textView.insertSnippet(expansion, replacing: nsRange)
            }
            return
        }
        if textView.isMultiCursorActive {
            // Apply the same relative edit -- "replace these N characters around the primary
            // caret" -- at every caret, not just the primary one.
            let primaryCaretLocation = textView.selectedRange.location
            let relativeStartOffset = nsRange.location - primaryCaretLocation
            textView.replaceAtAllSelections(relativeStartOffset: relativeStartOffset, length: nsRange.length, with: item.insertText)
        } else {
            textView.replace(nsRange, withText: item.insertText)
        }
    }

    private func moveCompletionSelection(delta: Int) {
        guard isCompletionVisible, !completionItems.isEmpty,
              let replacementRange = currentReplacementRange else {
            return
        }
        selectedCompletionIndex = (selectedCompletionIndex + delta + completionItems.count) % completionItems.count
        let model = CompletionPanelModel(
            items: completionItems,
            selectedIndex: selectedCompletionIndex,
            replacementRange: replacementRange
        )
        completionPanelView.update(model: model)
        let item = completionItems[selectedCompletionIndex]
        showGhostText(item.insertText, at: replacementRange.end)
    }

    // MARK: - Hover

    private func scheduleHoverRequest() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.requestHover()
            }
        }
    }

    private func showHover(_ result: HoverResult, document: Document) {
        guard let textView else {
            return
        }
        let anchorRange = result.range ?? document.selection.range
        let model = HoverWindowModel(
            contents: result.contents,
            anchorRange: anchorRange,
            isMarkdown: true
        )
        hoverWindowView.update(model: model)
        positionPanel(hoverWindowView, near: anchorRange.start.utf16Offset, in: textView, size: NSSize(width: 280, height: 80))
        hoverWindowView.isHidden = false
        overlayContainer.isHidden = false
    }

    private func hideHover() {
        hoverWindowView.isHidden = true
        updateOverlayVisibility()
    }

    // MARK: - Ghost Text

    private func showGhostText(_ text: String, at position: TextPosition) {
        guard let textView else {
            return
        }
        let model = GhostTextModel(text: text, anchorPosition: position)
        ghostTextModel = model
        ghostTextView.update(model: model)
        positionPanel(ghostTextView, near: position.utf16Offset, in: textView, size: NSSize(width: 200, height: 20))
        ghostTextView.isHidden = false
        overlayContainer.isHidden = false
    }

    private func hideGhostText() {
        ghostTextModel = nil
        ghostTextView.isHidden = true
        updateOverlayVisibility()
    }

    // MARK: - Parameter Hints

    /// Show parameter hints anchored near the cursor.
    public func showParameterHints(_ model: ParameterHintsModel) {
        guard let textView, let document = adapter.currentDocument else {
            return
        }
        parameterHintsView.update(model: model)
        positionPanel(
            parameterHintsView,
            near: document.cursor.position.utf16Offset,
            in: textView,
            size: NSSize(width: 360, height: 28)
        )
        parameterHintsView.isHidden = false
        overlayContainer.isHidden = false
    }

    public func hideParameterHints() {
        parameterHintsView.isHidden = true
        updateOverlayVisibility()
    }

    private func requestSignatureHelp() {
        guard let document = adapter.currentDocument, let signatureHelpProvider else {
            return
        }
        signatureHelpTask?.cancel()
        signatureHelpTask = Task { [weak self] in
            guard let self else { return }
            if let model = await signatureHelpProvider.signatureHelp(for: document, at: document.cursor.position) {
                await MainActor.run {
                    self.showParameterHints(model)
                }
            }
        }
    }

    // MARK: - Code Actions

    private func showCodeActions(_ actions: [CodeAction], anchorRange: EditorIntelligence.TextRange) {
        guard let textView else {
            return
        }
        codeActionView.update(model: CodeActionModel(actions: actions, anchorRange: anchorRange))
        positionPanel(
            codeActionView,
            near: anchorRange.start.utf16Offset,
            in: textView,
            size: NSSize(width: 280, height: min(CGFloat(actions.count) * 24 + 8, 200))
        )
        codeActionView.isHidden = false
        overlayContainer.isHidden = false
    }

    private func hideCodeActions() {
        codeActionView.isHidden = true
        updateOverlayVisibility()
    }

    // MARK: - Workspace Search

    private func presentWorkspaceSearch(query: String, results: [WorkspaceSearchResult]) {
        guard let textView, let document = adapter.currentDocument else {
            return
        }
        workspaceSearchPanelView.update(model: WorkspaceSearchModel(query: query, results: results))
        positionPanel(
            workspaceSearchPanelView,
            near: document.cursor.position.utf16Offset,
            in: textView,
            size: NSSize(width: 480, height: 180)
        )
        workspaceSearchPanelView.isHidden = false
        overlayContainer.isHidden = false
    }

    public func hideWorkspaceSearch() {
        workspaceSearchPanelView.isHidden = true
        updateOverlayVisibility()
    }

    // MARK: - Navigation Helpers

    private func focus(range: EditorIntelligence.TextRange) {
        guard let textView else {
            return
        }
        let nsRange = TextEditApplicator.nsRange(for: range, in: textView)
        textView.selectedRanges = [nsRange]
        textView.scrollRangeToVisible(nsRange)
    }

    private func focusWorkspaceResult(_ result: WorkspaceSearchResult) {
        focus(range: result.range)
        hideWorkspaceSearch()
    }

    private func selectedOutlineItemID(for position: TextPosition, in items: [OutlineItem]) -> UUID? {
        let offset = position.utf16Offset
        var match: OutlineItem?
        func walk(_ items: [OutlineItem]) {
            for item in items {
                let start = min(item.range.start.utf16Offset, item.range.end.utf16Offset)
                let end = max(item.range.start.utf16Offset, item.range.end.utf16Offset)
                if start <= offset, offset <= end {
                    match = item
                    walk(item.children)
                }
            }
        }
        walk(items)
        return match?.id
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 0x35 {
            hideHover()
            hideCodeActions()
            hideWorkspaceSearch()
            if isCompletionVisible {
                dismissCompletion()
                return true
            }
        }

        guard isCompletionVisible else {
            return false
        }

        switch event.keyCode {
        case 0x35:
            dismissCompletion()
            return true
        case 0x7D:
            moveCompletionSelection(delta: 1)
            return true
        case 0x7E:
            moveCompletionSelection(delta: -1)
            return true
        case 0x24, 0x4C:
            acceptSelectedCompletion()
            return true
        case 0x09 where !event.modifierFlags.contains(.shift):
            acceptSelectedCompletion()
            return true
        default:
            return false
        }
    }

    private func shouldTriggerCompletion(for text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else {
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar) || text == "." || text == ":"
    }

    private func shouldTriggerSignatureHelp(for text: String) -> Bool {
        text == "(" || text == ","
    }

    func handleTextInsertion(_ text: String) {
        if shouldTriggerSignatureHelp(for: text) {
            requestSignatureHelp()
        } else if text == ")" {
            hideParameterHints()
        }

        if shouldTriggerCompletion(for: text) {
            requestCompletion(trigger: .keystroke(text))
        } else if isCompletionVisible {
            dismissCompletion()
        }
    }

    // MARK: - Layout Helpers

    private func positionPanel(_ panel: NSView, near location: Int, in textView: TextView, size: NSSize = NSSize(width: 240, height: 120)) {
        let caretRect = textView.caretRect(for: IndexedPosition(index: location))
        let origin = CGPoint(
            x: caretRect.minX + textView.textContainerInset.left,
            y: caretRect.maxY + 4
        )
        panel.frame = CGRect(origin: origin, size: size)
    }

    private func updateOverlayVisibility() {
        let hasVisibleChild = !completionPanelView.isHidden
            || !hoverWindowView.isHidden
            || !ghostTextView.isHidden
            || !parameterHintsView.isHidden
            || !codeActionView.isHidden
            || !workspaceSearchPanelView.isHidden
        overlayContainer.isHidden = !hasVisibleChild
    }
    private func adapterMatchesActiveTextView() -> Bool {
        guard let textView else { return false }
        if let workbench = adapter as? RunestoneWorkbenchEditorAdapter {
            return workbench.textView === textView
        }
        if let runestone = adapter as? RunestoneEditorAdapter {
            return runestone.textView === textView
        }
        return true
    }
}

// MARK: - Text change hook via forwarding delegate wrapper

/// Delegate wrapper that forwards editor callbacks to an intelligence controller.
@MainActor
public final class EditorIntelligenceForwardingDelegate: TextViewDelegate {
    private weak var controller: EditorIntelligenceController?
    public weak var userDelegate: TextViewDelegate?

    public init(userDelegate: TextViewDelegate? = nil) {
        self.userDelegate = userDelegate
    }

    func attach(controller: EditorIntelligenceController) {
        self.controller = controller
    }

    public func textViewDidChange(_ textView: TextView) {
        userDelegate?.textViewDidChange(textView)
    }

    public func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let allowed = userDelegate?.textView(textView, shouldChangeTextIn: range, replacementText: text) ?? true
        if allowed, text.count == 1 {
            controller?.handleTextInsertion(text)
        }
        return allowed
    }

    public func textViewDidChangeSelection(_ textView: TextView) {
        userDelegate?.textViewDidChangeSelection(textView)
    }

    public func textView(_ textView: TextView,
                         didChangeDistractionFreeChromeVisibility isVisible: Bool,
                         transitionDuration: TimeInterval) {
        userDelegate?.textView(
            textView,
            didChangeDistractionFreeChromeVisibility: isVisible,
            transitionDuration: transitionDuration
        )
    }

    public func textViewDidFinishSyntaxParse(_ textView: TextView) {
        userDelegate?.textViewDidFinishSyntaxParse(textView)
    }

    public func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
        userDelegate?.textView(textView, didChangeContent: change)
    }
}
