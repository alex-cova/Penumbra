@preconcurrency import AppKit
import EditorIntelligence

/// What ``NavigationChoicesView`` lists: a header and one row per candidate target.
public struct NavigationChoicesModel: Equatable {
    public struct Row: Equatable {
        public var title: String
        public var subtitle: String?

        public init(title: String, subtitle: String?) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public var header: String
    public var rows: [Row]

    public init(header: String, rows: [Row]) {
        self.header = header
        self.rows = rows
    }

    /// Rows for `locations`, each subtitled with its file and folder so two classes named alike
    /// in different packages are told apart.
    public init(identifier: String, locations: [Location]) {
        header = "Choose target for \(identifier) (\(locations.count))"
        rows = locations.map { location in
            let subtitle = location.url.map { url -> String in
                let folder = url.deletingLastPathComponent().lastPathComponent
                return folder.isEmpty ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
            }
            return Row(title: location.displayName, subtitle: subtitle)
        }
    }
}

/// Popup listing the targets of a ⌘-click that resolved to more than one location (e.g. the
/// implementations of an interface). ↑/↓ move the highlight, Return or a click opens a row.
@MainActor
public final class NavigationChoicesView: NSView {
    static let rowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 22
    static let maximumVisibleRows = 10
    static let width: CGFloat = 360

    /// Called with the index of the row a click or Return chose.
    public var onChoose: ((Int) -> Void)?

    public private(set) var model = NavigationChoicesModel(header: "", rows: [])
    private let headerLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    /// The highlighted row, the one Return opens.
    public var selectedIndex: Int? {
        model.rows.indices.contains(tableView.selectedRow) ? tableView.selectedRow : nil
    }

    public static func preferredSize(for model: NavigationChoicesModel) -> NSSize {
        let visibleRows = min(model.rows.count, maximumVisibleRows)
        return NSSize(width: width, height: headerHeight + CGFloat(visibleRows) * (rowHeight + 2) + 8)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: NavigationChoicesModel) {
        self.model = model
        headerLabel.stringValue = model.header
        tableView.reloadData()
    }

    /// Highlights `row` (clamped) without opening it.
    public func selectRow(_ row: Int) {
        guard !model.rows.isEmpty else { return }
        let clamped = min(max(0, row), model.rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    /// Moves the highlight by `delta` rows, wrapping around.
    public func moveSelection(by delta: Int) {
        let count = model.rows.count
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : count - 1) : ((current + delta) % count + count) % count
        selectRow(next)
    }

    /// `layer?.backgroundColor`/`borderColor` are baked to `CGColor`, so dynamic system colors go
    /// stale if the effective appearance changes afterward.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard model.rows.indices.contains(row) else { return }
        onChoose?(row)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Frame-positioned and zero-sized until shown, so trailing and bottom insets give way
        // below required until the frame is set (as in `CodeActionView`).
        let headerTrailing = headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        headerTrailing.priority = .init(999)
        let trailing = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        trailing.priority = .init(999)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerTrailing,
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            headerLabel.heightAnchor.constraint(equalToConstant: Self.headerHeight - 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            trailing,
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            bottom
        ])
    }
}

extension NavigationChoicesView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = model.rows[row]
        let cellID = NSUserInterfaceItemIdentifier("targetCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = cellID
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
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
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        if let subtitle = item.subtitle {
            text.append(NSAttributedString(string: "  \(subtitle)", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        cell.textField?.attributedStringValue = text
        return cell
    }
}
