@preconcurrency import AppKit
import EditorIntelligence
import os

/// Debug-level completion tracing: `log stream --level debug --predicate 'subsystem == "Penumbra" && category == "Completion"'`.
let completionLog = Logger(subsystem: "Penumbra", category: "Completion")

/// Optional LSP and workspace services wired into ``EditorIntelligenceController``.
public struct EditorIntelligenceServices {
    public var formattingProvider: (any FormattingProviding)?
    /// Parameter info after `(`/`,` and after accepting a method completion. Any
    /// ``SignatureHelpProviding`` works: ``LSPSignatureHelpProvider`` or a native one.
    public var signatureHelpProvider: (any SignatureHelpProviding)?
    public var codeActionProvider: (any CodeActionProviding)?
    /// Language-aware breadcrumbs, tried before the ones derived from ``symbolIndex``.
    public var breadcrumbProvider: (any BreadcrumbProviding)?
    public var symbolIndex: SymbolIndex?
    public var workspace: Workspace?
    /// Backs ``EditorIntelligenceController/searchProject(_:in:matchWholeWord:useRegularExpression:)``.
    /// Defaults to a private instance when unset; inject a shared one to dedupe concurrent scans
    /// of the same root across multiple controllers.
    public var projectSearchEngine: ProjectSearchEngine?

    public init(
        formattingProvider: (any FormattingProviding)? = nil,
        signatureHelpProvider: (any SignatureHelpProviding)? = nil,
        codeActionProvider: (any CodeActionProviding)? = nil,
        breadcrumbProvider: (any BreadcrumbProviding)? = nil,
        symbolIndex: SymbolIndex? = nil,
        workspace: Workspace? = nil,
        projectSearchEngine: ProjectSearchEngine? = nil
    ) {
        self.formattingProvider = formattingProvider
        self.signatureHelpProvider = signatureHelpProvider
        self.codeActionProvider = codeActionProvider
        self.breadcrumbProvider = breadcrumbProvider
        self.symbolIndex = symbolIndex
        self.workspace = workspace
        self.projectSearchEngine = projectSearchEngine
    }
}

