@preconcurrency import AppKit
import EditorIntelligence

/// What ``NavigationChoicesView`` lists: a header and one row per candidate target.
public struct NavigationChoicesModel: Equatable {
    public struct Row: Equatable {
        public var title: String
        /// Where the target is: its folder and file, so two classes named alike in different
        /// packages are told apart.
        public var subtitle: String?
        /// The target's 1-based line, shown at the row's trailing edge.
        public var line: Int?
        /// SF Symbol drawn before the title: a method or constructor, or a type.
        public var symbolName: String

        public init(title: String, subtitle: String?, line: Int? = nil, symbolName: String = "c.square.fill") {
            self.title = title
            self.subtitle = subtitle
            self.line = line
            self.symbolName = symbolName
        }
    }

    public var header: String
    public var rows: [Row]

    public init(header: String, rows: [Row]) {
        self.header = header
        self.rows = rows
    }

    /// Rows for `locations`, each subtitled with its file and folder.
    public init(identifier: String, locations: [Location]) {
        header = "\(locations.count) targets for \(identifier)"
        rows = locations.map { location in
            // A folder or package row is already named by its path; there is no file to add.
            let subtitle = location.target != .source ? nil : location.url.map { url -> String in
                let folder = url.deletingLastPathComponent().lastPathComponent
                return folder.isEmpty ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
            }
            let line = location.target == .source && location.url != nil ? location.range.start.line + 1 : nil
            let symbol: String
            switch location.target {
            case .directory, .package: symbol = "folder.fill"
            case .source: symbol = location.displayName.contains("(") ? "m.square.fill" : "c.square.fill"
            }
            return Row(title: location.displayName, subtitle: subtitle, line: line, symbolName: symbol)
        }
    }
}

/// Popup listing the targets of a ⌘-click that resolved to more than one location (e.g. the
/// implementations of an interface, or the constructors of a class). ↑/↓ move the highlight,
/// Return or a click opens a row.
///
/// A row is two lines: the target's name (a signature, for a method or constructor) and, under it,
/// the file it is in, with the line at the trailing edge. The popup is as wide as its longest name
/// within limits, and a name longer than that is cut in the middle, so the end of a signature
/// stays readable.
@MainActor
public final class NavigationChoicesView: NSView {
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 28
    static let maximumVisibleRows = 8
    static let minimumWidth: CGFloat = 340
    static let maximumWidth: CGFloat = 620
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Room beside the title: the icon, the line number and the paddings.
    private static let horizontalChrome: CGFloat = 4 + 18 + 8 + 8 + 52 + 8

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
        let widest = model.rows.map { ($0.title as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        let width = min(max(widest + horizontalChrome, minimumWidth), maximumWidth)
        return NSSize(width: width.rounded(.up), height: headerHeight + CGFloat(visibleRows) * rowHeight + 8)
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
        applyChromeColors()
    }

    private func applyChromeColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard model.rows.indices.contains(row) else { return }
        onChoose?(row)
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        applyChromeColors()

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Frame-positioned and zero-sized until shown, so trailing and bottom insets give way
        // below required until the frame is set (as in `CodeActionView`).
        let headerTrailing = headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        headerTrailing.priority = .init(999)
        let trailing = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        trailing.priority = .init(999)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerTrailing,
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.heightAnchor.constraint(equalToConstant: 14),
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

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NavigationChoiceRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("targetCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NavigationChoiceCell ?? {
            let view = NavigationChoiceCell()
            view.identifier = cellID
            return view
        }()
        cell.configure(with: model.rows[row])
        return cell
    }
}

/// A row's selection: a rounded tint that shows whether or not the table has the keyboard, since
/// the popup's keys are handled by the editor and the table is never first responder.
private final class NavigationChoiceRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 2, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// The tint is light, so the text keeps its normal colors instead of flipping to white.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class NavigationChoiceCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NavigationChoicesView.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingHead
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        lineLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lineLabel.textColor = .tertiaryLabelColor
        lineLabel.alignment = .right
        lineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lineLabel.setContentHuggingPriority(.required, for: .horizontal)
        lineLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [iconView, titleLabel, subtitleLabel, lineLabel] { addSubview(subview) }
        textField = titleLabel
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            lineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            lineLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: lineLabel.leadingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with row: NavigationChoicesModel.Row) {
        titleLabel.stringValue = row.title
        subtitleLabel.stringValue = row.subtitle ?? ""
        subtitleLabel.isHidden = row.subtitle == nil
        lineLabel.stringValue = row.line.map { ":\($0)" } ?? ""
        iconView.image = NSImage(systemSymbolName: row.symbolName, accessibilityDescription: nil)
        setAccessibilityLabel([row.title, row.subtitle, row.line.map { "line \($0)" }].compactMap { $0 }.joined(separator: ", "))
        // A row with no subtitle centres its title.
        needsLayout = true
    }
}
