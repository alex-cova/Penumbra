@preconcurrency import AppKit

/// The overlay for Search Everywhere / Find Action / Recent Files / Go-to-file: a query field
/// above a grouped, keyboard-navigable results list. Positioned and driven by
/// `CommandPaletteController`; follows the same `NSView` + baked-`CGColor` idiom as
/// `WorkspaceSearchPanelView`.
@MainActor
public final class CommandPaletteView: NSView {
    public var onQueryChange: ((String) -> Void)?
    public var onMoveSelection: ((Int) -> Void)?
    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Row was clicked — argument is the item index (headers excluded).
    public var onActivateItemAtIndex: ((Int) -> Void)?

    private enum Row {
        case header(String)
        case item(PaletteItem)
    }

    private let queryField = PaletteQueryField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [Row] = []
    /// Table row index of the currently selected item, or `nil`.
    private var selectedTableRow: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var placeholder: String = "" {
        didSet { queryField.placeholderString = placeholder }
    }

    public var query: String {
        get { queryField.stringValue }
        set { queryField.stringValue = newValue }
    }

    /// Makes the query field first responder — call after the view is in a window.
    public func focusQueryField() {
        window?.makeFirstResponder(queryField)
    }

    /// - Parameters:
    ///   - sections: grouped results.
    ///   - selectedItemIndex: index among items (headers excluded).
    public func update(sections: [PaletteSection], selectedItemIndex: Int) {
        var newRows: [Row] = []
        for section in sections {
            if !section.title.isEmpty {
                newRows.append(.header(section.title))
            }
            for item in section.items {
                newRows.append(.item(item))
            }
        }
        rows = newRows
        tableView.reloadData()

        let itemRowIndices = rows.indices.filter { if case .item = rows[$0] { return true } else { return false } }
        if itemRowIndices.isEmpty {
            selectedTableRow = nil
        } else {
            let clamped = min(max(selectedItemIndex, 0), itemRowIndices.count - 1)
            selectedTableRow = itemRowIndices[clamped]
        }
        if let selectedTableRow {
            tableView.selectRowIndexes(IndexSet(integer: selectedTableRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedTableRow)
        } else {
            tableView.deselectAll(nil)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 24
        layer?.shadowOffset = .zero
        applyChromeColors()

        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.font = .systemFont(ofSize: 17, weight: .regular)
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.delegate = self
        queryField.onMoveSelection = { [weak self] delta in self?.onMoveSelection?(delta) }
        queryField.onConfirm = { [weak self] in self?.onConfirm?() }
        queryField.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(queryField)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.target = self
        tableView.action = #selector(tableViewClicked)
        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            queryField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            queryField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            queryField.heightAnchor.constraint(equalToConstant: 28),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    private func applyChromeColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            layer?.backgroundColor = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.133, alpha: 1).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    @objc private func tableViewClicked() {
        let clickedRow = tableView.clickedRow
        guard rows.indices.contains(clickedRow), case .item = rows[clickedRow] else {
            return
        }
        let itemIndex = rows[0...clickedRow].reduce(into: -1) { count, row in
            if case .item = row { count += 1 }
        }
        onActivateItemAtIndex?(itemIndex)
    }

    private func attributedTitle(for item: PaletteItem, includeSubtitle: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: item.title,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        let matched = Set(item.matchedIndices)
        let characters = Array(item.title)
        var utf16Offset = 0
        for (index, character) in characters.enumerated() {
            let length = String(character).utf16.count
            if matched.contains(index) {
                result.addAttributes(
                    [.foregroundColor: NSColor.controlAccentColor,
                     .font: NSFont.boldSystemFont(ofSize: 13)],
                    range: NSRange(location: utf16Offset, length: length)
                )
            }
            utf16Offset += length
        }
        if includeSubtitle, let subtitle = item.subtitle, !subtitle.isEmpty {
            result.append(NSAttributedString(
                string: "   \(subtitle)",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11)
                ]
            ))
        }
        return result
    }

    fileprivate static func isKeyboardShortcut(_ subtitle: String) -> Bool {
        subtitle.contains("⌘")
            || subtitle.contains("⌃")
            || subtitle.contains("⌥")
            || subtitle.contains("⇧")
            || subtitle.contains("\u{2303}")
    }
}

extension CommandPaletteView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] {
            let view = NSTableRowView()
            view.selectionHighlightStyle = .none
            return view
        }
        return PaletteRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("headerCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeLabelCell(id: id)
            cell.textField?.stringValue = title
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            return cell
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("itemCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteItemCell ?? PaletteItemCell(id: id)
            let shortcut = item.subtitle.flatMap { Self.isKeyboardShortcut($0) ? $0 : nil }
            cell.apply(
                title: attributedTitle(for: item, includeSubtitle: shortcut == nil),
                shortcut: shortcut
            )
            return cell
        }
    }

    private static func makeLabelCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let view = NSTableCellView()
        view.identifier = id
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        view.addSubview(textField)
        view.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }
}

extension CommandPaletteView: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(queryField.stringValue)
    }
}

/// Query field that routes ↑/↓/Return/Esc to the palette instead of the field editor.
private final class PaletteQueryField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onMoveSelection?(-1)
        case #selector(NSResponder.moveDown(_:)):
            onMoveSelection?(1)
        case #selector(NSResponder.insertNewline(_:)):
            onConfirm?()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: selector)
        }
    }
}

private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
    }
}

private final class PaletteItemCell: NSTableCellView {
    private let shortcutField = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        addSubview(textField)
        self.textField = textField

        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutField.textColor = .tertiaryLabelColor
        shortcutField.alignment = .right
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(shortcutField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 8),
            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(title: NSAttributedString, shortcut: String?) {
        textField?.attributedStringValue = title
        if let shortcut, !shortcut.isEmpty {
            shortcutField.stringValue = shortcut
            shortcutField.isHidden = false
        } else {
            shortcutField.stringValue = ""
            shortcutField.isHidden = true
        }
    }
}
