import AppKit
import Penumbra

/// Laid over the editor while a CSV or TSV file's table preview is showing. Read-only: a
/// virtualized `NSTableView` over an `IDECSVTable`, sortable by column, with row numbers.
@MainActor
final class IDECSVTableView: NSView {
    /// A double-click on a row: the zero-based line of the buffer the row starts on.
    var onRevealLine: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = IDECSVNSTableView()
    private let searchField = NSSearchField()
    private let footer = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private var table = IDECSVTable.empty
    /// Row indexes into `table.rows` in display order.
    private var order: [Int] = []
    private var sortKey: String?
    private var sortAscending = true
    private var numericColumns: [Bool?] = []
    private var configuredHeader: [String] = []
    private var footerHeight: NSLayoutConstraint?
    /// What the search field holds; rows with no cell containing it are hidden.
    private var query = ""
    private var searchTask: Task<Void, Never>?

    private static let rowNumberID = NSUserInterfaceItemIdentifier("csv.row")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true

        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.copyHandler = { [weak self] in self?.copySelection() }

        searchField.placeholderString = "Search rows"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        footer.alignment = .center
        footer.font = .systemFont(ofSize: 11)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        message.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)

        let footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        self.footerHeight = footerHeight
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footerHeight,
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuilt on every show so a changed UI color scheme or font is picked up.
    func show() {
        isHidden = false
        applyColors()
        tableView.reloadData()
    }

    func hide() {
        isHidden = true
    }

    func focus() {
        window?.makeFirstResponder(tableView)
    }

    /// ⌘F: the search field takes the keyboard, with its text selected.
    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Shows `table`, keeping the scroll position and the sort when the columns are the same.
    func update(_ table: IDECSVTable) {
        let sameColumns = table.header == configuredHeader
        self.table = table
        numericColumns = Array(repeating: nil, count: table.columnCount)
        if !sameColumns { rebuildColumns() }
        if let sortKey, columnIndex(of: sortKey) == nil {
            self.sortKey = nil
            tableView.sortDescriptors = []
        }
        applySort()
        tableView.reloadData()
        updateFooter()
        message.stringValue = table.columnCount == 0 ? "Empty file" : ""
        message.isHidden = table.columnCount != 0
    }

    // MARK: - Columns

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        configuredHeader = table.header
        guard table.columnCount > 0 else { return }

        let font = IDEEditorTheme.shared.current.font
        let rowNumbers = NSTableColumn(identifier: Self.rowNumberID)
        rowNumbers.title = "#"
        rowNumbers.width = 56
        rowNumbers.minWidth = 40
        rowNumbers.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumbers)

        for index in 0..<table.columnCount {
            let column = NSTableColumn(identifier: Self.columnID(index))
            let title = table.header[index]
            column.title = title.isEmpty ? "Column \(index + 1)" : title
            column.minWidth = 40
            column.width = Self.initialWidth(for: index, in: table, font: font)
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            tableView.addTableColumn(column)
        }
    }

    private static func columnID(_ index: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("csv.col.\(index)")
    }

    private func columnIndex(of key: String) -> Int? {
        guard key.hasPrefix("csv.col."), let index = Int(key.dropFirst("csv.col.".count)),
              index < table.columnCount else { return nil }
        return index
    }

    /// Wide enough for the header and the first rows' values, within a readable range.
    private static func initialWidth(for column: Int, in table: IDECSVTable, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest = (table.header[column] as NSString).size(withAttributes: attributes).width + 24
        for row in table.rows.prefix(50) {
            widest = max(widest, (row[column] as NSString).size(withAttributes: attributes).width + 16)
        }
        return min(max(widest, 60), 360)
    }

    // MARK: - Sorting

    /// Rows that contain the search text in any cell (all rows when it is empty), in file order.
    private func matchingRows() -> [Int] {
        guard !query.isEmpty else { return Array(table.rows.indices) }
        return table.rows.indices.filter { row in
            table.rows[row].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func updateFooter() {
        var parts: [String] = []
        if !query.isEmpty {
            parts.append("\(order.count.formatted()) of \(table.rows.count.formatted()) rows match")
        }
        if table.isTruncated {
            parts.append("Showing the first \(IDECSVTable.maximumRows.formatted()) rows")
        }
        footer.stringValue = parts.joined(separator: " · ")
        footerHeight?.constant = parts.isEmpty ? 0 : 22
    }

    /// Filters by the search text, then sorts by the chosen column.
    private func applySort() {
        var indexes = matchingRows()
        guard let sortKey, let column = columnIndex(of: sortKey) else {
            order = indexes
            return
        }
        let numeric = isNumeric(column)
        let ascending = sortAscending
        let rows = table.rows
        if numeric {
            let values = rows.map { Double($0[column].trimmingCharacters(in: .whitespaces)) ?? -.infinity }
            indexes.sort { lhs, rhs in
                values[lhs] == values[rhs] ? lhs < rhs : (values[lhs] < values[rhs]) == ascending
            }
        } else {
            indexes.sort { lhs, rhs in
                let result = rows[lhs][column].localizedStandardCompare(rows[rhs][column])
                return result == .orderedSame ? lhs < rhs : (result == .orderedAscending) == ascending
            }
        }
        order = indexes
    }

    /// True when every non-empty value in the column reads as a number.
    private func isNumeric(_ column: Int) -> Bool {
        if let cached = numericColumns[column] { return cached }
        var sawValue = false
        var numeric = true
        for row in table.rows {
            let value = row[column].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            sawValue = true
            if Double(value) == nil {
                numeric = false
                break
            }
        }
        let result = sawValue && numeric
        numericColumns[column] = result
        return result
    }

    // MARK: - Actions

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < order.count else { return }
        let source = order[row]
        guard source < table.sourceLines.count else { return }
        onRevealLine?(table.sourceLines[source])
    }

    /// The selected rows (all rows when none is selected) as delimiter-separated text.
    private func copySelection() {
        let selected = tableView.selectedRowIndexes
        let displayRows = selected.isEmpty ? Array(order.indices) : Array(selected)
        let delimiter = String(table.delimiter)
        let lines = displayRows.compactMap { display -> String? in
            guard display < order.count else { return nil }
            return table.rows[order[display]].map { Self.quoted($0, delimiter: delimiter) }.joined(separator: delimiter)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private static func quoted(_ value: String, delimiter: String) -> String {
        guard value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func applyColors() {
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        footer.textColor = IDEAppearance.NSToken.muted
        message.textColor = IDEAppearance.NSToken.muted
        tableView.gridColor = IDEAppearance.NSToken.border
    }
}

// MARK: - Table

extension IDECSVTableView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < order.count else { return nil }
        let identifier = tableColumn.identifier
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.lineBreakMode = .byTruncatingTail
            cell.usesSingleLineMode = true
        }
        let source = order[row]
        cell.font = IDEEditorTheme.shared.current.font
        if identifier == Self.rowNumberID {
            cell.stringValue = String(source + 1)
            cell.alignment = .right
            cell.textColor = IDEAppearance.NSToken.muted
        } else if let column = columnIndex(of: identifier.rawValue) {
            cell.stringValue = table.rows[source][column]
            cell.alignment = isNumeric(column) ? .right : .left
            cell.textColor = IDEAppearance.NSToken.foreground
            highlightMatches(in: cell)
        }
        return cell
    }

    /// Marks every occurrence of the search text in a cell's (already set) string.
    private func highlightMatches(in cell: NSTextField) {
        guard !query.isEmpty else { return }
        let text = cell.stringValue
        let marked = NSMutableAttributedString(string: text, attributes: [
            .font: cell.font as Any,
            .foregroundColor: cell.textColor as Any
        ])
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            marked.addAttribute(
                .backgroundColor,
                value: IDEAppearance.NSToken.selection,
                range: NSRange(found, in: text)
            )
            searchRange = found.upperBound..<text.endIndex
        }
        cell.attributedStringValue = marked
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            sortKey = key
            sortAscending = descriptor.ascending
        } else {
            sortKey = nil
        }
        applySort()
        tableView.reloadData()
    }
}

/// An `NSTableView` that answers ⌘C itself, since the first responder is what Edit ▸ Copy reaches.
private final class IDECSVNSTableView: NSTableView {
    var copyHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        copyHandler?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? true : super.validateUserInterfaceItem(item)
    }
}

// MARK: - Search

extension IDECSVTableView: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        let text = searchField.stringValue
        guard text != query else { return }
        // Filtering touches every cell, so wait for a pause in typing on a large file.
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            query = text
            applySort()
            tableView.reloadData()
            updateFooter()
        }
    }

    /// Esc clears the search; with nothing to clear it hands the keyboard to the table.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if searchField.stringValue.isEmpty {
            focus()
        } else {
            searchField.stringValue = ""
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        return true
    }
}
