import func EditorIntelligence.runDetached
import AppKit
import Penumbra
import SwiftUI

// MARK: - Pane host

@MainActor
final class IDEEditorPaneHost: NSView {
    let pane: EditorPane
    let textView: TextView
    let markdownPreviewController: MarkdownPreviewController
    let imageViewerController: ImageViewerController
    /// Laid over the editor while a diff tab is selected.
    let diffViewer = IDEDiffViewerView()
    /// Laid over the editor while a class or dependency diagram tab is selected, and while a JSON
    /// file's diagram preview is showing.
    let diagramViewer = IDEDiagramViewerView()
    /// Laid over the editor while a Java Flight Recorder profile tab is selected.
    let profileViewer = IDEProfilerViewerView()
    /// Laid over the editor while a heap dump tab is selected.
    let heapDumpViewer = IDEHeapDumpViewerView()
    /// True while this pane's JSON file is covered by its diagram.
    private(set) var isJSONDiagramVisible = false
    private var jsonDiagramSession: IDEDiagramSession?
    private let jsonRefresh = Debouncer()
    private var editorWasSelectableBeforeJSONDiagram = true
    /// Laid over the editor while a CSV or TSV file's table preview is showing.
    let csvTableView = IDECSVTableView()
    /// Laid over the editor while a hex tab is selected.
    let hexViewer = IDEHexViewerView()
    /// True while this pane's CSV/TSV file is covered by its table.
    private(set) var isCSVTableVisible = false
    private let csvRefresh = Debouncer()
    private var csvParseTask: Task<Void, Never>?
    private var editorWasSelectableBeforeCSVTable = true
    let applyGate = PenumbraStateBuilder.GenerationGate()
    var intelligenceController: EditorIntelligenceController?
    var loadedDocumentID: UUID?
    /// `WorkbenchDocument.contentGeneration` as of the last `setState`/reload into this host —
    /// lets two panes sharing one document (from a split) tell a same-document refresh (this
    /// pane's own edits reapplied) apart from picking up an edit made in the *other* pane.
    var loadedGeneration: UInt64 = 0
    /// `TextView.contentGeneration` as of the last load/sync. Compared on the next sync so a
    /// file-backed document (whose `text` is empty by design) is only treated as edited when
    /// the live buffer actually changed — not on every tab switch or ⌘N.
    var loadedBufferGeneration: UInt64 = 0
    /// This pane's own scroll/selection, captured just before a reload triggered by the shared
    /// document changing underneath it. Preferred over `document.selectedRange`/`scrollOffset`
    /// on that reload so one pane's edits don't yank the other pane's viewport around.
    var lastSelectedRange: NSRange?
    var lastScrollOffset: CGPoint?
    /// A navigation target for a document whose text is still loading: once it is applied, the
    /// range is selected and centered instead of restoring the document's last scroll position.
    var pendingReveal: (documentID: UUID, range: NSRange)?
    var onActivated: (() -> Void)?
    /// The table was closed from inside (a row double-click), not by the play button.
    var onCSVTableClosed: (() -> Void)?

