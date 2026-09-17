@preconcurrency import AppKit
import EditorIntelligence

/// Panel listing matches from a workspace-wide search.
@MainActor
public final class WorkspaceSearchPanelView: NSView {
    public var onSelectResult: ((WorkspaceSearchResult) -> Void)?

    private var model = WorkspaceSearchModel(query: "", results: [])
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: WorkspaceSearchModel) {
        self.model = model
        tableView.reloadData()
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

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.width = 120
        let previewColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        tableView.addTableColumn(fileColumn)
        tableView.addTableColumn(previewColumn)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .plain
        tableView.backgroundColor = .clear
        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
}

extension WorkspaceSearchPanelView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = model.results[row]
        let cellID = NSUserInterfaceItemIdentifier("searchCell")
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
        if tableColumn?.identifier.rawValue == "file" {
            cell.textField?.stringValue = "\(result.documentName):\(result.line + 1)"
        } else {
            cell.textField?.stringValue = result.preview
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard model.results.indices.contains(row) else {
            return
        }
        onSelectResult?(model.results[row])
    }
}
