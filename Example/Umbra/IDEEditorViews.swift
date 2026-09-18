import AppKit
import Penumbra
import SwiftUI

// MARK: - Pane host

@MainActor
final class IDEEditorPaneHost: NSView {
    let pane: EditorPane
    let textView: TextView
    let markdownPreviewController: MarkdownPreviewController
    let paletteController: CommandPaletteController
    let applyGate = PenumbraStateBuilder.GenerationGate()
    var intelligenceController: EditorIntelligenceController?
    var loadedDocumentID: UUID?
    /// `WorkbenchDocument.contentGeneration` as of the last `setState`/reload into this host —
    /// lets two panes sharing one document (from a split) tell a same-document refresh (this
    /// pane's own edits reapplied) apart from picking up an edit made in the *other* pane.
    var loadedGeneration: UInt64 = 0
    /// This pane's own scroll/selection, captured just before a reload triggered by the shared
    /// document changing underneath it. Preferred over `document.selectedRange`/`scrollOffset`
    /// on that reload so one pane's edits don't yank the other pane's viewport around.
    var lastSelectedRange: NSRange?
    var lastScrollOffset: CGPoint?
    var onActivated: (() -> Void)?

    init(pane: EditorPane, preferences: IDEPreferences) {
        self.pane = pane
        textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.theme = IDEEditorTheme.shared
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.showMethodSeparators = true
        textView.highlightsOccurrencesOfSelection = true
        textView.keymap = preferences.keymap
        markdownPreviewController = MarkdownPreviewController(textView: textView)
        paletteController = CommandPaletteController(textView: textView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        preferences.apply(to: textView)

        markdownPreviewController.embed(editorView: textView)
        let container = markdownPreviewController.containerView
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
            IDESplitStack(axis: data.axis == .horizontal ? .horizontal : .vertical, childCount: data.children.count) { index in
                IDEEditorLayoutNode(layout: data.children[index])
            }
        case .vertical(let data):
            IDESplitStack(axis: data.axis == .horizontal ? .horizontal : .vertical, childCount: data.children.count) { index in
                IDEEditorLayoutNode(layout: data.children[index])
            }
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

struct IDESplitStack<Content: View>: View {
    let axis: Axis
    let childCount: Int
    @ViewBuilder var content: (Int) -> Content

    @State private var fractions: [CGFloat] = []

    var body: some View {
        Group {
            if childCount <= 0 {
                Color.clear
            } else if childCount == 1 {
                content(0)
            } else {
                GeometryReader { geometry in
                    let sizes = splitSizes(in: geometry.size)
                    stack {
                        ForEach(0..<childCount, id: \.self) { index in
                            content(index)
                                .frame(
                                    width: axis == .horizontal ? sizes[index] : nil,
                                    height: axis == .vertical ? sizes[index] : nil
                                )
                            if index < childCount - 1 {
                                IDESplitHandle(axis: axis) { delta in
                                    resize(index: index, delta: delta, total: axisLength(geometry.size))
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: resetFractions)
        .onChange(of: childCount) {
            resetFractions()
        }
    }

    @ViewBuilder
    private func stack<Stacked: View>(@ViewBuilder content: () -> Stacked) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    private func axisLength(_ size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func splitSizes(in size: CGSize) -> [CGFloat] {
        let handleCount = CGFloat(max(childCount - 1, 0))
        let available = axisLength(size) - handleCount * IDESplitHandle.thickness
        let values = normalizedFractions()
        var result = values.map { ($0 * available).rounded() }
        if let last = result.indices.last {
            result[last] = max(0, available - result.dropLast().reduce(0, +))
        }
        return result
    }

    private func normalizedFractions() -> [CGFloat] {
        if fractions.count == childCount {
            return fractions
        }
        let share = 1 / CGFloat(max(childCount, 1))
        return Array(repeating: share, count: childCount)
    }

    private func resetFractions() {
        let share = 1 / CGFloat(max(childCount, 1))
        fractions = Array(repeating: share, count: max(childCount, 1))
    }

    private func resize(index: Int, delta: CGFloat, total: CGFloat) {
        guard fractions.indices.contains(index), fractions.indices.contains(index + 1), total > 0 else {
            return
        }
        let minimum: CGFloat = 0.12
        var next = fractions
        let change = delta / total
        next[index] += change
        next[index + 1] -= change
        if next[index] < minimum || next[index + 1] < minimum {
            return
        }
        fractions = next
    }
}

private struct IDESplitHandle: View {
    /// Total space this handle occupies along the split axis. `splitSizes(in:)` must subtract
    /// this per divider, not an arbitrary smaller amount, or panes are over-allocated and the
    /// last one overflows the stack.
    static let thickness: CGFloat = 6

    let axis: Axis
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear
                .frame(
                    width: axis == .horizontal ? Self.thickness : nil,
                    height: axis == .vertical ? Self.thickness : nil
                )
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let current = axis == .horizontal ? value.translation.width : value.translation.height
                    onDrag(current - lastTranslation)
                    lastTranslation = current
                }
                .onEnded { _ in
                    lastTranslation = 0
                }
        )
        .onHover { hovering in
            if hovering {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

#Preview("Split Stack") {
    IDESplitStack(axis: .horizontal, childCount: 3) { index in
        Color(hue: Double(index) / 3, saturation: 0.4, brightness: 0.6)
            .overlay {
                Text("Pane \(index)")
                    .foregroundStyle(.white)
            }
    }
    .frame(width: 640, height: 360)
    .preferredColorScheme(.dark)
}
