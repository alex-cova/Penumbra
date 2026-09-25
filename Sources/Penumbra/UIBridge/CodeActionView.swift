@preconcurrency import AppKit
import EditorIntelligence

/// Popover-style list of available code actions.
@MainActor
public final class CodeActionView: NSView {
    public var onSelectAction: ((CodeAction) -> Void)?

    private var model = CodeActionModel(actions: [], anchorRange: TextRange(
        start: TextPosition(line: 0, column: 0, utf16Offset: 0),
        end: TextPosition(line: 0, column: 0, utf16Offset: 0)
    ))
    private let tableView = NSTableView()

    /// The highlighted action, the one Return applies.
    public var selectedAction: CodeAction? {
        model.actions.indices.contains(tableView.selectedRow) ? model.actions[tableView.selectedRow] : nil
    }

    /// Highlights `row` (clamped) without applying it.
    public func selectRow(_ row: Int) {
        guard !model.actions.isEmpty else { return }
        let clamped = min(max(0, row), model.actions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
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
        frame.size.height = min(CGFloat(model.actions.count) * 24 + 8, 200)
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
        let row = tableView.clickedRow
        guard model.actions.indices.contains(row) else { return }
        onSelectAction?(model.actions[row])
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
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        // The panel is frame-positioned and starts at zero size (autoresizing-mask width == 0),
        // so required 4 pt insets on both sides conflict until it is sized. Trailing and bottom
        // give way below required; once the frame is set they hold as before.
        let trailing = tableView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        trailing.priority = .init(999)
        let bottom = tableView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            trailing,
            tableView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bottom
        ])
    }
}

extension CodeActionView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.actions.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = model.actions[row]
        let cellID = NSUserInterfaceItemIdentifier("actionCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = cellID
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(textField)
            view.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        let prefix = action.isPreferred ? "💡 " : ""
        cell.textField?.stringValue = "\(prefix)\(action.title)"
        return cell
    }
}
