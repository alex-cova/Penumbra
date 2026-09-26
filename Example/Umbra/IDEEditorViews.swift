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

        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    func wireMarkdownPreview() {
        markdownPreviewController.installMetalFailureHandler(chaining: textView.onMetalRenderingFailure)
        markdownPreviewController.installTextObservation(chaining: textView.editorDelegate)
        markdownPreviewController.codeBlockLanguageResolver = { IDELanguageSupport.language(forIdentifier: $0) }

        let previousHandler = textView.editorActionHandler
        textView.editorActionHandler = { [markdownPreviewController] action in
            if action == .toggleMarkdownPreview {
                return markdownPreviewController.toggle()
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
        container.mount(workspace.host(for: paneID))
    }
}

// MARK: - Layout

struct IDEEditorLayoutNode: View {
    @Environment(IDEWorkspace.self) private var workspace
    let layout: EditorLayout

    var body: some View {
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
    .background(IDEAppearance.ColorToken.frame)
    .preferredColorScheme(.dark)
}
