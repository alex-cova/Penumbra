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
    /// True while this pane's JSON file is covered by its diagram.
    private(set) var isJSONDiagramVisible = false
    private var jsonDiagramSession: IDEDiagramSession?
    private var jsonRefreshTask: Task<Void, Never>?
    private var editorWasSelectableBeforeJSONDiagram = true
    /// Laid over the editor while a CSV or TSV file's table preview is showing.
    let csvTableView = IDECSVTableView()
    /// True while this pane's CSV/TSV file is covered by its table.
    private(set) var isCSVTableVisible = false
    private var csvRefreshTask: Task<Void, Never>?
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

        csvTableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(csvTableView)
        NSLayoutConstraint.activate([
            csvTableView.topAnchor.constraint(equalTo: topAnchor),
            csvTableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            csvTableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            csvTableView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        csvTableView.onRevealLine = { [weak self] line in self?.revealCSVSourceLine(line) }

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
        jsonRefreshTask?.cancel()
        jsonRefreshTask = nil
        guard isJSONDiagramVisible else { return }
        isJSONDiagramVisible = false
        textView.isSelectable = editorWasSelectableBeforeJSONDiagram
        jsonDiagramSession?.cancel()
        if hidingViewer { diagramViewer.hide() }
    }

    /// Rebuilds the diagram from the live buffer. A first show lets the viewer start the load;
    /// later shows reload, because the viewer only loads an empty session.
    func refreshJSONDiagram() {
        jsonRefreshTask?.cancel()
        jsonRefreshTask = nil
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
        jsonRefreshTask?.cancel()
        jsonRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
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
        csvRefreshTask?.cancel()
        csvRefreshTask = nil
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
        csvRefreshTask?.cancel()
        csvRefreshTask = nil
        csvParseTask?.cancel()
        guard isCSVTableVisible, Self.isCSV(textView.languageIdentifier) else { return }
        let text = textView.text
        let identifier = textView.languageIdentifier
        csvParseTask = Task { [weak self] in
            let table = await Task.detached(priority: .userInitiated) {
                let sample = String(text.prefix(4096))
                let delimiter = IDECSVTable.delimiter(forIdentifier: identifier, sample: sample)
                return IDECSVTable.parse(text, delimiter: delimiter)
            }.value
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
        csvRefreshTask?.cancel()
        csvRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
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
        container.mount(workspace.host(for: paneID))
    }
}

// MARK: - Layout

struct IDEEditorLayoutNode: View {
    @Environment(IDEWorkspace.self) private var workspace
    let layout: EditorLayout

    var body: some View {
        let _ = workspace.layoutEpoch
        switch layout {
        case .pane(let pane):
            IDEEditorPaneView(paneID: pane.id)
                .id(pane.id)
        case .horizontal(let data):
            // `.horizontal` means children sit left/right (see `EditorSplitData.split`), i.e. an
            // HStack. Switch on `data.axis` rather than the enum case so a case/axis mismatch
            // (the two are always constructed together, but round-trip independently through
            // `EditorRestorationState`) can't silently invert the split again.
            IDEEditorSplitChain(axis: data.axis == .horizontal ? .horizontal : .vertical, children: data.children)
        case .vertical(let data):
            IDEEditorSplitChain(axis: data.axis == .horizontal ? .horizontal : .vertical, children: data.children)
        }
    }
}

struct IDEEditorPaneView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let paneID: UUID

    var body: some View {
        VStack(spacing: 0) {
            IDEEditorTabsBar(paneID: paneID)
                .opacity(workspace.chromeOpacity)

            IDETextViewRepresentable(paneID: paneID, workspace: workspace)
                .overlay {
                    if workspace.activePaneID != paneID {
                        Rectangle()
                            .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
struct IDEEditorSplitChain: View {
    let axis: SplitLayout
    let children: [EditorLayout]
    var start = 0

    var body: some View {
        let remaining = children.count - start
        Group {
            if remaining <= 0 {
                Color.clear
            } else if remaining == 1 {
                IDEEditorLayoutNode(layout: children[start])
            } else {
                SplitPanes(
                    axis: axis,
                    minPrimary: IDEAppearance.Spacing.editorPaneMinLength,
                    minSecondary: IDEAppearance.Spacing.editorPaneMinLength * CGFloat(remaining - 1),
                    defaultFraction: 1 / CGFloat(remaining),
                    // Panes scale together with the window rather than one keeping its size.
                    priority: nil
                ) {
                    IDEEditorLayoutNode(layout: children[start])
                } secondary: {
                    IDEEditorSplitChain(axis: axis, children: children, start: start + 1)
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
