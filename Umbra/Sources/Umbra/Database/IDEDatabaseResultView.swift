import AppKit
import DatabaseKit
import SwiftUI

/// The page of results for the last statement, with paging and export of that page.
struct IDEDatabaseResultView: View {
    var support: IDEDatabaseSupport

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(IDEAppearance.ColorToken.border)
            if let error = support.result.error {
                Text(error)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(IDEAppearance.Spacing.md)
            } else if support.result.columns.isEmpty {
                Text(support.isRunning ? "Running…" : (support.result.message ?? "Run a query to see results."))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(IDEAppearance.Spacing.md)
            } else {
                IDEDatabaseResultGrid(
                    columns: support.result.columns,
                    rows: support.result.rows,
                    onSort: { column in Task { await support.sort(by: column) } }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.panel)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await support.goToPage(support.result.page - 1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!support.result.canGoBack || support.isRunning)
            Text("Page \(support.result.page + 1)")
                .font(IDEAppearance.Typography.monoSmall)
            Button {
                Task { await support.goToPage(support.result.page + 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!support.result.canGoForward || support.isRunning)
            if let message = support.result.message {
                Text(message)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if support.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Menu("Export") {
                Button("CSV") { export(.csv) }
                Button("TSV") { export(.tsv) }
                Button("JSON") { export(.json) }
            }
            .disabled(support.result.columns.isEmpty)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private enum Format {
        case csv, tsv, json

        var name: String {
            switch self {
            case .csv: "results.csv"
            case .tsv: "results.tsv"
            case .json: "results.json"
            }
        }

        func text(columns: [String], rows: [[String?]]) -> String {
            switch self {
            case .csv: QueryExport.csv(columns: columns, rows: rows)
            case .tsv: QueryExport.tsv(columns: columns, rows: rows)
            case .json: QueryExport.json(columns: columns, rows: rows)
            }
        }
    }

    private func export(_ format: Format) {
        let text = format.text(columns: support.result.columns, rows: support.result.rows)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// A virtualized grid. `nil` cells read as NULL.
struct IDEDatabaseResultGrid: NSViewRepresentable {
    var columns: [String]
    var rows: [[String?]]
    var onSort: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSort: onSort)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.backgroundColor = .clear
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.rowHeight = 20
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSort = onSort
        context.coordinator.rows = rows
        let table = context.coordinator.table
        guard let table else { return }
        if context.coordinator.columnNames != columns {
            context.coordinator.columnNames = columns
            while !table.tableColumns.isEmpty {
                table.removeTableColumn(table.tableColumns[0])
            }
            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.title = name
                column.width = 140
                column.minWidth = 60
                column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                table.addTableColumn(column)
            }
        }
        table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var onSort: (String) -> Void
        var columnNames: [String] = []
        var rows: [[String?]] = []
        weak var table: NSTableView?

        init(onSort: @escaping (String) -> Void) {
            self.onSort = onSort
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
            let index = Int(identifier.rawValue.dropFirst()) ?? 0
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
            let value = row < rows.count && rows[row].indices.contains(index) ? rows[row][index] : nil
            cell.stringValue = value ?? "NULL"
            cell.textColor = value == nil ? .secondaryLabelColor : .labelColor
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let key = tableView.sortDescriptors.first?.key else { return }
            onSort(key)
        }
    }
}
