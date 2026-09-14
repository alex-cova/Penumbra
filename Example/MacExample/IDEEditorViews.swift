import AppKit
import Runestone

// MARK: - Pane host

@MainActor
final class IDEEditorPaneHost: NSView {
    let pane: EditorPane
    let textView: TextView
    let paletteController: CommandPaletteController
    let applyGate = RunestoneStateBuilder.GenerationGate()
    var loadedDocumentID: UUID?
    var onTabSelected: ((UUID) -> Void)?
    var onTabClosed: ((UUID) -> Void)?
    var onPaneActivated: (() -> Void)?

    private let accentBar = NSView()

    init(pane: EditorPane) {
        self.pane = pane
        textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.theme = DefaultTheme()
        textView.showMinimap = true
        textView.showMethodSeparators = true
        textView.highlightsOccurrencesOfSelection = true
        textView.keymap = .default_
        paletteController = CommandPaletteController(textView: textView)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1).cgColor

        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor(red: 0, green: 0x7a / 255, blue: 0xcc / 255, alpha: 1).cgColor
        accentBar.isHidden = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accentBar)
        addSubview(textView)

        NSLayoutConstraint.activate([
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Do not delay mouse-down: the default click recognizer would swallow the event
        // so TextInputView never becomes first responder. Deliver the click to the editor
        // and only use this recognizer to activate the pane.
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func paneClicked() {
        onPaneActivated?()
    }

    func setActive(_ active: Bool) {
        accentBar.isHidden = !active
        layer?.borderWidth = active ? 0 : 1
        layer?.borderColor = NSColor(red: 0x3c / 255, green: 0x3c / 255, blue: 0x3c / 255, alpha: 1).cgColor
    }
}

// MARK: - Layout host

@MainActor
final class IDEEditorLayoutHostView: NSView {
    var onPaneActivated: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        layout: EditorLayout,
        existingHosts: [UUID: IDEEditorPaneHost],
        makeHost: (EditorPane) -> IDEEditorPaneHost
    ) -> [UUID: IDEEditorPaneHost] {
        subviews.forEach { $0.removeFromSuperview() }
        var hosts: [UUID: IDEEditorPaneHost] = [:]

        func host(for pane: EditorPane) -> IDEEditorPaneHost {
            if let existing = existingHosts[pane.id] {
                hosts[pane.id] = existing
                existing.onPaneActivated = { [weak self] in
                    self?.onPaneActivated?(pane.id)
                }
                return existing
            }
            let created = makeHost(pane)
            created.onPaneActivated = { [weak self] in
                self?.onPaneActivated?(pane.id)
            }
            hosts[pane.id] = created
            return created
        }

        let built = buildView(for: layout, hostForPane: host)
        built.translatesAutoresizingMaskIntoConstraints = false
        addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: topAnchor),
            built.leadingAnchor.constraint(equalTo: leadingAnchor),
            built.trailingAnchor.constraint(equalTo: trailingAnchor),
            built.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        return hosts
    }

    private func buildView(
        for layout: EditorLayout,
        hostForPane: (EditorPane) -> IDEEditorPaneHost
    ) -> NSView {
        switch layout {
        case .pane(let pane):
            return hostForPane(pane)
        case .vertical(let data):
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            styleSplitView(split)
            for child in data.children {
                split.addArrangedSubview(buildView(for: child, hostForPane: hostForPane))
            }
            return split
        case .horizontal(let data):
            let split = NSSplitView()
            split.isVertical = false
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            styleSplitView(split)
            for child in data.children {
                split.addArrangedSubview(buildView(for: child, hostForPane: hostForPane))
            }
            return split
        }
    }

    private func styleSplitView(_ splitView: NSSplitView) {
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1).cgColor
    }
}
