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
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            tableView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
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

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard model.actions.indices.contains(row) else {
            return
        }
        onSelectAction?(model.actions[row])
    }
}
