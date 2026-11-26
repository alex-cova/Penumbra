import AppKit
import DatabaseKit
import EditorIntelligence
import SwiftUI

/// The active console's stored results, inspector, and bounded preview export.
struct IDEDatabaseResultView: View {
    let support: IDEDatabaseSupport
    var consoleID: UUID? = nil
    var runChartQuery: ((String, IDEDatabaseConsoleBinding) -> Void)?
    @State private var showsNotices = false
    @State private var pendingSort: PendingSort?
    @State private var inspectedValue: IDEDatabaseInspectedValue?
    @State private var inspectionTask: Task<Void, Never>?
    @State private var visualization: IDEDatabaseVisualizationSource?
    @State private var reveal: IDEDatabaseResultGrid.Reveal?

    private var results: IDEDatabaseResultSet { support.resultSet(for: consoleID) }
    private var result: IDEDatabaseResult { results.result }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(IDEAppearance.ColorToken.border)
            if let error = result.error {
                Text(error)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(IDEAppearance.Spacing.md)
            } else if result.columns.isEmpty {
                Text(support.isRunning && result.connectionID == support.runningConnectionID
                     ? "Running…" : (result.message ?? "Run a query to see results."))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(IDEAppearance.Spacing.md)
            } else if let storage = result.storage {
                SplitPanes(minPrimary: 200, minSecondary: 180, idealSecondary: 300, priority: .secondary,
                           hiddenSide: inspectedValue == nil ? .secondary : nil) {
                    IDEDatabaseResultGrid(storage: storage, columns: result.columns, rowCount: result.rowCount,
                                          canSort: result.canSort && !support.isRunning, onSort: previewSort,
                                          onInspect: inspect, reveal: reveal)
                } secondary: {
                    if let inspectedValue {
                        IDEDatabaseValueInspector(value: inspectedValue, onClose: clearInspection)
                    }
                }
                .overlay {
                    if result.rowCount == 0, result.hasCompleteRows {
                        ContentUnavailableView("No Rows", systemImage: "tablecells",
                                               description: Text("The statement finished without returning any rows."))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.panel)
        .onChange(of: result.storage) {
            pendingSort = nil
            visualization = nil
            reveal = nil
            clearInspection()
        }
        .sheet(item: $visualization) { source in
            IDEDatabaseVisualizationSheet(source: source, query: chartQuery, runQuery: runChartQuery.map { run in
                { sql, binding in
                    visualization = nil
                    run(sql, binding)
                }
            }) { row in
                guard support.resultSet(for: consoleID).result.storage == source.storage else { return }
                reveal = .init(row: row)
                visualization = nil
            }
        }
        .onDisappear(perform: clearInspection)
    }

    private var chartQuery: IDEDatabaseChartQuery? {
        guard let connectionID = result.connectionID, result.engine != .mongo,
              !support.isRunning, result.canSort else { return nil }
        return IDEDatabaseChartQuery(statement: result.statement, engine: result.engine,
                                     binding: .init(connectionID: connectionID))
    }

    private func inspect(row: Int, column: Int) {
        guard let storage = result.storage, result.columns.indices.contains(column) else { return }
        inspectionTask?.cancel()
        inspectionTask = Task {
            do {
                let values = try await storage.store.mapRows(in: row..<(row + 1)) { cells in
                    cells.indices.contains(column) ? cells[column] : .missing
                }
                let snapshot = await storage.store.snapshot
                guard let value = values.first, snapshot.columns.indices.contains(column),
                      !Task.isCancelled, support.resultSet(for: consoleID).result.storage == storage else { return }
                let field = snapshot.columns[column]
                let inspected = await runDetached { IDEDatabaseInspectedValue(row: row, column: field, cell: value) }
                guard !Task.isCancelled, support.resultSet(for: consoleID).result.storage == storage else { return }
                inspectedValue = inspected
            } catch {
                if !Task.isCancelled { support.banner = error.localizedDescription }
            }
        }
    }

    private func clearInspection() {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectedValue = nil
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if results.scriptResults.count > 1 {
                Menu("Statement \(results.selection + 1) of \(results.scriptResults.count)") {
                    ForEach(results.scriptResults.indices, id: \.self) { index in
                        let statement = results.scriptResults[index].statement
                        Button("\(index + 1). \(statement.prefix(72))") { support.selectScriptResult(index, consoleID: consoleID) }
                    }
                }
                .fixedSize()
                .disabled(support.isRunning)
            }
            if let message = result.message {
                Text(message)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else if !result.columns.isEmpty {
                Text("\(result.rowCount.formatted()) loaded")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let duration = result.duration {
                Text(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if let column = result.sortColumn {
                Label(column, systemImage: result.sortAscending ? "arrow.up" : "arrow.down")
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .help(result.sortAscending ? "Sorted ascending" : "Sorted descending")
            }
            if support.isRunning {
                ProgressView().controlSize(.small)
                IDEIconButton(
                    systemImage: "stop.fill",
                    help: support.isCancelling ? "Cancelling…" : "Cancel Statement",
                    isDisabled: support.isCancelling
                ) {
                    Task { await support.cancelRunning() }
                }
            }
            Spacer(minLength: 0)
            IDEIconButton(systemImage: "chart.xyaxis.line", help: "Visualize Results",
                          isDisabled: result.storage == nil || result.rowCount == 0) {
                if let storage = result.storage {
                    visualization = IDEDatabaseVisualizationSource(
                        storage: storage, columns: result.columns, rowCount: result.rowCount, complete: result.hasCompleteRows
                    )
                }
            }
            if !result.notices.isEmpty {
                Button("Server Messages (\(result.notices.count))", systemImage: "exclamationmark.bubble") {
                    showsNotices.toggle()
                }
                .popover(isPresented: $showsNotices) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                            ForEach(result.notices.enumerated(), id: \.offset) { _, notice in
                                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                                    Text("\(notice.level) \(notice.code)").font(.caption.weight(.semibold))
                                    Text(notice.message).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(IDEAppearance.Spacing.md)
                    }
                    .frame(width: 430, height: 240)
                }
            }
            IDEIconMenu(systemImage: "square.and.arrow.up",
                        help: "Export First \(result.rows.count.formatted()) Rows",
                        isDisabled: result.columns.isEmpty || support.isRunning) {
                Button("CSV") { export(.csv) }
                Button("TSV") { export(.tsv) }
                Button("JSON") { export(.json) }
            }
        }
        .ideIconButtonSize(.compact)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .popover(item: $pendingSort) { request in
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                Text(request.title).font(.headline)
                ScrollView {
                    Text(request.preview)
                        .font(IDEAppearance.Typography.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { pendingSort = nil }
                    Button("Run Sorted Query") {
                        pendingSort = nil
                        Task {
                            guard support.resultSet(for: consoleID).result.storage == request.storage else { return }
                            await support.sort(by: request.column, consoleID: consoleID)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(IDEAppearance.Spacing.md)
            .frame(width: 440, height: 200)
        }
    }

    private struct PendingSort: Identifiable {
        let id = UUID()
        let storage: IDEDatabaseResultStorage
        let column: String
        let title: String
        let preview: String
    }

    private func previewSort(_ column: String) {
        guard let storage = result.storage, let statement = result.preparedStatement else { return }
        let ascending = result.sortColumn != column || !result.sortAscending
        do {
            let preview: String
            if result.engine == .mongo {
                preview = ExtendedJSON.string(BSONDocument([column: .int32(ascending ? 1 : -1)]), mode: .relaxed)
            } else {
                guard let sql = try DatabaseQuery.sortedStatement(statement.sql, column: column,
                                                                  ascending: ascending, engine: result.engine) else { return }
                preview = sql
            }
            pendingSort = PendingSort(storage: storage, column: column, title: "Sort by \(column)", preview: preview)
        } catch {
            support.banner = error.localizedDescription
        }
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
        guard let store = result.storage?.store else { return }
        let count = min(result.rowCount, result.pageSize)
        let columns = result.columns
        let engine = result.engine
        Task {
            do {
                let rows = try await store.mapRows(in: 0..<count) { row in
                    columns.indices.map { index -> String? in
                        guard row.indices.contains(index) else { return nil }
                        let value = row[index]
                        return engine == .mongo && value.isNull ? "null" : value.rawText
                    }
                }
                let text = await runDetached { format.text(columns: columns, rows: rows) }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = format.name
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task {
                        do {
                            try await runDetached { try text.write(to: url, atomically: true, encoding: .utf8) }
                        } catch {
                            support.banner = error.localizedDescription
                        }
                    }
                }
            } catch {
                support.banner = error.localizedDescription
            }
        }
    }
}
