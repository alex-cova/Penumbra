import AppKit

/// The terminal's find bar: a search field, "k of n", previous/next and close, floating at the top
/// trailing corner of one terminal session (`IDETerminalHostView` owns one per session).
///
/// Keys while the field has focus: Return selects the next match (toward older output, as in
/// Ghostty), Shift-Return the previous one, Escape closes the bar and hands the keyboard back to the
/// terminal. Typing searches after a short pause.
@MainActor
final class GhosttyTerminalFindBar: NSView, NSSearchFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var pendingQuery: Task<Void, Never>?
    /// Typing pause before the search runs.
    var queryDelay: Duration = .milliseconds(80)
    /// Whether the Return being handled was Shift-Return (tests replace it).
    var isShiftDown: () -> Bool = { NSApp.currentEvent?.modifierFlags.contains(.shift) == true }

    var query: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    var statusText: String { statusLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        applyColors()

        searchField.placeholderString = "Find in Terminal"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Find in Terminal")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byClipping
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previous = Self.button("chevron.down", help: "Previous Match (⇧↩)", action: #selector(previousClicked))
        let next = Self.button("chevron.up", help: "Next Match (↩)", action: #selector(nextClicked))
        let close = Self.button("xmark", help: "Close (Esc)", action: #selector(closeClicked))
        for button in [previous, next, close] { button.target = self }

        let stack = NSStackView(views: [searchField, statusLabel, next, previous, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 190),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal Find Bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func button(_ symbol: String, help: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.imageScaling = .scaleProportionallyDown
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    func applyColors() {
        layer?.backgroundColor = IDEAppearance.NSToken.workbench.cgColor
        layer?.borderColor = IDEAppearance.NSToken.border.cgColor
        statusLabel.textColor = IDEAppearance.NSToken.muted
    }

    /// Puts the keyboard in the field with its text selected, so typing replaces the last search.
    func focusField() {
        guard let window else { return }
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func show(_ state: GhosttySearchState) {
        statusLabel.stringValue = Self.statusText(for: state, query: query)
    }

    /// "3 of 12", "12 matches", "No matches", "Searching…"; a `+` while scrollback is still being read.
    static func statusText(for state: GhosttySearchState, query: String) -> String {
        guard !query.isEmpty else { return "" }
        let more = state.status == .searching ? "+" : ""
        if state.total == 0 {
            return state.status == .searching ? "Searching…" : "No matches"
        }
        if let index = state.selectedIndex {
            return "\(index + 1) of \(state.total)\(more)"
        }
        return state.total == 1 ? "1 match\(more)" : "\(state.total) matches\(more)"
    }

    // MARK: - Field

    func controlTextDidChange(_ notification: Notification) {
        pendingQuery?.cancel()
        let text = query
        if text.isEmpty {
            statusLabel.stringValue = ""
            onQueryChange?(text)
            return
        }
        let delay = queryDelay
        pendingQuery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.onQueryChange?(text)
        }
    }

    /// Runs a query the pause has not sent yet, so Return acts on what is typed.
    private func flushPendingQuery() {
        guard let pending = pendingQuery else { return }
        pending.cancel()
        pendingQuery = nil
        onQueryChange?(query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            flushPendingQuery()
            if isShiftDown() {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Handled here, so neither the field's own clear nor the panel's Escape (which hides the
            // whole bottom panel) runs.
            pendingQuery?.cancel()
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func nextClicked() {
        flushPendingQuery()
        onNext?()
    }

    @objc private func previousClicked() {
        flushPendingQuery()
        onPrevious?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
