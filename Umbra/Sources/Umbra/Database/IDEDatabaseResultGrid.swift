import AppKit
import DatabaseKit
import EditorIntelligence
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
    var engine: DatabaseEngine = .postgres
    var onEdit: ((Int, Int) -> Void)?
    var onError: ((String) -> Void)?
    var stagedCells: Set<IDEDatabasePendingEdits.Position> = []
    var rowProjection: IDEDatabaseLoadedFilter.Matches?
    var onPaste: ((IDEDatabaseGridPaste) -> Void)?
    var deletedRows: Set<Int> = []
    var onRowAction: ((RowAction, [Int]) -> Void)?

    /// What the context menu asks of the staged-change model for the selected rows.
    enum RowAction { case insert, duplicate, delete, revert }

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
        table.selectCell = { [weak coordinator = context.coordinator] in
            coordinator?.selectCell(row: $0, column: $1, extend: $2) ?? false
        }
        table.moveCell = { [weak coordinator = context.coordinator] in
            coordinator?.moveSelection(row: $0, column: $1, extend: $2) ?? false
        }
        table.copySelection = { [weak coordinator = context.coordinator] in coordinator?.copySelection(as: .tsv) }
        table.pasteSelection = { [weak coordinator = context.coordinator] in coordinator?.pasteSelection() ?? false }
        table.editSelection = { [weak coordinator = context.coordinator] in coordinator?.editSelectedValue() ?? false }
        table.clearCells = { [weak coordinator = context.coordinator] in coordinator?.clearCellSelection() }
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
        table.menu = context.coordinator.makeMenu()
        table.headerView?.menu = context.coordinator.makeColumnMenu()
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
                                   canSort: canSort, onSort: onSort, onInspect: onInspect,
                                   engine: engine, onEdit: onEdit, onError: onError, stagedCells: stagedCells,
                                   rowProjection: rowProjection, onPaste: onPaste)
        context.coordinator.updateRows(deleted: deletedRows, onRowAction: onRowAction)
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
        var selectCell: ((Int, Int, Bool) -> Bool)?
        var moveCell: ((Int, Int, Bool) -> Bool)?
        var editSelection: (() -> Bool)?
        var copySelection: (() -> Void)?
        var pasteSelection: (() -> Bool)?
        var clearCells: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point)
            let column = column(at: point)
            if event.modifierFlags.contains(.command) || column <= 0 || row < 0 {
                clearCells?()
                super.mouseDown(with: event)
                return
            }
            if selectCell?(row, column, event.modifierFlags.contains(.shift)) == true {
                window?.makeFirstResponder(self)
                if event.clickCount > 1 { _ = inspectSelection?() }
                return
            }
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let extend = event.modifierFlags.contains(.shift)
            let handled: Bool?
            switch event.specialKey {
            case .leftArrow: handled = moveCell?(0, -1, extend)
            case .rightArrow: handled = moveCell?(0, 1, extend)
            case .upArrow: handled = moveCell?(-1, 0, extend)
            case .downArrow: handled = moveCell?(1, 0, extend)
            default:
                handled = event.charactersIgnoringModifiers == "\r" ? editSelection?() : nil
            }
            if handled != true { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers == "i",
               inspectSelection?() == true { return true }
            if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers == "c" {
                copySelection?()
                return true
            }
            if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers == "v",
               pasteSelection?() == true { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
        private struct Position {
            let row: Int
            let column: Int
        }
        private struct Viewport: Equatable {
            let rows: Range<Int>
            let columns: [Int]
        }
        private static let rowNumber = NSUserInterfaceItemIdentifier("rowNumber")
        private let rowPadding = 48
        /// Columns read beyond each side of the viewport, and how close to the edge of those a scroll may get.
        private static let columnPadding = 6
        private static let columnLookahead = 3
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
        private var cachedColumns: [Int: Int] = [:]
        private var requestedViewport: Viewport?
        private var readTask: Task<Void, Never>?
        private var lastReveal: UUID?
        private var anchor: Position?
        private var endpoint: Position?
        private var engine: DatabaseEngine = .postgres
        private var onEdit: ((Int, Int) -> Void)?
        private var onError: ((String) -> Void)?
        private var copyTask: Task<Void, Never>?
        private var stagedCells: Set<IDEDatabasePendingEdits.Position> = []
        private var rowProjection: IDEDatabaseLoadedFilter.Matches?
        private var onPaste: ((IDEDatabaseGridPaste) -> Void)?
        private var deletedRows: Set<Int> = []
        private var onRowAction: ((RowAction, [Int]) -> Void)?

        func updateRows(deleted: Set<Int>, onRowAction: ((RowAction, [Int]) -> Void)?) {
            self.onRowAction = onRowAction
            guard deleted != deletedRows else { return }
            deletedRows = deleted
            redrawSelection()
        }

        private func sourceRow(_ row: Int) -> Int { rowProjection?.indices[row] ?? row }

        func reveal(_ request: Reveal?) {
            guard let request, request.id != lastReveal, let table else { return }
            let row: Int
            if let rowProjection {
                guard let match = rowProjection.indices.firstIndex(of: request.row) else { return }
                row = match
            } else {
                guard (0..<rowCount).contains(request.row) else { return }
                row = request.row
            }
            lastReveal = request.id
            clearCellSelection()
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
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
            copyTask?.cancel()
            NotificationCenter.default.removeObserver(self)
            storage = nil
            table = nil
        }

        func update(
            storage: IDEDatabaseResultStorage, columns: [String], rowCount: Int, canSort: Bool,
            onSort: @escaping (String) -> Void, onInspect: @escaping (Int, Int) -> Void,
            engine: DatabaseEngine = .postgres, onEdit: ((Int, Int) -> Void)? = nil,
            onError: ((String) -> Void)? = nil, stagedCells: Set<IDEDatabasePendingEdits.Position> = [],
            rowProjection: IDEDatabaseLoadedFilter.Matches? = nil, onPaste: ((IDEDatabaseGridPaste) -> Void)? = nil
        ) {
            guard let table else { return }
            self.onSort = onSort
            self.onInspect = onInspect
            self.engine = engine
            self.onEdit = onEdit
            self.onError = onError
            self.onPaste = onPaste
            let stagedChanged = self.stagedCells != stagedCells
            self.stagedCells = stagedCells
            self.canSort = canSort
            let changedResult = self.storage != storage
            let changedProjection = self.rowProjection?.id != rowProjection?.id
            self.rowProjection = rowProjection
            let displayCount = rowProjection?.indices.count ?? rowCount
            if changedResult || changedProjection {
                readTask?.cancel()
                copyTask?.cancel()
                anchor = nil
                endpoint = nil
                requestedViewport = nil
                rows.removeAll()
                cachedColumns.removeAll()
                firstRow = 0
                self.storage = storage
                self.rowCount = displayCount
                table.deselectAll(nil)
                table.toolTip = nil
                clip?.scroll(to: .zero)
            }
            if changedResult || self.columns != columns {
                updateColumns(columns, reset: changedResult, in: table)
            }
            if changedResult || changedProjection {
                table.reloadData()
            } else if self.rowCount != displayCount {
                self.rowCount = displayCount
                table.noteNumberOfRowsChanged()
            }
            for column in table.tableColumns where column.identifier != Self.rowNumber {
                let index = Int(column.identifier.rawValue) ?? 0
                column.headerToolTip = canSort && columns.indices.contains(index) ? "Sort by \(columns[index])" : nil
            }
            visibleBoundsChanged()
            if stagedChanged { redrawSelection() }
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

        /// Whether a loaded window leaves enough rows and columns beyond the viewport that a smooth
        /// scroll will not outrun it before the next read lands. The refill starts while the
        /// viewport is still inside the cache, which is what keeps placeholders off the screen.
        private func covers(
            rows loaded: Range<Int>, columns: Set<Int>, visibleRows: Range<Int>, nearColumns: [Int]
        ) -> Bool {
            let wantedLower = max(0, visibleRows.lowerBound - rowPadding / 2)
            let wantedUpper = min(rowCount, visibleRows.upperBound + rowPadding / 2)
            return loaded.lowerBound <= wantedLower && wantedUpper <= loaded.upperBound
                && nearColumns.allSatisfy(columns.contains)
        }

        @objc private func visibleBoundsChanged() {
            guard let table, let storage, rowCount > 0 else { return }
            let rect = table.visibleRect
            let visible = table.rows(in: rect)
            guard visible.location != NSNotFound, visible.length > 0, visible.location < rowCount else { return }
            let lastVisible = min(rowCount, NSMaxRange(visible))
            let positions = table.columnIndexes(in: rect)
            guard let firstColumn = positions.first, let lastColumn = positions.last else { return }
            func identifier(_ position: Int) -> Int? {
                table.tableColumns.indices.contains(position) ? Int(table.tableColumns[position].identifier.rawValue) : nil
            }
            guard positions.contains(where: { identifier($0) != nil }) else { return }
            let visibleColumns = positions.compactMap(identifier)
            let nearColumns = ((firstColumn - Self.columnLookahead)...(lastColumn + Self.columnLookahead)).compactMap(identifier)
            let wantedColumns = ((firstColumn - Self.columnPadding)...(lastColumn + Self.columnPadding)).compactMap(identifier)
            let visibleRows = visible.location..<lastVisible
            if covers(rows: firstRow..<(firstRow + rows.count), columns: Set(cachedColumns.keys),
                      visibleRows: visibleRows, nearColumns: nearColumns) {
                readTask?.cancel()
                requestedViewport = nil
                return
            }
            let range = max(0, visible.location - rowPadding)..<min(rowCount, lastVisible + rowPadding)
            if let requestedViewport,
               covers(rows: requestedViewport.rows, columns: Set(requestedViewport.columns),
                      visibleRows: visibleRows, nearColumns: nearColumns) { return }
            readTask?.cancel()
            let viewport = Viewport(rows: range, columns: wantedColumns)
            requestedViewport = viewport
            let sourceIndices = rowProjection.map { Array($0.indices[range]) }
            // A refill that starts while every visible cell is still cached has time to spare and
            // goes straight out. Only a read for cells that are on screen and not loaded waits to
            // coalesce a fast drag before the store decodes a spilled chunk, and then only briefly.
            let visibleIsCached = firstRow <= visible.location && lastVisible <= firstRow + rows.count
                && visibleColumns.allSatisfy { cachedColumns[$0] != nil }
            readTask = Task { [weak self] in
                do {
                    if !visibleIsCached { try await Task.sleep(for: .milliseconds(4)) }
                    let project: @Sendable ([DatabaseValue]) -> [Cell] = { row in
                        wantedColumns.map { row.indices.contains($0) ? Cell(row[$0]) : Cell(.missing) }
                    }
                    let loaded: [[Cell]]
                    if let sourceIndices {
                        loaded = try await storage.store.mapRows(at: sourceIndices, project)
                    } else {
                        loaded = try await storage.store.mapRows(in: range, project)
                    }
                    guard let self, !Task.isCancelled, self.storage == storage, requestedViewport == viewport else { return }
                    requestedViewport = nil
                    firstRow = range.lowerBound
                    rows = loaded
                    cachedColumns = Dictionary(uniqueKeysWithValues: wantedColumns.enumerated().map { ($0.element, $0.offset) })
                    refreshVisibleCells(in: range)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.storage == storage, requestedViewport == viewport else { return }
                    requestedViewport = nil
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
            // NSTableView builds a row's cells for every column when the row appears, so cells just
            // off screen were made as placeholders before this read landed. Refresh every cached
            // column, not only the visible ones, or they stay blank when scrolled into view.
            var positions = IndexSet()
            for (position, column) in table.tableColumns.enumerated() {
                if let id = Int(column.identifier.rawValue), cachedColumns[id] != nil { positions.insert(position) }
            }
            table.reloadData(forRowIndexes: IndexSet(integersIn: lower..<upper), columnIndexes: positions)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            columnIndex > 0 && newColumnIndex != 0
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = column?.identifier, (0..<rowCount).contains(row) else { return nil }
            let source = sourceRow(row)
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
            cell.drawsBackground = false
            if identifier == Self.rowNumber {
                cell.stringValue = (source + 1).formatted()
                cell.textColor = .secondaryLabelColor
                cell.setAccessibilityLabel("Row \(source + 1)")
                return cell
            }
            let index = Int(identifier.rawValue) ?? 0
            let offset = row - firstRow
            let value: Cell = if rows.indices.contains(offset), let cached = cachedColumns[index],
                                 rows[offset].indices.contains(cached) {
                rows[offset][cached]
            } else {
                Cell(.unloaded)
            }
            let staged = stagedCells.contains(.init(row: source, column: index))
            let deleted = deletedRows.contains(source)
            cell.stringValue = staged ? "• " + value.label : value.label
            cell.setAccessibilityLabel(column?.title ?? "Column")
            cell.setAccessibilityValue(deleted ? "\(value.label), staged for deletion"
                                       : staged ? "\(value.label), staged edit" : value.label)
            cell.textColor = deleted ? .systemRed : value.muted ? .secondaryLabelColor : .labelColor
            if deleted {
                cell.attributedStringValue = NSAttributedString(string: cell.stringValue, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                ])
            }
            if let anchor, let endpoint, inSelection(row, anchor.row, endpoint.row),
               let column, inSelection(tableView.column(withIdentifier: column.identifier), anchor.column, endpoint.column) {
                cell.drawsBackground = true
                cell.backgroundColor = .selectedContentBackgroundColor.withAlphaComponent(0.24)
                cell.setAccessibilityValue(staged ? "\(value.label), staged edit, selected" : "\(value.label), selected")
            }
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
            onInspect?(sourceRow(table.clickedRow), column)
        }

        func inspectSelectedValue() -> Bool {
            if let (row, column) = selectedValue() {
                onInspect?(row, column)
                return true
            }
            return false
        }

        func editSelectedValue() -> Bool {
            guard let (row, column) = selectedValue(), let onEdit else { return false }
            onEdit(row, column)
            return true
        }

        private func selectedValue() -> (Int, Int)? {
            if let endpoint, let table, table.tableColumns.indices.contains(endpoint.column),
               let column = Int(table.tableColumns[endpoint.column].identifier.rawValue) {
                return (sourceRow(endpoint.row), column)
            }
            guard let table, (0..<rowCount).contains(table.selectedRow) else { return nil }
            let preferred = table.tableColumns.indices.contains(table.clickedColumn)
                ? Int(table.tableColumns[table.clickedColumn].identifier.rawValue) : nil
            let first = table.tableColumns.lazy.compactMap { Int($0.identifier.rawValue) }.first
            guard let column = preferred ?? first, columns.indices.contains(column) else { return nil }
            return (sourceRow(table.selectedRow), column)
        }

        func selectCell(row: Int, column: Int, extend: Bool) -> Bool {
            guard let table, (0..<rowCount).contains(row), column > 0, table.tableColumns.indices.contains(column),
                  !table.tableColumns[column].isHidden else { return false }
            let position = Position(row: row, column: column)
            if !extend || anchor == nil { anchor = position }
            endpoint = position
            table.deselectAll(nil)
            redrawSelection()
            return true
        }

        func moveSelection(row: Int, column: Int, extend: Bool) -> Bool {
            guard let table, rowCount > 0 else { return false }
            let available = table.tableColumns.indices.filter { $0 > 0 && !table.tableColumns[$0].isHidden }
            guard let first = available.first else { return false }
            if endpoint == nil, column == 0 { return false }
            let current = endpoint ?? Position(row: max(table.selectedRow, 0), column: first)
            let toRow = min(rowCount - 1, max(0, current.row + row))
            let index = available.firstIndex(of: current.column) ?? 0
            let toColumn = available[min(available.count - 1, max(0, index + column))]
            guard selectCell(row: toRow, column: toColumn, extend: extend) else { return false }
            table.scrollRowToVisible(toRow)
            table.scrollColumnToVisible(toColumn)
            return true
        }

        func clearCellSelection() {
            guard anchor != nil else { return }
            anchor = nil
            endpoint = nil
            redrawSelection()
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            clearCellSelection()
            visibleBoundsChanged()
        }

        func tableViewColumnDidResize(_ notification: Notification) { visibleBoundsChanged() }

        private func redrawSelection() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0,
                  visible.location < min(NSMaxRange(visible), rowCount) else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<min(NSMaxRange(visible), rowCount)),
                             columnIndexes: table.columnIndexes(in: table.visibleRect))
        }

        private func inSelection(_ value: Int, _ first: Int, _ last: Int) -> Bool {
            (min(first, last)...max(first, last)).contains(value)
        }

        func makeMenu() -> NSMenu {
            func item(_ title: String, _ action: Selector) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                return item
            }
            let menu = NSMenu()
            menu.addItem(item("Inspect Value", #selector(inspectFromMenu)))
            menu.addItem(item("Edit Value…", #selector(editFromMenu)))
            menu.addItem(item("Paste and Stage Cells", #selector(pasteFromMenu)))
            menu.addItem(.separator())
            menu.addItem(item("New Row…", #selector(insertRowFromMenu)))
            menu.addItem(item("Duplicate Row…", #selector(duplicateRowFromMenu)))
            menu.addItem(item("Delete Row", #selector(deleteRowsFromMenu)))
            menu.addItem(item("Revert Row Changes", #selector(revertRowsFromMenu)))
            menu.addItem(.separator())
            for (index, format) in IDEDatabaseGridCopy.allCases.enumerated() {
                let option = item("Copy as \(format.rawValue)", #selector(copyFromMenu(_:)))
                option.tag = index
                menu.addItem(option)
            }
            menu.addItem(.separator())
            menu.addItem(item("Autosize Columns to Visible Values", #selector(autosizeColumns)))
            return menu
        }

        func makeColumnMenu() -> NSMenu {
            let menu = NSMenu(title: "Result Columns")
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            menu.removeAllItems()
            let autosize = NSMenuItem(title: "Autosize Columns", action: #selector(autosizeColumns), keyEquivalent: "")
            autosize.target = self
            menu.addItem(autosize)
            menu.addItem(.separator())
            for column in table.tableColumns where column.identifier != Self.rowNumber {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.state = column.isHidden ? .off : .on
                item.representedObject = column.identifier.rawValue
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ item: NSMenuItem) {
            guard let table, let identifier = item.representedObject as? String,
                  let column = table.tableColumn(withIdentifier: .init(identifier)) else { return }
            column.isHidden.toggle()
            clearCellSelection()
            visibleBoundsChanged()
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case #selector(editFromMenu): return onEdit != nil && (table?.clickedRow ?? -1) >= 0
            case #selector(pasteFromMenu): return onPaste != nil && pasteStart() != nil
            case #selector(insertRowFromMenu): return onRowAction != nil
            case #selector(duplicateRowFromMenu), #selector(deleteRowsFromMenu), #selector(revertRowsFromMenu):
                return onRowAction != nil && !targetRows().isEmpty
            case #selector(copyFromMenu(_:)):
                return IDEDatabaseGridCopy.allCases[item.tag] != .sql || engine != .mongo
            default: return true
            }
        }

        @objc private func inspectFromMenu() {
            if !inspectSelectedValue() { inspectClickedValue() }
        }

        @objc private func editFromMenu() {
            if editSelectedValue() { return }
            guard let table, (0..<rowCount).contains(table.clickedRow), table.tableColumns.indices.contains(table.clickedColumn),
                  let column = Int(table.tableColumns[table.clickedColumn].identifier.rawValue) else { return }
            onEdit?(sourceRow(table.clickedRow), column)
        }

        @objc private func pasteFromMenu() { _ = pasteSelection() }

        /// The rows a row command applies to: the selected cell rectangle's rows, else the clicked row.
        private func targetRows() -> [Int] {
            if let anchor, let endpoint {
                return (min(anchor.row, endpoint.row)...max(anchor.row, endpoint.row)).map(sourceRow)
            }
            guard let table, (0..<rowCount).contains(table.clickedRow) else { return [] }
            return [sourceRow(table.clickedRow)]
        }

        @objc private func insertRowFromMenu() { onRowAction?(.insert, []) }
        @objc private func duplicateRowFromMenu() { onRowAction?(.duplicate, targetRows()) }
        @objc private func deleteRowsFromMenu() { onRowAction?(.delete, targetRows()) }
        @objc private func revertRowsFromMenu() { onRowAction?(.revert, targetRows()) }

        private func pasteStart() -> Position? {
            if let anchor, let endpoint {
                return Position(row: min(anchor.row, endpoint.row), column: min(anchor.column, endpoint.column))
            }
            guard let table, (0..<rowCount).contains(table.clickedRow), table.clickedColumn > 0 else { return nil }
            return Position(row: table.clickedRow, column: table.clickedColumn)
        }

        func pasteSelection() -> Bool {
            guard let onPaste else { return false }
            guard let table, let start = pasteStart(), table.tableColumns.indices.contains(start.column) else {
                onError?("Select the top-left destination cell before pasting.")
                return true
            }
            let board = NSPasteboard.general
            let csv = NSPasteboard.PasteboardType("public.comma-separated-values-text")
            let source: (String, Character)?
            if let tsv = board.string(forType: .tabularText) { source = (tsv, "\t") }
            else if let comma = board.string(forType: csv) { source = (comma, ",") }
            else if let text = board.string(forType: .string) { source = (text, "\t") }
            else { source = nil }
            guard let (text, delimiter) = source else {
                onError?("Copy spreadsheet cells or tab-separated text first.")
                return true
            }
            let destinationRows = (start.row..<min(rowCount, start.row + IDEDatabasePendingEdits.limit)).map(sourceRow)
            let destinationColumns = table.tableColumns[start.column...].lazy.filter { !$0.isHidden }
                .compactMap { Int($0.identifier.rawValue) }.prefix(IDEDatabasePendingEdits.limit)
            onPaste(.init(text: text, delimiter: delimiter, sourceRows: destinationRows, columns: Array(destinationColumns)))
            return true
        }

        @objc private func copyFromMenu(_ item: NSMenuItem) {
            copySelection(as: IDEDatabaseGridCopy.allCases[item.tag])
        }

        func copySelection(as format: IDEDatabaseGridCopy) {
            guard let table, let storage else { return }
            let positions: [Int]
            let selectedRows: IndexSet
            if let anchor, let endpoint {
                positions = Array(min(anchor.column, endpoint.column)...max(anchor.column, endpoint.column))
                selectedRows = IndexSet(integersIn: min(anchor.row, endpoint.row)..<(max(anchor.row, endpoint.row) + 1))
            } else if !table.selectedRowIndexes.isEmpty {
                positions = Array(table.tableColumns.indices)
                selectedRows = table.selectedRowIndexes
            } else if table.clickedRow >= 0, table.clickedColumn > 0 {
                positions = [table.clickedColumn]
                selectedRows = IndexSet(integer: table.clickedRow)
            } else {
                return
            }
            guard selectedRows.count <= IDEDatabaseGridCopy.rowLimit else {
                onError?("Select fewer rows to copy.")
                return
            }
            let sourceRows = rowProjection == nil ? selectedRows : IndexSet(selectedRows.map(sourceRow))
            let selectedColumns = positions.compactMap { index -> Int? in
                guard table.tableColumns.indices.contains(index), !table.tableColumns[index].isHidden else { return nil }
                return Int(table.tableColumns[index].identifier.rawValue)
            }
            let engine = self.engine
            copyTask?.cancel()
            copyTask = Task { [weak self] in
                do {
                    let text = try await runDetached {
                        try await format.text(from: storage.store, rows: sourceRows, columns: selectedColumns, engine: engine)
                    }
                    guard self?.storage == storage, !Task.isCancelled else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } catch {
                    if !Task.isCancelled { self?.onError?(error.localizedDescription) }
                }
            }
        }

        @objc private func autosizeColumns() {
            guard let table else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            for column in table.tableColumns {
                guard let index = Int(column.identifier.rawValue), !column.isHidden else { continue }
                var width = (column.title as NSString).size(withAttributes: attributes).width
                if let cached = cachedColumns[index] {
                    for row in rows where row.indices.contains(cached) {
                        width = max(width, (row[cached].label as NSString).size(withAttributes: attributes).width)
                    }
                }
                column.width = min(460, max(column.minWidth, width + 18))
            }
        }
    }
}
