@preconcurrency import AppKit
import EditorIntelligence

/// Sidebar view that renders a hierarchical document outline.
@MainActor
public final class OutlineSidebarView: NSView {
    public var onSelectItem: ((OutlineItem) -> Void)?

    private var model = OutlineModel(items: [])
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

    public func update(model: OutlineModel) {
        self.model = model
        tableView.reloadData()
        if let selectedID = model.selectedItemID,
           let row = flattenedItems().firstIndex(where: { $0.item.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// `layer?.backgroundColor` in `configure()` is baked to `CGColor` once, so a dynamic system
    /// color goes stale if the effective appearance changes afterward.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        column.title = "Outline"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .plain
        tableView.backgroundColor = .clear
        scrollView.documentView = tableView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func flattenedItems() -> [(item: OutlineItem, depth: Int)] {
        var result: [(OutlineItem, Int)] = []
        func walk(_ items: [OutlineItem], depth: Int) {
            for item in items {
                result.append((item, depth))
                walk(item.children, depth: depth + 1)
            }
        }
        walk(model.items, depth: 0)
        return result
    }
}

extension OutlineSidebarView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        flattenedItems().count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = flattenedItems()[row]
        let cellID = NSUserInterfaceItemIdentifier("outlineCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = cellID
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(textField)
            view.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        let indent = String(repeating: "  ", count: entry.depth)
        cell.textField?.stringValue = "\(indent)\(entry.item.title)"
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelectItem?(flattenedItems()[row].item)
    }
}