    init(pane: EditorPane, preferences: IDEPreferences) {
        self.pane = pane
        textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.theme = IDEEditorTheme.shared.current
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.keymap = preferences.keymap
        markdownPreviewController = MarkdownPreviewController(textView: textView)
        imageViewerController = ImageViewerController()
        imageViewerController.coveredEditor = textView
        imageViewerController.viewerBackgroundColor = IDEAppearance.NSToken.editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        preferences.apply(to: textView)

        markdownPreviewController.embed(editorView: textView)
        imageViewerController.embed(contentView: markdownPreviewController.containerView)
        let container = imageViewerController.containerView
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        diffViewer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffViewer)
        NSLayoutConstraint.activate([
            diffViewer.topAnchor.constraint(equalTo: topAnchor),
            diffViewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffViewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffViewer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        diagramViewer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diagramViewer)
        NSLayoutConstraint.activate([
            diagramViewer.topAnchor.constraint(equalTo: topAnchor),
            diagramViewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            diagramViewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            diagramViewer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        profileViewer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(profileViewer)
        NSLayoutConstraint.activate([
            profileViewer.topAnchor.constraint(equalTo: topAnchor),
            profileViewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            profileViewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            profileViewer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        heapDumpViewer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heapDumpViewer)
        NSLayoutConstraint.activate([
            heapDumpViewer.topAnchor.constraint(equalTo: topAnchor),
            heapDumpViewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            heapDumpViewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            heapDumpViewer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        csvTableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(csvTableView)
        NSLayoutConstraint.activate([
            csvTableView.topAnchor.constraint(equalTo: topAnchor),
            csvTableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            csvTableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            csvTableView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        csvTableView.onRevealLine = { [weak self] line in self?.revealCSVSourceLine(line) }

        hexViewer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hexViewer)
        NSLayoutConstraint.activate([
            hexViewer.topAnchor.constraint(equalTo: topAnchor),
            hexViewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            hexViewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            hexViewer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    func wireMarkdownPreview(onToggle: @escaping () -> Void) {
        markdownPreviewController.installMetalFailureHandler(chaining: textView.onMetalRenderingFailure)
        markdownPreviewController.installTextObservation(chaining: textView.editorDelegate)
        markdownPreviewController.codeBlockLanguageResolver = { IDELanguageSupport.language(forIdentifier: $0) }

        let previousHandler = textView.editorActionHandler
        textView.editorActionHandler = { [weak self] action in
            guard let self else { return previousHandler?(action) ?? false }
            if action == .toggleMarkdownPreview {
                let handled: Bool
                switch self.textView.languageIdentifier {
                case "json": handled = self.toggleJSONDiagram()
                case "csv", "tsv": handled = self.toggleCSVTable()
                default: handled = self.markdownPreviewController.toggle()
                }
                if handled { onToggle() }
                return handled
            }
            return previousHandler?(action) ?? false
        }
    }

    /// Covers the editor with a diagram of the JSON buffer, or returns to the source.
    /// Returns `false` when the buffer is not JSON.
    @discardableResult
    func toggleJSONDiagram() -> Bool {
        guard textView.languageIdentifier == "json" else { return false }
        if isJSONDiagramVisible {
            hideJSONDiagram()
        } else {
            editorWasSelectableBeforeJSONDiagram = textView.isSelectable
            textView.isSelectable = false
            isJSONDiagramVisible = true
            refreshJSONDiagram()
        }
        return true
    }

    /// Hides the diagram when this pane is no longer showing JSON. A JSON file keeps whatever
    /// the play button last did.
    func closeJSONDiagramIfNotJSON() {
        guard textView.languageIdentifier != "json" else { return }
        hideJSONDiagram()
    }

    /// Drops the diagram. `hidingViewer` is false when another overlay is about to take the same
    /// view, so it is not hidden and shown again in one turn.
    func hideJSONDiagram(hidingViewer: Bool = true) {
        jsonRefresh.cancel()
        guard isJSONDiagramVisible else { return }
        isJSONDiagramVisible = false
        textView.isSelectable = editorWasSelectableBeforeJSONDiagram
        jsonDiagramSession?.cancel()
        if hidingViewer { diagramViewer.hide() }
    }

    /// Rebuilds the diagram from the live buffer. A first show lets the viewer start the load;
    /// later shows reload, because the viewer only loads an empty session.
    func refreshJSONDiagram() {
        jsonRefresh.cancel()
        guard isJSONDiagramVisible, textView.languageIdentifier == "json" else { return }
        let session = ensureJSONSession()
        session.loadJSONText = { [weak self] in self?.textView.text ?? "" }
        let firstShow = session.loadedAt == nil && session.state == .loading && session.document.nodes.isEmpty
        diagramViewer.show(session)
        if !firstShow { session.reload() }
    }

    /// Puts the diagram back on top without reading the buffer again.
    func revealJSONDiagramIfVisible() {
        guard isJSONDiagramVisible, let jsonDiagramSession else { return }
        diagramViewer.show(jsonDiagramSession)
    }

    /// Schedules a rebuild. The buffer is read once the pause has elapsed, not on the keystroke.
    func noteJSONDiagramEdited() {
        guard isJSONDiagramVisible, textView.languageIdentifier == "json" else { return }
        jsonRefresh.schedule(after: .milliseconds(200)) { [weak self] in
            self?.refreshJSONDiagram()
        }
    }

    private func ensureJSONSession() -> IDEDiagramSession {
        let title = jsonDiagramTitle()
        if let jsonDiagramSession {
            jsonDiagramSession.setJSONPreviewTitle(title)
            return jsonDiagramSession
        }
        let session = IDEDiagramSession(request: .jsonPreview(title: title))
        jsonDiagramSession = session
        return session
    }

    private func jsonDiagramTitle() -> String {
        if let url = textView.documentURL {
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return "JSON"
    }

    // MARK: - CSV table

    static func isCSV(_ identifier: String?) -> Bool {
        identifier == "csv" || identifier == "tsv"
    }

    /// Covers the editor with a table of the CSV/TSV buffer, or returns to the source.
    /// Returns `false` when the buffer is not CSV or TSV.
    @discardableResult
    func toggleCSVTable() -> Bool {
        guard Self.isCSV(textView.languageIdentifier) else { return false }
        if isCSVTableVisible {
            hideCSVTable()
        } else {
            editorWasSelectableBeforeCSVTable = textView.isSelectable
            textView.isSelectable = false
            isCSVTableVisible = true
            csvTableView.show()
            refreshCSVTable()
        }
        return true
    }

    /// Hides the table when this pane is no longer showing CSV or TSV.
    func closeCSVTableIfNotCSV() {
        guard !Self.isCSV(textView.languageIdentifier) else { return }
        hideCSVTable()
    }

    func hideCSVTable() {
        csvRefresh.cancel()
        csvParseTask?.cancel()
        csvParseTask = nil
        guard isCSVTableVisible else { return }
        isCSVTableVisible = false
        textView.isSelectable = editorWasSelectableBeforeCSVTable
        csvTableView.hide()
    }

    /// Re-parses the live buffer. The text is read here and parsed off the main actor; a result
    /// that a newer refresh has overtaken is dropped.
    func refreshCSVTable() {
        csvRefresh.cancel()
        csvParseTask?.cancel()
        guard isCSVTableVisible, Self.isCSV(textView.languageIdentifier) else { return }
        let text = textView.text
        let identifier = textView.languageIdentifier
        csvParseTask = Task { [weak self] in
            let table = await runDetached(priority: .userInitiated) {
                let sample = String(text.prefix(4096))
                let delimiter = IDECSVTable.delimiter(forIdentifier: identifier, sample: sample)
                return IDECSVTable.parse(text, delimiter: delimiter)
            }
            guard !Task.isCancelled else { return }
            self?.csvTableView.update(table)
        }
    }

    /// Puts the table back on top without reading the buffer again.
    func revealCSVTableIfVisible() {
        guard isCSVTableVisible else { return }
        csvTableView.show()
    }

    /// Schedules a re-parse. The buffer is read once the pause has elapsed, not on the keystroke.
    func noteCSVTableEdited() {
        guard isCSVTableVisible, Self.isCSV(textView.languageIdentifier) else { return }
        csvRefresh.schedule(after: .milliseconds(200)) { [weak self] in
            self?.refreshCSVTable()
        }
    }

    /// Double-click on a table row: back to the source, with the caret on that row's line.
    private func revealCSVSourceLine(_ line: Int) {
        hideCSVTable()
        textView.goToLine(line)
        onCSVTableClosed?()
    }

    /// Routes F2 / ⇧F2 (next / previous problem) to the workspace, which owns the problem list.
    func wireProblemNavigation(_ go: @escaping (_ forward: Bool) -> Void) {
        let previousHandler = textView.editorActionHandler
        textView.editorActionHandler = { action in
            switch action {
            case .goToNextProblem:
                go(true)
                return true
            case .goToPreviousProblem:
                go(false)
                return true
            default:
                return previousHandler?(action) ?? false
            }
        }
    }

    /// Routes Select In… (⌥F1) to the workspace, which owns the Explorer, Finder and terminals.
    func wireSelectIn(_ show: @escaping () -> Void) {
        let previousHandler = textView.editorActionHandler
        textView.editorActionHandler = { action in
            if action == .selectIn {
                show()
                return true
            }
            return previousHandler?(action) ?? false
        }
    }

    func wireHTTPActions(sendRequest: @escaping () -> Void) {
        let previousHandler = textView.editorActionHandler
        textView.editorActionHandler = { action in
            if action.rawValue == "sendHTTPRequest" {
                sendRequest()
                return true
            }
            return previousHandler?(action) ?? false
        }
    }

    @objc private func paneClicked() {
        onActivated?()
    }
}

// MARK: - Representable

struct IDETextViewRepresentable: NSViewRepresentable {
    let paneID: UUID
    let workspace: IDEWorkspace

    func makeNSView(context: Context) -> EditorHostContainer {
        let container = EditorHostContainer()
        container.mount(workspace.host(for: paneID))
        return container
    }

    func updateNSView(_ container: EditorHostContainer, context: Context) {
        let host = workspace.host(for: paneID)
        container.mount(host)
        // An image tab's editor stays out of the key-view loop while its viewer covers it (the
        // viewer controller restores the flag when the image hides). Without this guard every
        // representable update would re-enable Tab-into-the-hidden-editor behind the image.
        let isImage = workspace.workbench.layout.findPane(id: paneID)?.selectedDocument?.contentKind == .image
        host.textView.participatesInKeyViewLoop = !workspace.isEditorCoveredByOverlay && !isImage
    }
}

// MARK: - Layout

struct IDEEditorLayoutNode: View {
    let layout: EditorLayout
    /// `IDEWorkspace.layoutEpoch`. The layout is a tree of classes edited in place, so a node
    /// handed the same objects looks unchanged to SwiftUI; the epoch is what says it changed.
    /// Passing it down, rather than giving the whole tree a new identity per change, is what lets
    /// panes that stay keep their views and the ones that come and go be animated.
    var epoch: UInt64 = 0
    /// The edge a pane in this node grows from when it opens and shrinks to when it
    /// closes: away from the other side of its split. `nil` for the only pane.
    var growthEdge: Edge? = nil
    /// The top of the editor area. A lone pane there is drawn as a chain of one, so it keeps its
    /// view when a second one opens beside it, which is what turns it into a chain of two.
    var isRoot = false

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDEEditorLayoutNode")
        // `.horizontal` means children sit left/right (see `EditorSplitData.split`), i.e. an
        // HStack. Switch on `data.axis` rather than the enum case so a case/axis mismatch
        // (the two are always constructed together, but round-trip independently through
        // `EditorRestorationState`) can't silently invert the split again.
        //
        // One call site for every container, so the view is the same whichever way the layout
        // is shaped: a pane split sideways and then downward keeps being a chain of panes.
        if let (axis, children) = chain {
            IDEEditorSplitChain(axis: axis, children: children, epoch: epoch)
        } else if case .pane(let pane) = layout {
            IDEEditorPaneView(paneID: pane.id, growthEdge: growthEdge)
                .id(pane.id)
        }
    }

    private var chain: (SplitLayout, [EditorLayout])? {
        switch layout {
        case .pane:
            return isRoot ? (.horizontal, [layout]) : nil
        case .horizontal(let data), .vertical(let data):
            return (data.axis == .horizontal ? .horizontal : .vertical, data.children)
        }
    }
}

/// Reveals a pane from `edge` as `presence` runs 0 → 1 on open and hides it back toward the edge
/// on close (Silica's `PanePlacement`).
///
/// A clip, not a frame: the pane keeps the size its split gives it, so its text view does not
/// reflow on every frame of the animation. The modifier must never take part in layout. An earlier
/// version measured the allocation with a `GeometryReader` and re-framed the pane; inside a
/// transition modifier that reader was proposed the whole editor area instead of the pane's share,
/// so every split drew its panes a quarter of the window too far right.
private struct PanePresence: ViewModifier, Animatable {
    let edge: Edge?
    var presence: CGFloat

    nonisolated var animatableData: CGFloat {
        get { presence }
        set { presence = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let edge {
            content.clipShape(PaneReveal(edge: edge, presence: presence))
        } else {
            content
        }
    }
}

/// The part of a rectangle that is showing: `presence` of it, anchored at `edge`.
private struct PaneReveal: Shape {
    let edge: Edge
    var presence: CGFloat

    nonisolated var animatableData: CGFloat {
        get { presence }
        set { presence = newValue }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let share = min(max(presence, 0), 1)
        var visible = rect
        switch edge {
        case .leading:
            visible.size.width = rect.width * share
        case .trailing:
            visible.origin.x = rect.maxX - rect.width * share
            visible.size.width = rect.width * share
        case .top:
            visible.size.height = rect.height * share
        case .bottom:
            visible.origin.y = rect.maxY - rect.height * share
            visible.size.height = rect.height * share
        }
        return Path(visible)
    }
}

struct IDEEditorPaneView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID
    var growthEdge: Edge? = nil

    var body: some View {
        VStack(spacing: 0) {
            IDEEditorTabsBar(paneID: paneID)
                .opacity(workspace.chromeOpacity)

            IDELargeFileBanner(paneID: paneID)

            IDEExternalChangeBanner(paneID: paneID)
            IDEGitConflictBanner(paneID: paneID)
            IDEMissingLanguageServerBanner(paneID: paneID)

            if let document = workspace.selectedTabDocument(in: paneID),
               document.contentKind == .image,
               !workspace.isPhotoEditing(document.id) {
                IDEImageViewerToolbar(paneID: paneID)
            }

            if let document = workspace.workbench.layout.findPane(id: paneID)?.selectedDocument,
               document.contentKind == .text,
               workspace.databaseSupport.consoles[document.id] != nil
                   || (document.languageIdentifier == "sql" && !workspace.databaseSupport.catalog.connections.isEmpty) {
                IDEDatabaseConsoleHeader(document: document, support: workspace.databaseSupport) {
                    workspace.refreshDatabaseConsoleBinding(in: paneID)
                }
            }

            IDETextViewRepresentable(paneID: paneID, workspace: workspace)
                .overlay(alignment: .topTrailing) { IDEInspectionWidget(paneID: paneID) }
                .overlay {
                    if let document = workspace.selectedTabDocument(in: paneID),
                       document.contentKind == .image,
                       workspace.isPhotoEditing(document.id) {
                        IDEPhotoEditorView(document: document)
                    }
                }
                .overlay {
                    if workspace.activePaneID != paneID {
                        Rectangle()
                            .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IDEEditorTabsBar.panesSpace)) } action: {
            workspace.editorPaneFrames[paneID] = $0
        }
        // Where a tab being dragged would land: the new pane beside it, or the pane as a whole. Into
        // its bar the tabs show it themselves, by opening a gap.
        .overlay {
            if let target = workspace.tabDrag.target, target.paneID == paneID, target.edge != nil || target.index == nil {
                IDETabDropHighlight(edge: target.edge)
            }
        }
        .transition(.modifier(
            active: PanePresence(edge: growthEdge, presence: 0),
            identity: PanePresence(edge: growthEdge, presence: 1)
        ))
    }
}

/// The area a dragged tab would take: the half of the pane on an edge, or all of it for its tabs.
private struct IDETabDropHighlight: View {
    let edge: EditorSplitEdge?

    var body: some View {
        GeometryReader { proxy in
            let area = IDEEditorTabDrop.highlight(
                for: edge,
                in: CGRect(origin: .zero, size: proxy.size),
                tabBarHeight: IDEAppearance.Spacing.tabHeight
            )
            Rectangle()
                .fill(IDEAppearance.ColorToken.accent.opacity(0.14))
                .overlay { Rectangle().strokeBorder(IDEAppearance.ColorToken.accent.opacity(0.5), lineWidth: 1) }
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .ideAnimation(IDEAppearance.Motion.quick, value: edge)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Splitter

/// One split container's children, laid out as a chain of two-pane `SplitPanes`: the first child
/// against a chain of the rest. `SplitPanes` only splits in two, and `EditorSplitData` holds any
/// number of children (splitting a pane inserts its sibling beside it).
///
/// Each link opens at `1 / remaining`, so every pane starts with an equal share, and re-spreads
/// evenly when a pane is added or closed (`SplitPanes` follows a changing `defaultFraction`).
/// Dragging a divider moves one pane against all the panes after it, not just its neighbour.
///
/// The last pane is a link too, with nothing on its second side (`hiddenSide`). A pane is therefore
/// always the first side of the link at its place in the chain, and opening a sibling after it only
/// shows that link's second side: the pane keeps its view and its share is animated, where
/// switching a bare pane for a split would build it again beside the new one. A pane inserted or
/// closed before another takes that one's place (see `IDEEditorLayoutPaths`).
struct IDEEditorSplitChain: View {
    let axis: SplitLayout
    let children: [EditorLayout]
    var start = 0
    var epoch: UInt64 = 0
    /// Growth edge of the first child; later children are the second side of
    /// their link and grow from the opposite edge. Computed from `axis` when nil.
    var firstGrowthEdge: Edge? = nil

    private var firstEdge: Edge {
        firstGrowthEdge ?? (axis == .horizontal ? .leading : .top)
    }
    private var restEdge: Edge { axis == .horizontal ? .trailing : .bottom }

    var body: some View {
        let remaining = children.count - start
        Group {
            if remaining <= 0 {
                Color.clear
            } else {
                SplitPanes(
                    axis: axis,
                    minPrimary: IDEAppearance.Spacing.editorPaneMinLength,
                    minSecondary: IDEAppearance.Spacing.editorPaneMinLength * CGFloat(remaining - 1),
                    // The share a second pane gets when it opens: a lone link is hidden at the
                    // moment, and its fraction is what it opens at.
                    defaultFraction: remaining > 1 ? 1 / CGFloat(remaining) : 0.5,
                    // Panes scale together with the window rather than one keeping its size.
                    priority: nil,
                    hiddenSide: remaining == 1 ? .secondary : nil,
                    animatesFraction: true,
                    dividerResetsOnDoubleClick: true
                ) {
                    IDEEditorLayoutNode(layout: children[start], epoch: epoch, growthEdge: firstEdge)
                } secondary: {
                    IDEEditorSplitChain(axis: axis, children: children, start: start + 1, epoch: epoch, firstGrowthEdge: restEdge)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Split Panes") {
    SplitPanes(minPrimary: 120, idealPrimary: 220, minSecondary: 240) {
        Color(hue: 0.6, saturation: 0.4, brightness: 0.5)
    } secondary: {
        SplitPanes(axis: .vertical, minPrimary: 80, minSecondary: 80, priority: nil) {
            Color(hue: 0.3, saturation: 0.4, brightness: 0.5)
        } secondary: {
            Color(hue: 0.1, saturation: 0.4, brightness: 0.5)
        }
    }
    .frame(width: 640, height: 360)
    .background(IDEAppearance.ColorToken.window)
    .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
