import AppKit
import DatabaseKit
import SwiftUI

/// The table tracks the store's row count. Its data source keeps only a window around the viewport.
struct IDEDatabaseResultGrid: NSViewRepresentable {
    let storage: IDEDatabaseResultStorage
    let columns: [String]
    let rowCount: Int
    let canSort: Bool
    let onSort: (String) -> Void
    let onInspect: (Int, Int) -> Void
    var reveal: Reveal?

    struct Reveal {
        let id = UUID()
        let row: Int
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTable()
        table.inspectSelection = { [weak coordinator = context.coordinator] in
            coordinator?.inspectSelectedValue() ?? false
        }
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.backgroundColor = .clear
        table.rowHeight = 20
        table.headerView = NSTableHeaderView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.inspectClickedValue)
        let menu = NSMenu()
        let inspect = NSMenuItem(title: "Inspect Value", action: #selector(Coordinator.inspectClickedValue), keyEquivalent: "")
        inspect.target = context.coordinator
        menu.addItem(inspect)
        table.menu = menu
        table.setAccessibilityLabel("Query results")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        context.coordinator.install(table: table, clip: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(storage: storage, columns: columns, rowCount: rowCount,
                                   canSort: canSort, onSort: onSort, onInspect: onInspect)
        context.coordinator.reveal(reveal)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private struct Cell: Sendable {
        let label: String
        let muted: Bool

        init(_ value: DatabaseValue) {
            muted = value.presence != .value
            switch value.presence {
            case .null: label = "NULL"
            case .missing: label = "Missing"
            case .empty: label = "Empty"
            case .unloaded: label = "Loading…"
            default: label = String((value.displayText() ?? "").prefix(DatabaseValue.displayLimit))
            }
        }
    }

    private final class GridTable: NSTableView {
        var inspectSelection: (() -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers == "i",
               inspectSelection?() == true { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let rowNumber = NSUserInterfaceItemIdentifier("rowNumber")
        private let rowPadding = 48
        private weak var table: NSTableView?
        private weak var clip: NSClipView?
        private var storage: IDEDatabaseResultStorage?
        private var columns: [String] = []
        private var rowCount = 0
        private var canSort = false
        private var onSort: ((String) -> Void)?
        private var onInspect: ((Int, Int) -> Void)?
        private var rows: [[Cell]] = []
        private var firstRow = 0
        private var requestedRange: Range<Int>?
        private var readTask: Task<Void, Never>?
        private var lastReveal: UUID?

        func reveal(_ request: Reveal?) {
            guard let request, request.id != lastReveal, (0..<rowCount).contains(request.row),
                  let table else { return }
            lastReveal = request.id
            table.selectRowIndexes(IndexSet(integer: request.row), byExtendingSelection: false)
            table.scrollRowToVisible(request.row)
        }

        func install(table: NSTableView, clip: NSClipView) {
            self.table = table
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibleBoundsChanged), name: name, object: clip)
            }
        }

        func detach() {
            readTask?.cancel()
            NotificationCenter.default.removeObserver(self)
            storage = nil
            table = nil
        }

        func update(
            storage: IDEDatabaseResultStorage, columns: [String], rowCount: Int, canSort: Bool,
            onSort: @escaping (String) -> Void, onInspect: @escaping (Int, Int) -> Void
        ) {
            guard let table else { return }
            self.onSort = onSort
            self.onInspect = onInspect
            self.canSort = canSort
            let changedResult = self.storage != storage
            if changedResult {
                readTask?.cancel()
                requestedRange = nil
                rows.removeAll()
                firstRow = 0
                self.storage = storage
                self.rowCount = rowCount
                table.deselectAll(nil)
                table.toolTip = nil
                clip?.scroll(to: .zero)
            }
            if changedResult || self.columns != columns {
                updateColumns(columns, reset: changedResult, in: table)
            }
            if changedResult {
                table.reloadData()
            } else if self.rowCount != rowCount {
                self.rowCount = rowCount
                table.noteNumberOfRowsChanged()
            }
            for column in table.tableColumns where column.identifier != Self.rowNumber {
                let index = Int(column.identifier.rawValue) ?? 0
                column.headerToolTip = canSort && columns.indices.contains(index) ? "Sort by \(columns[index])" : nil
            }
            visibleBoundsChanged()
        }

        private func updateColumns(_ newColumns: [String], reset: Bool, in table: NSTableView) {
            if reset || !newColumns.starts(with: columns) {
                for column in table.tableColumns { table.removeTableColumn(column) }
                let numbers = NSTableColumn(identifier: Self.rowNumber)
                numbers.title = "#"
                numbers.width = 64
                numbers.headerToolTip = "Row number"
                table.addTableColumn(numbers)
                columns = []
            }
            for index in columns.count..<newColumns.count {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = newColumns[index]
                column.width = 140
                column.minWidth = 60
                table.addTableColumn(column)
            }
            columns = newColumns
        }

        @objc private func visibleBoundsChanged() {
            guard let table, let storage, rowCount > 0 else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0, visible.location < rowCount else { return }
            let lastVisible = min(rowCount, NSMaxRange(visible))
            if firstRow <= visible.location, lastVisible <= firstRow + rows.count {
                readTask?.cancel()
                requestedRange = nil
                return
            }
            let range = max(0, visible.location - rowPadding)..<min(rowCount, lastVisible + rowPadding)
            if let requestedRange,
               requestedRange.lowerBound <= visible.location, lastVisible <= requestedRange.upperBound { return }
            readTask?.cancel()
            requestedRange = range
            readTask = Task { [weak self] in
                do {
                    // Coalesce a fast scroll before asking the store to decode a spilled chunk.
                    try await Task.sleep(for: .milliseconds(12))
                    let loaded = try await storage.store.mapRows(in: range) { $0.map(Cell.init) }
                    guard let self, !Task.isCancelled, self.storage == storage, requestedRange == range else { return }
                    requestedRange = nil
                    firstRow = range.lowerBound
                    rows = loaded
                    refreshVisibleCells(in: range)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.storage == storage, requestedRange == range else { return }
                    requestedRange = nil
                    self.table?.toolTip = error.localizedDescription
                }
            }
        }

        private func refreshVisibleCells(in range: Range<Int>) {
            guard let table else { return }
            let rect = table.visibleRect
            let visible = table.rows(in: rect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            let lower = max(range.lowerBound, visible.location)
            let upper = min(firstRow + rows.count, NSMaxRange(visible), rowCount)
            guard lower < upper else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: lower..<upper), columnIndexes: table.columnIndexes(in: rect))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            columnIndex > 0 && newColumnIndex > 0
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = column?.identifier else { return nil }
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
            if identifier == Self.rowNumber {
                cell.stringValue = (row + 1).formatted()
                cell.textColor = .secondaryLabelColor
                cell.setAccessibilityLabel("Row \(row + 1)")
                return cell
            }
            let index = Int(identifier.rawValue) ?? 0
            let offset = row - firstRow
            let value: Cell = if rows.indices.contains(offset) {
                rows[offset].indices.contains(index) ? rows[offset][index] : Cell(.missing)
            } else {
                Cell(.unloaded)
            }
            cell.stringValue = value.label
            cell.setAccessibilityLabel(column?.title ?? "Column")
            cell.setAccessibilityValue(value.label)
            cell.textColor = value.muted ? .secondaryLabelColor : .labelColor
            return cell
        }

        func tableView(_: NSTableView, didClick tableColumn: NSTableColumn) {
            guard canSort, let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { return }
            onSort?(columns[index])
        }

        @objc func inspectClickedValue() {
            guard let table, (0..<rowCount).contains(table.clickedRow),
                  table.tableColumns.indices.contains(table.clickedColumn),
                  let column = Int(table.tableColumns[table.clickedColumn].identifier.rawValue),
                  columns.indices.contains(column) else { return }
            onInspect?(table.clickedRow, column)
        }

        func inspectSelectedValue() -> Bool {
            guard let table, (0..<rowCount).contains(table.selectedRow) else { return false }
            let preferred = table.tableColumns.indices.contains(table.clickedColumn)
                ? Int(table.tableColumns[table.clickedColumn].identifier.rawValue) : nil
            let first = table.tableColumns.lazy.compactMap { Int($0.identifier.rawValue) }.first
            guard let column = preferred ?? first, columns.indices.contains(column), let onInspect else { return false }
            onInspect(table.selectedRow, column)
            return true
        }
    }
}