/// Wires Editor Intelligence Platform services into a live `TextView`.
///
/// Owns the `PenumbraEditorAdapter`, mounts completion/hover/ghost-text UI, and drives
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
    private var jumpToDefinitionController: JumpToDefinitionController?

    private let formattingProvider: (any FormattingProviding)?
    private let signatureHelpProvider: (any SignatureHelpProviding)?
    private let codeActionProvider: (any CodeActionProviding)?
    private let breadcrumbProvider: (any BreadcrumbProviding)?
    private let symbolIndex: SymbolIndex?
    private let workspace: Workspace?
    private let workspaceSearchEngine = WorkspaceSearchEngine()
    private let projectSearchEngine: ProjectSearchEngine

    private let overlayContainer = IntelligenceOverlayView()
    private let completionPanelView: CompletionPanelView
    private let hoverWindowView: HoverWindowView
    private let ghostTextView: GhostTextView
    private let parameterHintsView: ParameterHintsView

    /// Items currently shown, filtered and ranked for the live prefix.
    private var completionItems: [CompletionItem] = []
    /// Everything the providers returned for the current session, re-filtered locally on each
    /// keystroke so the list reacts instantly while a fresh request runs.
    private var unfilteredCompletionItems: [CompletionItem] = []
    private var selectedCompletionIndex = 0
    private var isCompletionVisible = false
    private var currentReplacementRange: EditorIntelligence.TextRange?
    /// UTF-16 offset where the identifier being completed starts.
    private var completionAnchor: Int?
    /// 0 while typing, 1 for the first explicit completion, 2 after a noticeable repeated one.
    private var completionInvocationCount = 1
    private var completionMode: CompletionMode = .basic
    private var completionShownAt: Date?
    private var completionPainted = false
    private var frozenCompletionKeys: [String] = []
    private var frozenPrefix: String?
    private var completionGeneration = 0
    private var completionAdvertisement: String?
    private var completionIsComputing = false
    private var completionEmptyText: String?
    private var completionHoldTask: Task<Void, Never>?
    private var pendingCompletionUpdate: CompletionUpdate?
    private var resizeObserver: NSObjectProtocol?
    private var completionWindowFrame: NSRect?
    /// Scrolling lays the text out and can post a window-resize notification for the same frame.
    private var suppressResizeDismissal = false
    /// The session was opened explicitly (Ctrl+Space) or the user moved the selection, so the
    /// selected item may be committed by `.`, `(` or `;`.
    private var isCompletionSelectionExplicit = false
    private var liveDocumentVersion = 0
    private var emptyCompletionHintTask: Task<Void, Never>?
    private var windowObserver: NSObjectProtocol?
    private var ghostTextModel: GhostTextModel?
    private var latestDiagnostics: [Diagnostic] = []
    private var diagnosticsTask: Task<Void, Never>?
    private let forwardingDelegateBox: EditorIntelligenceForwardingDelegate

    /// Create a controller that connects EIP services to a text view.
    ///
    /// Pass an existing ``EditorAdapter`` (e.g. ``PenumbraWorkbenchEditorAdapter``) when the host
    /// already bridges documents with stable IDs. When `adapter` is nil, a per-view
    /// ``PenumbraEditorAdapter`` is created.
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
        self.breadcrumbProvider = services.breadcrumbProvider
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
            let penumbraAdapter = PenumbraEditorAdapter(textView: textView, context: context)
            penumbraAdapter.forwardingDelegate = forwarding
            self.adapter = penumbraAdapter
        }

        installOverlayViews(on: textView)
        configureAccessoryViews()
        textView.addKeyDownInterceptor { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        textView.addTypingObserver { [weak self] event in
            self?.handleTypingEvent(event)
        }
        textView.onCaretRepositioningClick = { [weak self] in
            guard let self, self.isCompletionVisible || self.completionAnchor != nil else { return }
            self.dismissCompletion()
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // `Notification` isn't Sendable. Read the window identity on this queue and send only that.
            let resignedWindowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let resignedWindowID,
                      resignedWindowID == self.textView?.window.map(ObjectIdentifier.init) else { return }
                if self.isCompletionVisible {
                    self.dismissCompletion()
                }
            }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let resizedWindowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let resizedWindowID,
                      resizedWindowID == self.textView?.window.map(ObjectIdentifier.init),
                      self.isCompletionVisible, !self.suppressResizeDismissal else { return }
                guard let frame = self.textView?.window?.frame else { return }
                // Layout during scrolling can post this without the window frame changing.
                guard frame != self.completionWindowFrame else { return }
                self.completionWindowFrame = frame
                self.dismissCompletion()
            }
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
        if let navigationEngine {
            let jump = JumpToDefinitionController(textView: textView, adapter: self.adapter, navigationEngine: navigationEngine)
            jump.onOpenInOtherDocument = { [weak self] location in
                self?.onOpenLocationInOtherDocument?(location) ?? false
            }
            jump.onPresentChoices = { [weak self] kind, locations in
                guard let self else { return }
                if let onPresentNavigationChoices = self.onPresentNavigationChoices {
                    onPresentNavigationChoices(kind, locations)
                } else if let first = locations.first {
                    self.focus(first)
                }
            }
            jumpToDefinitionController = jump
        }

        completionPanelView.onSelectRow = { [weak self] index in
            self?.selectCompletionRow(index)
        }
        completionPanelView.onAcceptRow = { [weak self] index in
            self?.acceptCompletionRow(index)
        }
    }

    /// Invoked with the request kind and the candidates when "Go to Definition/Implementation"
    /// resolves to more than one location. Wire this to a picker (e.g.
    /// `CommandPaletteController.presentList`, titled by `kind`); if unset, the first location is
    /// used.
    public var onPresentNavigationChoices: ((NavigationKind, [Location]) -> Void)?
    /// Invoked when a navigation target is in a different document (`Location.url` set and
    /// different). Return `true` if the host opened it; otherwise the target is focused in the
    /// current text view.
    public var onOpenLocationInOtherDocument: ((Location) -> Bool)?
    /// Invoked for `.findInFiles` / ⌘⇧F. Present your own UI here (a dedicated panel, a sheet…)
    /// and call ``searchProject(_:in:matchWholeWord:useRegularExpression:)`` to run it; return
    /// `true` once handled. Left `nil`, the action falls through to the command palette's own
    /// `.findInFiles` handling instead.
    public var onRequestProjectSearch: (() -> Bool)?
    /// Invoked for `.typeHierarchy` (⌃H in the IntelliJ keymap). The host resolves the type at the
    /// caret and shows its hierarchy; return `true` once handled. Left `nil`, the action is not
    /// handled.
    public var onRequestTypeHierarchy: (() -> Bool)?
    /// Invoked whenever enclosing-symbol breadcrumbs are recomputed. Hosts that render their own
    /// trail (rather than ``breadcrumbBarView``) should assign this and ignore the AppKit bar.
    public var onBreadcrumbsUpdated: (([BreadcrumbSegment]) -> Void)?
    /// Invoked on the main actor after each diagnostics refresh with the active document's report,
    /// so a host can list problems (e.g. a Problems panel). Only the latest refresh is delivered:
    /// a refresh superseded by a newer one is cancelled and never reported.
    public var onDiagnosticsUpdated: ((DiagnosticReport) -> Void)?

    private func handleEditorAction(_ action: EditorActionID) -> Bool {
        switch action {
        case .reformatCode:
            // A provider that doesn't handle this document (a Java formatter, in a Swift file)
            // leaves it to the editor's own re-indent.
            guard let formattingProvider, let document = adapter.currentDocument,
                  formattingProvider.supportsFormatting(document) else { return false }
            formatSelection()
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
        case .triggerSmartCompletion:
            triggerSmartCompletion()
            return true
        case .quickDocumentation:
            requestHover(trigger: .manual)
            return true
        case .showContextActions:
            guard codeActionProvider != nil else { return false }
            requestCodeActions()
            return true
        case .optimizeImports:
            guard codeActionProvider != nil else { return false }
            Task { [weak self] in
                if await self?.organizeImports() == false {
                    self?.showTransientHint("Nothing to optimize")
                }
            }
            return true
        case .findInFiles:
            guard let onRequestProjectSearch else { return false }
            return onRequestProjectSearch()
        case .typeHierarchy:
            guard let onRequestTypeHierarchy else { return false }
            return onRequestTypeHierarchy()
        default:
            return false
        }
    }

    /// Runs the navigation engine for `kind` at the current cursor and focuses the result.
    @discardableResult
    public func navigate(kind: NavigationKind) -> Bool {
        guard let navigationEngine, let textView, let base = adapter.currentDocument else {
            return false
        }
        // The adapter snapshot lags the live buffer, and the caret to resolve is the one on screen.
        let utf16 = textView.selectedRange.location
        let position = TextPosition(line: 0, column: utf16, utf16Offset: utf16)
        let cursor = Cursor(position: position)
        let document = Document(
            id: base.id,
            url: textView.documentURL ?? base.url,
            displayName: base.displayName,
            contentSnapshot: TextSnapshot(version: base.version, text: textView.text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: cursor,
            viewport: base.viewport,
            languageIdentifier: base.languageIdentifier
        )
        let context = NavigationContext(
            document: document,
            cursor: cursor,
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
                        onPresentNavigationChoices(kind, locations)
                    } else if let first = locations.first {
                        self.focus(first)
                    }
                case .none:
                    self.showTransientHint(Self.noResultText(for: kind, languageIdentifier: document.languageIdentifier))
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
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        completionHoldTask?.cancel()
        emptyCompletionHintTask?.cancel()
        eventTask?.cancel()
        hoverTask?.cancel()
        completionTask?.cancel()
        signatureHelpTask?.cancel()
        outlineTask?.cancel()
        breadcrumbTask?.cancel()
    }

    // MARK: - Public API

    /// Manually trigger a completion request at the current cursor (Ctrl+Space). Invoking it
    /// again while the popup is open asks providers for a broader result, like IntelliJ's second
    /// Ctrl+Space (e.g. classes that aren't imported yet).
    public func triggerCompletion() {
        beginExplicitCompletion(mode: .basic)
    }

    /// Smart type completion (Ctrl+Shift+Space): only suggestions of the expected type.
    public func triggerSmartCompletion() {
        beginExplicitCompletion(mode: .smart)
    }

    private func beginExplicitCompletion(mode: CompletionMode) {
        let noticeable = isCompletionVisible && completionMode == mode
            && completionShownAt.map { Date().timeIntervalSince($0) >= 0.3 } == true
        if completionMode != mode {
            frozenCompletionKeys = []
            frozenPrefix = nil
        }
        completionMode = mode
        completionInvocationCount = noticeable ? max(completionInvocationCount + 1, 2) : 1
        isCompletionSelectionExplicit = true
        requestCompletion(trigger: .manual)
    }

    /// Whether the completion popup is showing.
    public var isShowingCompletion: Bool {
        isCompletionVisible
    }

    /// Labels of the items currently shown in the completion popup, in display order.
    public var visibleCompletionItems: [CompletionItem] {
        isCompletionVisible ? completionItems : []
    }

    /// Where the completion popup is, in the text view's viewport coordinates (tests).
    var completionPanelFrameInViewport: CGRect? {
        guard isCompletionVisible, let textView, completionPanelView.superview === overlayContainer,
              overlayContainer.superview === textView, !overlayContainer.isHidden else { return nil }
        return textView.convert(completionPanelView.frame, from: overlayContainer)
    }

    /// Moves the popup's selection by `delta` rows, wrapping around (what ↑/↓ do).
    public func moveCompletionSelection(by delta: Int) {
        moveCompletionSelection(delta: delta)
    }

    /// The selected row of the completion popup.
    public var selectedCompletionItem: CompletionItem? {
        guard isCompletionVisible, completionItems.indices.contains(selectedCompletionIndex) else { return nil }
        return completionItems[selectedCompletionIndex]
    }

    /// Dismiss any visible completion UI.
    public func dismissCompletion() {
        hideCompletionPanel()
        completionTask?.cancel()
        Task { await completionEngine.cancel() }
    }

    /// Apply the currently selected completion item. `replacingIdentifier` (Tab) also replaces
    /// the rest of the identifier after the caret; otherwise (Enter) only the typed prefix is.
    public func acceptSelectedCompletion(replacingIdentifier: Bool = false) {
        guard isCompletionVisible, completionItems.indices.contains(selectedCompletionIndex) else {
            return
        }
        let item = completionItems[selectedCompletionIndex]
        hideCompletionPanel()
        applyCompletion(item, replacingIdentifier: replacingIdentifier)
    }

    /// Request hover information for the current cursor position.
    /// Shows hover information for the symbol at the caret. `trigger` is `.idle` for the popup
    /// that follows a resting caret (a provider may stay quiet then) and `.manual` for an explicit
    /// request such as Quick Documentation.
    public func requestHover(trigger: RequestTrigger = .manual) {
        guard let document = liveDocument() ?? adapter.currentDocument else {
            return
        }
        hoverTask?.cancel()
        let context = HoverContext(
            document: document,
            cursor: document.cursor,
            selection: document.selection,
            trigger: trigger
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
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self, diagnosticEngine] in
            let report = await diagnosticEngine.diagnostics(for: document)
            guard !Task.isCancelled, let self, let textView = self.textView else { return }
            self.latestDiagnostics = report.diagnostics
            textView.diagnostics = report.diagnostics.map { TextViewDiagnostic($0, in: textView) }
            self.onDiagnosticsUpdated?(report)
        }
    }

    /// Format the entire document using the configured LSP formatting provider.
    public func formatDocument() {
        guard let document = liveDocument(), let formattingProvider, let textView else {
            return
        }
        Task {
            let edits = await formattingProvider.formatDocument(document)
            await MainActor.run {
                TextEditApplicator.apply(edits, in: textView)
            }
        }
    }

    /// Format the current selection using the configured formatting provider. With multiple
    /// selections active (multi-caret or block), every non-empty range is formatted individually
    /// and the results applied together. With nothing selected the whole document is formatted.
    public func formatSelection() {
        guard let document = liveDocument(), let formattingProvider, let textView else {
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
        guard let document = liveDocument(), let codeActionProvider else {
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
                    self.showTransientHint("No context actions available")
                    return
                }
                self.showCodeActions(actions, anchorRange: document.selection.range)
            }
        }
    }

    /// Applies the provider's organize-imports action (``CodeAction/organizeImportsKind``) to the
    /// current document. Returns `false` when there is no provider or nothing to organize.
    @discardableResult
    public func organizeImports() async -> Bool {
        guard let codeActionProvider, let textView, let document = liveDocument() else {
            return false
        }
        let actions = await codeActionProvider.codeActions(
            for: document,
            at: document.cursor.position,
            diagnostics: latestDiagnostics
        )
        guard let action = actions.first(where: { $0.kind == CodeAction.organizeImportsKind }) else {
            return false
        }
        TextEditApplicator.apply(action.edits, in: textView)
        return true
    }

    /// The document as it is on screen: the adapter's snapshot lags the live buffer, so code
    /// actions get the live text and a caret with its real line and column.
    private func liveDocument() -> Document? {
        guard let textView, let base = adapter.currentDocument else {
            return nil
        }
        let text = textView.text
        let ns = text as NSString
        func position(_ offset: Int) -> TextPosition {
            let utf16 = min(max(0, offset), ns.length)
            let before = ns.substring(to: utf16)
            let line = before.utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            let lineStart = (before as NSString).range(of: "\n", options: .backwards)
            let column = lineStart.location == NSNotFound ? utf16 : utf16 - (lineStart.location + 1)
            return TextPosition(line: line, column: column, utf16Offset: utf16)
        }
        func range(_ selected: NSRange) -> EditorIntelligence.TextRange {
            EditorIntelligence.TextRange(start: position(selected.location), end: position(selected.location + selected.length))
        }
        let caret = position(textView.selectedRange.location)
        let selected = textView.selectedRanges
        return Document(
            id: base.id,
            url: textView.documentURL ?? base.url,
            displayName: base.displayName,
            contentSnapshot: TextSnapshot(version: base.version, text: text),
            selection: Selection(
                range: range(textView.selectedRange),
                additionalRanges: selected.dropFirst().map(range)
            ),
            cursor: Cursor(position: caret),
            viewport: base.viewport,
            languageIdentifier: base.languageIdentifier
        )
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
        guard textView?.languageConfiguration.showsBreadcrumbs ?? true else {
            publishBreadcrumbs([])
            return
        }
        // The adapter's snapshot lags the live buffer; a language provider needs the text and the
        // caret as they are on screen.
        guard let document = (breadcrumbProvider != nil ? liveDocument() : nil) ?? adapter.currentDocument,
              symbolIndex != nil || breadcrumbProvider != nil else {
            publishBreadcrumbs([])
            return
        }
        breadcrumbTask?.cancel()
        breadcrumbTask = Task { [weak self] in
            guard let self else { return }
            var segments = await breadcrumbProvider?.breadcrumbs(for: document)
            if segments == nil, let symbolIndex {
                let symbols = await symbolIndex.symbols(in: document.id)
                let cursorOffset = document.cursor.position.utf16Offset
                // Share BreadcrumbProvider's logic rather than re-deriving it here.
                let locations = BreadcrumbProvider.breadcrumbLocations(from: symbols, cursorOffset: cursorOffset)
                segments = locations.map { BreadcrumbSegment(title: $0.displayName, range: $0.range) }
            }
            guard !Task.isCancelled else { return }
            let result = segments ?? []
            await MainActor.run {
                self.publishBreadcrumbs(result)
            }
        }
    }

    private func publishBreadcrumbs(_ segments: [BreadcrumbSegment]) {
        breadcrumbBarView.update(model: BreadcrumbBarModel(segments: segments))
        onBreadcrumbsUpdated?(segments)
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

    /// The overlay is a *fixed* child of the text view, covering its viewport above the rendered
    /// text. `TextView.addSubview(_:)` would route it into the scrolling document container,
    /// underneath the Metal-rendered text and pinned to the top of the document, which is why
    /// popups used to be invisible anywhere but the first screen of a file.
    private func installOverlayViews(on textView: TextView) {
        overlayContainer.translatesAutoresizingMaskIntoConstraints = true
        overlayContainer.autoresizingMask = [.width, .height]
        overlayContainer.frame = textView.bounds
        overlayContainer.isHidden = true
        textView.addFixedOverlaySubview(overlayContainer)

        for view in [completionPanelView, hoverWindowView, ghostTextView, parameterHintsView, codeActionView, workspaceSearchPanelView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.isHidden = true
            overlayContainer.addSubview(view)
        }
        textView.addScrollObserver { [weak self] in
            guard let self else { return }
            self.suppressResizeDismissal = true
            if textView.isUserInitiatedScroll, self.isCompletionVisible || self.completionAnchor != nil {
                self.dismissCompletion()
            } else {
                self.repositionAnchoredPanels()
            }
            DispatchQueue.main.async { [weak self] in
                self?.suppressResizeDismissal = false
            }
        }
    }

    /// Keeps caret-anchored panels attached to the text while it scrolls (typing near the
    /// bottom edge scrolls the view), and drops the hover, which is tied to the mouse.
    private func repositionAnchoredPanels() {
        guard let textView, !overlayContainer.isHidden else { return }
        if !hoverWindowView.isHidden {
            hideHover()
        }
        if isCompletionVisible, let range = currentReplacementRange {
            positionPanel(completionPanelView, near: range.start.utf16Offset, in: textView, size: completionPanelView.frame.size)
        }
        let caret = textView.selectedRange.location
        if !ghostTextView.isHidden {
            positionGhostText(at: caret, in: textView)
        }
        if !parameterHintsView.isHidden {
            positionPanel(parameterHintsView, near: caret, in: textView, size: parameterHintsView.frame.size, preferAbove: true)
        }
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
        case .cursorMoved, .selectionChanged:
            dismissCompletionIfCaretLeftIdentifier()
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

    /// A document built from the live text view rather than the adapter's snapshot, which lags
    /// edits by up to 200 ms: completion must see the character that was just typed.
    ///
    /// File-backed buffers are not copied into `TextSnapshot.text` (that materializes the whole
    /// file on the main thread). A fresh piece-tree reader is taken instead, so the provider can
    /// read the live source — including the `.` just typed — without using the lagging snapshot.
    private func makeLiveDocument() -> Document? {
        guard let textView, let base = adapter.currentDocument else {
            return adapter.currentDocument
        }
        let caret = textView.selectedRange
        let position = livePosition(at: caret.location, in: textView)
        let endPosition = livePosition(at: caret.upperBound, in: textView)
        liveDocumentVersion += 1
        let version = base.version &+ liveDocumentVersion
        let snapshot: TextSnapshot
        if textView.isFileBacked, let piece = textView.pieceTreeContentSnapshot() {
            let reader = TextRangeReader(utf16Length: piece.utf16Length) { offset, length in
                piece.substring(utf16Offset: offset, length: length)
            }
            snapshot = TextSnapshot(version: version, utf16Length: piece.utf16Length, text: nil, rangeReader: reader)
        } else {
            snapshot = TextSnapshot(version: version, text: textView.text)
        }
        return Document(
            id: base.id,
            url: textView.documentURL ?? base.url,
            displayName: base.displayName,
            contentSnapshot: snapshot,
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: endPosition)),
            cursor: Cursor(position: position),
            viewport: base.viewport,
            languageIdentifier: base.languageIdentifier ?? textView.languageIdentifier
        )
    }

    private func livePosition(at offset: Int, in textView: TextView) -> TextPosition {
        let location = textView.textLocation(at: offset)
        return TextPosition(line: location?.lineNumber ?? 0, column: location?.column ?? offset, utf16Offset: offset)
    }

    private func requestCompletion(trigger: RequestTrigger) {
        guard let document = makeLiveDocument() else {
            completionLog.debug("request skipped: adapter has no current document")
            return
        }
        if !isCompletionVisible {
            completionPainted = false
            completionShownAt = nil
            frozenCompletionKeys = []
            frozenPrefix = nil
        }
        completionGeneration += 1
        let generation = completionGeneration
        pendingCompletionUpdate = nil
        completionHoldTask?.cancel()
        completionHoldTask = nil
        completionIsComputing = true
        let context = makeCompletionContext(
            document: document, trigger: trigger, invocationCount: completionInvocationCount, mode: completionMode
        )
        completionLog.debug("request \(String(describing: trigger), privacy: .public) language=\(document.languageIdentifier ?? "nil", privacy: .public) prefix='\(context.prefix, privacy: .public)' memberAccess=\(context.isMemberAccess)")
        completionTask?.cancel()
        emptyCompletionHintTask?.cancel()
        let started = Date()
        completionTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in await self.completionEngine.completeUpdates(context: context) {
                    let elapsed = Date().timeIntervalSince(started)
                    await MainActor.run {
                        self.ingestCompletion(update, context: context, generation: generation, elapsed: elapsed)
                    }
                }
            } catch {
                // Cancelled by a newer request; that request owns the popup now.
            }
        }
    }

    private func ingestCompletion(_ update: CompletionUpdate, context: CompletionContext, generation: Int, elapsed: TimeInterval) {
        guard generation == completionGeneration else { return }
        guard let textView, let live = liveIdentifierRange(), live.location == context.range.start.utf16Offset,
              textView.selectedRange.length == 0 else {
            return
        }
        if let advertisement = update.advertisement { completionAdvertisement = advertisement }
        if let emptyText = update.emptyText { completionEmptyText = emptyText }
        completionIsComputing = !update.isFinished
        let ready = update.isFinished || completionPainted || isCompletionVisible || elapsed >= 0.3
        if !ready {
            if update.items.isEmpty { return }
            pendingCompletionUpdate = update
            if completionHoldTask == nil {
                completionHoldTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, generation == self.completionGeneration, !self.completionPainted,
                              let pending = self.pendingCompletionUpdate else { return }
                        self.presentCompletion(pending, context: context)
                    }
                }
            }
            return
        }
        completionHoldTask?.cancel()
        completionHoldTask = nil
        presentCompletion(update, context: context)
    }

    private func presentCompletion(_ update: CompletionUpdate, context: CompletionContext) {
        let isManual = context.trigger == .manual
        let items = update.items
        if items.isEmpty {
            guard update.isFinished else { return }
            completionPainted = true
            completionIsComputing = false
            hideCompletionPanel()
            if isManual {
                showEmptyCompletionHint(at: context.range.end, text: update.emptyText ?? completionEmptyText ?? "No suggestions")
            }
            return
        }
        if isManual, items.count == 1, items[0].allowsAutoInsert, !isCompletionVisible,
           !context.prefix.isEmpty || context.isMemberAccess {
            applyCompletion(items[0], replacingIdentifier: false)
            return
        }
        if !isManual, !isCompletionVisible, items.allSatisfy({ $0.kind == .text }) {
            return
        }
        completionPainted = true
        if completionShownAt == nil { completionShownAt = Date() }
        completionWindowFrame = textView?.window?.frame
        unfilteredCompletionItems = items
        completionAnchor = context.range.start.utf16Offset
        refilterCompletion()
    }

    /// Re-filters and re-ranks the session's items for the prefix now in the buffer, keeping the
    /// selected item selected when it survives.
    private func refilterCompletion() {
        guard let textView, let anchor = completionAnchor else {
            hideCompletionPanel()
            return
        }
        let caret = textView.selectedRange.location
        guard caret >= anchor else {
            dismissCompletion()
            return
        }
        let prefix = textView.text(in: NSRange(location: anchor, length: caret - anchor)) ?? ""
        if let frozenPrefix, prefix != frozenPrefix {
            frozenCompletionKeys = []
            self.frozenPrefix = nil
        }
        var ranked: [CompletionItem]
        if let ranker = completionEngine.ranker as? DefaultRanker {
            ranked = ranker.rankSynchronously(items: unfilteredCompletionItems, prefix: prefix).map(\.item)
        } else {
            ranked = unfilteredCompletionItems.filter { CompletionMatcher.matches(prefix, $0.matchText) }
        }
        if !frozenCompletionKeys.isEmpty {
            ranked = freezeCompletion(ranked)
        } else if !ranked.isEmpty {
            frozenCompletionKeys = ranked.map(\.identityKey)
            frozenPrefix = prefix
        }
        guard !ranked.isEmpty else {
            hideCompletionPanel(keepingSession: true)
            return
        }
        let previouslySelected = isCompletionVisible && completionItems.indices.contains(selectedCompletionIndex)
            ? completionItems[selectedCompletionIndex].identityKey : nil
        completionItems = ranked
        if let previouslySelected, isCompletionSelectionExplicit,
           let index = ranked.firstIndex(where: { $0.identityKey == previouslySelected }) {
            selectedCompletionIndex = index
        } else if let index = ranked.firstIndex(where: \.preselect), prefix.isEmpty {
            selectedCompletionIndex = index
        } else {
            selectedCompletionIndex = 0
        }
        let start = livePosition(at: anchor, in: textView)
        let end = livePosition(at: caret, in: textView)
        currentReplacementRange = EditorIntelligence.TextRange(start: start, end: end)
        isCompletionVisible = true
        updateCompletionPanel(prefix: prefix, reposition: true)
    }

    private func updateCompletionPanel(prefix: String? = nil, reposition: Bool = false) {
        guard let textView, let replacementRange = currentReplacementRange else { return }
        let typedPrefix = prefix ?? completionPrefix()
        let model = CompletionPanelModel(
            items: completionItems,
            selectedIndex: selectedCompletionIndex,
            replacementRange: replacementRange,
            prefix: typedPrefix,
            isComputing: completionIsComputing,
            advertisement: completionAdvertisement
        )
        completionPanelView.update(model: model)
        if reposition || completionPanelView.isHidden {
            positionPanel(completionPanelView, near: replacementRange.start.utf16Offset, in: textView, size: CompletionPanelView.preferredSize(for: model))
        }
        completionPanelView.isHidden = false
        overlayContainer.isHidden = false
        updateGhostText(prefix: typedPrefix)
    }

    private func completionPrefix() -> String {
        guard let textView, let anchor = completionAnchor else { return "" }
        let caret = textView.selectedRange.location
        guard caret >= anchor else { return "" }
        return textView.text(in: NSRange(location: anchor, length: caret - anchor)) ?? ""
    }

    private func freezeCompletion(_ ranked: [CompletionItem]) -> [CompletionItem] {
        let byKey = Dictionary(ranked.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var frozen: [CompletionItem] = []
        for key in frozenCompletionKeys {
            if let item = byKey[key] {
                frozen.append(item)
                used.insert(key)
            }
        }
        frozen.append(contentsOf: ranked.filter { !used.contains($0.identityKey) })
        return frozen
    }

    /// Text for the hint shown when a navigation request finds nothing.
    static func noResultText(for kind: NavigationKind, languageIdentifier: String?) -> String {
        switch kind {
        case .definition:
            return "No definition found"
        case .implementation:
            return "No implementations found"
        case .references:
            return languageIdentifier == "java"
                ? "Find Usages isn't available for Java yet"
                : "No usages found"
        }
    }

    /// Shows `text` next to the caret for a moment, in the completion panel's empty state.
    private func showTransientHint(_ text: String) {
        guard let textView, !isCompletionVisible else { return }
        let utf16 = textView.selectedRange.location
        showEmptyCompletionHint(at: TextPosition(line: 0, column: utf16, utf16Offset: utf16), text: text)
    }

    private func showEmptyCompletionHint(at position: TextPosition, text: String = "No suggestions") {
        guard let textView else { return }
        let model = CompletionPanelModel(items: [], replacementRange: EditorIntelligence.TextRange(start: position, end: position), emptyText: text)
        completionPanelView.update(model: model)
        positionPanel(completionPanelView, near: position.utf16Offset, in: textView, size: CompletionPanelView.preferredSize(for: model))
        completionPanelView.isHidden = false
        overlayContainer.isHidden = false
        emptyCompletionHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isCompletionVisible else { return }
                self.completionPanelView.isHidden = true
                self.updateOverlayVisibility()
            }
        }
    }

    private func hideCompletionPanel(keepingSession: Bool = false) {
        isCompletionVisible = false
        completionItems = []
        selectedCompletionIndex = 0
        currentReplacementRange = nil
        if !keepingSession {
            unfilteredCompletionItems = []
            completionAnchor = nil
            isCompletionSelectionExplicit = false
            completionInvocationCount = 1
            completionMode = .basic
            completionShownAt = nil
            completionPainted = false
            frozenCompletionKeys = []
            frozenPrefix = nil
            completionIsComputing = false
            completionAdvertisement = nil
            completionEmptyText = nil
            completionHoldTask?.cancel()
            completionHoldTask = nil
        }
        completionPanelView.isHidden = true
        hideGhostText()
        updateOverlayVisibility()
    }

    /// The identifier run around the caret: from its start up to the caret (`location`/`length`
    /// cover only the part before the caret), or `nil` without a single caret.
    private func liveIdentifierRange() -> NSRange? {
        guard let textView else { return nil }
        let caret = textView.selectedRange
        guard caret.length == 0 else { return nil }
        let windowStart = max(0, caret.location - 256)
        let before = (textView.text(in: NSRange(location: windowStart, length: caret.location - windowStart)) ?? "") as NSString
        var start = before.length
        while start > 0, let scalar = UnicodeScalar(before.character(at: start - 1)), isCompletionIdentifierScalar(scalar) {
            start -= 1
        }
        return NSRange(location: windowStart + start, length: before.length - start)
    }

    /// Length of the identifier characters right after the caret (replaced by Tab).
    private func identifierSuffixLength(after offset: Int) -> Int {
        guard let textView else { return 0 }
        let after = (textView.text(in: NSRange(location: offset, length: min(256, max(0, textView.documentLength - offset)))) ?? "") as NSString
        var length = 0
        while length < after.length, let scalar = UnicodeScalar(after.character(at: length)), isCompletionIdentifierScalar(scalar) {
            length += 1
        }
        return length
    }

    private func dismissCompletionIfCaretLeftIdentifier() {
        guard isCompletionVisible || completionAnchor != nil, let textView, let anchor = completionAnchor else { return }
        let caret = textView.selectedRange
        guard caret.length == 0, caret.location >= anchor, let live = liveIdentifierRange(), live.location == anchor else {
            dismissCompletion()
            return
        }
    }

    private func applyCompletion(_ item: CompletionItem, replacingIdentifier: Bool) {
        guard let textView else {
            return
        }
        completionEngine.recordAcceptance(of: item)
        let caret = textView.selectedRange.location
        let anchor = liveIdentifierRange()?.location ?? caret
        var length = caret - anchor
        if replacingIdentifier {
            length += identifierSuffixLength(after: caret)
        }
        let nsRange = NSRange(location: anchor, length: max(0, length))
        if item.isSnippet {
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
                let relativeStartOffset = nsRange.location - caret
                textView.replaceAtAllSelections(
                    relativeStartOffset: relativeStartOffset,
                    length: nsRange.length,
                    with: expansion.text
                )
            } else {
                textView.insertSnippet(expansion, replacing: nsRange)
            }
            applyAdditionalEdits(item.additionalEdits, in: textView)
            return
        }

        var insertText = item.insertText
        var caretOffset = item.caretOffset
        // `foo|(x)`: don't add a second pair of parentheses; step into the existing one.
        let nextCharacter = textView.text(in: NSRange(location: nsRange.upperBound, length: min(1, max(0, textView.documentLength - nsRange.upperBound))))
        if insertText.hasSuffix("()"), nextCharacter == "(" {
            insertText.removeLast(2)
            caretOffset = (insertText as NSString).length + 1
        }

        textView.undoManager?.beginUndoGrouping()
        if textView.isMultiCursorActive {
            // Apply the same relative edit -- "replace these N characters around the primary
            // caret" -- at every caret, not just the primary one.
            let relativeStartOffset = nsRange.location - caret
            textView.replaceAtAllSelections(relativeStartOffset: relativeStartOffset, length: nsRange.length, with: insertText)
        } else {
            textView.replace(nsRange, withText: insertText)
            if let caretOffset {
                textView.selectedRange = NSRange(location: nsRange.location + caretOffset, length: 0)
            }
        }
        applyAdditionalEdits(item.additionalEdits, in: textView)
        textView.undoManager?.endUndoGrouping()

        if item.triggersSignatureHelp {
            requestSignatureHelp()
        }
    }

    private func applyAdditionalEdits(_ edits: [EditorIntelligence.TextEdit], in textView: TextView) {
        guard !edits.isEmpty else { return }
        TextEditApplicator.apply(edits, in: textView)
    }

    private func moveCompletionSelection(delta: Int, wrapping: Bool = true) {
        guard isCompletionVisible, !completionItems.isEmpty else {
            return
        }
        isCompletionSelectionExplicit = true
        let count = completionItems.count
        if wrapping {
            selectedCompletionIndex = (selectedCompletionIndex + delta % count + count) % count
        } else {
            selectedCompletionIndex = max(0, min(count - 1, selectedCompletionIndex + delta))
        }
        updateCompletionPanel()
    }

    /// A click on a completion row moves the selection there (mirrors arrow-key navigation)
    /// without accepting it, matching how a hover/click-to-highlight list normally behaves.
    private func selectCompletionRow(_ index: Int) {
        guard isCompletionVisible, completionItems.indices.contains(index) else { return }
        isCompletionSelectionExplicit = true
        selectedCompletionIndex = index
        updateCompletionPanel()
    }

    /// A double-click on a completion row accepts that item directly, regardless of which row is
    /// currently selected.
    private func acceptCompletionRow(_ index: Int) {
        guard isCompletionVisible, completionItems.indices.contains(index) else { return }
        selectedCompletionIndex = index
        acceptSelectedCompletion()
    }

    // MARK: - Hover

    private func scheduleHoverRequest() {
        // A popup left over from the previous position would sit over the wrong symbol.
        if !hoverWindowView.isHidden { hideHover() }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.requestHover(trigger: .idle)
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
        positionPanel(
            hoverWindowView,
            near: anchorRange.start.utf16Offset,
            in: textView,
            size: HoverWindowView.preferredSize(for: model)
        )
        hoverWindowView.isHidden = false
        overlayContainer.isHidden = false
    }

    private func hideHover() {
        hoverWindowView.isHidden = true
        updateOverlayVisibility()
    }

    // MARK: - Ghost Text

    /// Previews the rest of the selected item after the caret, when it extends what was typed.
    private func updateGhostText(prefix: String) {
        guard let item = selectedCompletionItem, !item.isSnippet, let textView,
              item.insertText.hasPrefix(prefix), item.insertText.count > prefix.count else {
            hideGhostText()
            return
        }
        let suffix = String(item.insertText.dropFirst(prefix.count))
        showGhostText(suffix, at: livePosition(at: textView.selectedRange.location, in: textView))
    }

    private func showGhostText(_ text: String, at position: TextPosition) {
        guard let textView else {
            return
        }
        let model = GhostTextModel(text: text, anchorPosition: position)
        ghostTextModel = model
        ghostTextView.update(model: model)
        positionGhostText(at: position.utf16Offset, in: textView)
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
        guard let textView else {
            return
        }
        parameterHintsView.update(model: model)
        // Above the caret, like IntelliJ's parameter info, so it doesn't cover the completion list.
        positionPanel(
            parameterHintsView,
            near: textView.selectedRange.location,
            in: textView,
            size: NSSize(width: 360, height: 28),
            preferAbove: true
        )
        parameterHintsView.isHidden = false
        overlayContainer.isHidden = false
    }

    public func hideParameterHints() {
        parameterHintsView.isHidden = true
        updateOverlayVisibility()
    }

    private func requestSignatureHelp() {
        guard let signatureHelpProvider, let document = makeLiveDocument() else {
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
        codeActionView.selectRow(0)
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
            hideParameterHints()
            if isCompletionVisible {
                dismissCompletion()
                return true
            }
        }

        if !codeActionView.isHidden, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            switch event.keyCode {
            case 0x7D:
                codeActionView.moveSelection(by: 1)
                return true
            case 0x7E:
                codeActionView.moveSelection(by: -1)
                return true
            case 0x24, 0x4C:
                if let action = codeActionView.selectedAction {
                    applyCodeAction(action)
                }
                return true
            default:
                break
            }
        }

        guard isCompletionVisible else {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch event.keyCode {
        case 0x7D where modifiers.isEmpty:
            moveCompletionSelection(delta: 1)
            return true
        case 0x7E where modifiers.isEmpty:
            moveCompletionSelection(delta: -1)
            return true
        case 0x79 where modifiers.isEmpty: // Page Down
            moveCompletionSelection(delta: CompletionPanelView.maxVisibleRows - 1, wrapping: false)
            return true
        case 0x74 where modifiers.isEmpty: // Page Up
            moveCompletionSelection(delta: -(CompletionPanelView.maxVisibleRows - 1), wrapping: false)
            return true
        case 0x24, 0x4C:
            acceptSelectedCompletion(replacingIdentifier: false)
            return true
        case 0x30 where !modifiers.contains(.shift): // Tab
            acceptSelectedCompletion(replacingIdentifier: true)
            return true
        default:
            break
        }
        guard modifiers.subtracting(.shift).isEmpty, let characters = event.characters, characters.count == 1 else {
            return false
        }
        return handleCompletionCommitCharacter(characters)
    }

    /// `.`, `(` and `;` commit the selected item, IntelliJ style, when the user chose it (manual
    /// invocation or arrow keys) or it is exactly what was typed. Returns `true` when the
    /// character itself was consumed (`(` on a method that already got its parentheses).
    private func handleCompletionCommitCharacter(_ character: String) -> Bool {
        guard [".", "(", ";"].contains(character), let item = selectedCompletionItem else {
            return false
        }
        let prefix = completionPrefix()
        guard isCompletionSelectionExplicit || item.label == prefix else {
            return false
        }
        let insertsParentheses = !item.isSnippet && item.insertText.hasSuffix("()")
        acceptSelectedCompletion(replacingIdentifier: false)
        if character == "(" && insertsParentheses {
            return true
        }
        if character == "." || character == ";", insertsParentheses, item.caretOffset != nil, let textView {
            // A method with parameters left the caret inside `(|)`; `.`/`;` belong after it.
            textView.selectedRange = NSRange(location: textView.selectedRange.location + 1, length: 0)
            hideParameterHints()
        }
        return false
    }

    private func handleTypingEvent(_ event: TextViewTypingEvent) {
        switch event {
        case .inserted(let text):
            handleTextInsertion(text)
        case .deletedBackward:
            guard let textView, let anchor = completionAnchor else { return }
            let caret = textView.selectedRange.location
            guard caret >= anchor, let live = liveIdentifierRange(), live.location == anchor else {
                // Deleted past the start of the completed identifier.
                dismissCompletion()
                return
            }
            let afterTriggerCharacter = anchor > 0 && [".", "@", ":"].contains(textView.text(in: NSRange(location: anchor - 1, length: 1)) ?? "")
            if live.length == 0, !afterTriggerCharacter, !isCompletionSelectionExplicit {
                dismissCompletion()
                return
            }
            refilterCompletion()
            requestCompletion(trigger: .idle)
        }
    }

    private func isIdentifierText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy(isCompletionIdentifierScalar)
    }

    /// Characters that open the popup on their own: member access and annotations.
    private func isCompletionTriggerCharacter(_ text: String) -> Bool {
        if text == "." || text == "@" {
            return true
        }
        if text == ":", let textView {
            let location = textView.selectedRange.location
            return location >= 2 && textView.text(in: NSRange(location: location - 2, length: 1)) == ":"
        }
        return false
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

        if isIdentifierText(text) {
            guard let live = liveIdentifierRange() else { return }
            if completionAnchor != nil, live.location == completionAnchor {
                refilterCompletion()
                requestCompletion(trigger: .keystroke(text))
                return
            }
            // A new identifier: auto-popup unless it's a number literal.
            if isCompletionVisible || completionAnchor != nil {
                hideCompletionPanel()
            }
            if let first = textView?.text(in: NSRange(location: live.location, length: 1))?.unicodeScalars.first,
               CharacterSet.decimalDigits.contains(first) {
                return
            }
            completionMode = .basic
            completionInvocationCount = 0
            isCompletionSelectionExplicit = false
            requestCompletion(trigger: .keystroke(text))
        } else if isCompletionTriggerCharacter(text) {
            hideCompletionPanel()
            completionMode = .basic
            completionInvocationCount = 0
            isCompletionSelectionExplicit = false
            requestCompletion(trigger: .keystroke(text))
        } else if isCompletionVisible || completionAnchor != nil {
            dismissCompletion()
        }
    }

    // MARK: - Layout Helpers

    /// Places `panel` just below the caret at `location` (or above it when `preferAbove`, or when
    /// there's no room below), clamped inside the visible text area, and brings the overlay to
    /// the front of the text view's fixed overlays.
    private func positionPanel(
        _ panel: NSView, near location: Int, in textView: TextView, size: NSSize = NSSize(width: 240, height: 120), preferAbove: Bool = false
    ) {
        overlayContainer.frame = textView.bounds
        textView.bringFixedOverlaySubviewToFront(overlayContainer)
        let caret = overlayContainer.convert(textView.caretRectInViewport(at: location), from: textView)
        let bounds = overlayContainer.bounds
        let below = caret.maxY + 2
        let above = caret.minY - 2 - size.height
        var y = preferAbove ? above : below
        if preferAbove, y < bounds.minY {
            y = below
        } else if !preferAbove, below + size.height > bounds.maxY, above >= bounds.minY {
            y = above
        }
        let x = min(max(bounds.minX + 2, caret.minX), max(bounds.minX + 2, bounds.maxX - size.width - 2))
        panel.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Ghost text sits on the caret's own line, right after it.
    private func positionGhostText(at location: Int, in textView: TextView) {
        overlayContainer.frame = textView.bounds
        textView.bringFixedOverlaySubviewToFront(overlayContainer)
        let caret = overlayContainer.convert(textView.caretRectInViewport(at: location), from: textView)
        ghostTextView.frame = CGRect(x: caret.maxX, y: caret.minY, width: 300, height: max(16, caret.height))
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
        if let workbench = adapter as? PenumbraWorkbenchEditorAdapter {
            return workbench.textView === textView
        }
        if let penumbra = adapter as? PenumbraEditorAdapter {
            return penumbra.textView === textView
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
        // Completion and signature help react to typing through `TextView.addTypingObserver`,
        // which also sees auto-paired characters and works without this delegate.
        userDelegate?.textView(textView, shouldChangeTextIn: range, replacementText: text) ?? true
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

/// Flipped, click-through container for the intelligence popups: it covers the text view's
/// viewport, but only its visible panels receive mouse events.
@MainActor
final class IntelligenceOverlayView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
