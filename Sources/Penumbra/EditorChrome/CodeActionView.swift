@preconcurrency import AppKit
import EditorIntelligence

/// Popover-style list of available code actions. An intention with a preview shows it beside the
/// list, and a chevron on that row offers Disable and Edit settings.
@MainActor
public final class CodeActionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public var onSelectAction: ((CodeAction) -> Void)?
    public var onSelectOption: ((CodeActionOption) -> Void)?

    private var model = CodeActionModel(actions: [], anchorRange: TextRange(
        start: TextPosition(line: 0, column: 0, utf16Offset: 0),
        end: TextPosition(line: 0, column: 0, utf16Offset: 0)
    ))
    private let tableView = NSTableView()
    private let previewField = NSTextField(wrappingLabelWithString: "")
    private var suppressRowClick = false

    /// The highlighted action, the one Return applies.
    public var selectedAction: CodeAction? {
        model.actions.indices.contains(tableView.selectedRow) ? model.actions[tableView.selectedRow] : nil
    }

    /// Width and height for the list, wider when any action carries a preview.
    public var preferredSize: NSSize {
        let rows = max(model.actions.count, 1)
        let listHeight = min(CGFloat(rows) * 24 + 8, 280)
        let showsPreview = model.actions.contains { $0.preview != nil }
        return NSSize(width: showsPreview ? 520 : 300, height: showsPreview ? max(listHeight, 96) : listHeight)
    }

    /// Highlights `row` (clamped) without applying it.
    public func selectRow(_ row: Int) {
        guard !model.actions.isEmpty else { return }
        let clamped = min(max(0, row), model.actions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
        updatePreview()
    }

    /// Moves the highlight by `delta` rows, wrapping around.
    public func moveSelection(by delta: Int) {
        let count = model.actions.count
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : count - 1) : ((current + delta) % count + count) % count
        selectRow(next)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: CodeActionModel) {
        self.model = model
        tableView.reloadData()
        if !model.actions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updatePreview()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let showsPreview = model.actions.contains { $0.preview != nil }
        let previewWidth: CGFloat = showsPreview ? 210 : 0
        let tableWidth = max(0, bounds.width - previewWidth - 8)
        tableView.frame = CGRect(x: 4, y: 4, width: tableWidth, height: max(0, bounds.height - 8))
        previewField.frame = CGRect(x: bounds.width - previewWidth - 4, y: 4, width: max(0, previewWidth), height: max(0, bounds.height - 8))
        previewField.isHidden = !showsPreview
    }

    /// `layer?.backgroundColor`/`borderColor` in `configure()` are baked to `CGColor` once, so
    /// dynamic system colors go stale if the effective appearance changes afterward.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// A click applies the action. Selection alone (arrow keys, the initial highlight) does not.
    @objc private func rowClicked() {
        if suppressRowClick {
            suppressRowClick = false
            return
        }
        let row = tableView.clickedRow
        guard model.actions.indices.contains(row) else { return }
        onSelectAction?(model.actions[row])
    }

    @objc private func showOptions(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard model.actions.indices.contains(row) else { return }
        suppressRowClick = true
        selectRow(row)
        let menu = NSMenu()
        for (index, option) in model.actions[row].options.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(chooseOption(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = NSNumber(value: row)
            menu.addItem(item)
        }
        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func chooseOption(_ sender: NSMenuItem) {
        guard let row = (sender.representedObject as? NSNumber)?.intValue, model.actions.indices.contains(row),
              model.actions[row].options.indices.contains(sender.tag) else { return }
        onSelectOption?(model.actions[row].options[sender.tag])
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.actions.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = model.actions[row]
        let cellID = NSUserInterfaceItemIdentifier("actionCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? CodeActionCell ?? CodeActionCell(identifier: cellID)
        cell.onShowOptions = { [weak self] button in self?.showOptions(button) }
        cell.update(action)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func updatePreview() {
        previewField.stringValue = selectedAction?.preview ?? ""
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(tableView)

        previewField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewField.textColor = .secondaryLabelColor
        previewField.maximumNumberOfLines = 8
        previewField.lineBreakMode = .byTruncatingTail
        previewField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(previewField)
    }
}

/// One row: the action's title, and a chevron when it has options.
@MainActor
private final class CodeActionCell: NSTableCellView {
    var onShowOptions: ((NSButton) -> Void)?
    private let optionsButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        addSubview(textField)
        self.textField = textField

        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.isBordered = false
        optionsButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Intention options")
        optionsButton.imageScaling = .scaleProportionallyDown
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.setAccessibilityLabel("Intention options")
        addSubview(optionsButton)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            optionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 16),
            optionsButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ action: CodeAction) {
        let prefix = action.isPreferred ? "💡 " : ""
        textField?.stringValue = "\(prefix)\(action.title)"
        optionsButton.isHidden = action.options.isEmpty
    }

    @objc private func showOptions() {
        onShowOptions?(optionsButton)
    }
}
