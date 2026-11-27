import AppKit
import DatabaseKit
import EditorIntelligence
import SwiftUI

/// The active console's stored results, inspector, and bounded preview export.
struct IDEDatabaseResultView: View {
    let support: IDEDatabaseSupport
    var consoleID: UUID? = nil
    var runChartQuery: ((String, IDEDatabaseConsoleBinding) -> Void)?
    var runResultQuery: ((IDEDatabaseResultQuery) -> Void)?
    @State private var showsNotices = false
    @State private var pendingSort: PendingSort?
    @State private var inspectedValue: IDEDatabaseInspectedValue?
    @State private var inspectionTask: Task<Void, Never>?
    @State private var fullValueTask: Task<Void, Never>?
    @State private var isLoadingFull = false
    @State private var fullValueError: String?
    @State private var visualization: IDEDatabaseVisualizationSource?
    @State private var reveal: IDEDatabaseResultGrid.Reveal?
    @State private var editDraft: IDEDatabaseCellEditDraft?
    @State private var insertDraft: InsertDraft?
    @State private var showsMutationPreview = false
    @State private var actionMessage: String?
    @State private var presentation = IDEDatabasePresentationMode.table
    @State private var showsLoadedFilter = false
    @State private var serverFilter: ServerFilterPresentation?
    @State private var loadedFilter: IDEDatabaseLoadedFilter?
    @State private var filteredStorage: IDEDatabaseResultStorage?
    @State private var loadedMatches: IDEDatabaseLoadedFilter.Matches?
    @State private var filterTask: Task<Void, Never>?
    @State private var pasteTask: Task<Void, Never>?
    @State private var isFiltering = false

    private var results: IDEDatabaseResultSet { support.resultSet(for: consoleID) }
    private var result: IDEDatabaseResult { results.result }
    private var rowProjection: IDEDatabaseLoadedFilter.Matches? {
        filteredStorage == result.storage ? loadedMatches : nil
    }
    private var matchesScope: Bool {
        guard let id = result.connectionID else { return false }
        return result.scopeRevision == support.scopeRevisions[id] && support.switchingSQLSourceID == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let actionMessage {
                Text(actionMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
            }
            filterStatus
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
                    if presentation == .table {
                        grid(storage)
                    } else {
                        IDEDatabaseStoredPresentation(storage: storage, mode: presentation, availableRows: result.rowCount) { row in
                            revealRow(row)
                        }
                        .id(presentation)
                    }
                } secondary: {
                    if let inspectedValue {
                        VStack(spacing: 0) {
                            IDEDatabaseValueInspector(
                                value: inspectedValue,
                                canLoadFull: result.rowSource != nil && matchesScope && !support.isRunning,
                                isLoading: isLoadingFull, error: fullValueError,
                                onLoadFull: loadFullValue, onShowStored: showStoredValue, onClose: clearInspection)
                            if result.rowSource != nil, result.rowSource?.engine != .mongo, matchesScope, let runResultQuery {
                                IDEDatabaseRelatedRows {
                                    try await support.relatedRows(in: result, row: inspectedValue.row, columnIndex: inspectedValue.columnIndex)
                                } run: { query in
                                    runResultQuery(query)
                                } follow: { query in
                                    Task { await support.followRelation(query, consoleID: consoleID) }
                                }
                                .id(inspectedValue.row.description + inspectedValue.column.name)
                                .padding(IDEAppearance.Spacing.sm)
                            }
                        }
                    }
                }
                .overlay {
                    if rowProjection?.indices.isEmpty == true {
                        ContentUnavailableView("No Matching Rows", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Try different text or clear the loaded-row filter."))
                            .allowsHitTesting(false)
                    } else if result.rowCount == 0, result.hasCompleteRows {
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
            editDraft = nil
            insertDraft = nil
            showsMutationPreview = false
            serverFilter = nil
            actionMessage = nil
            clearLoadedFilter()
            pasteTask?.cancel()
            clearInspection()
        }
        .onChange(of: presentation) {
            if presentation != .table { clearLoadedFilter() }
        }
        .onChange(of: matchesScope) {
            pendingSort = nil
            visualization = nil
            serverFilter = nil
        }
        .sheet(item: $visualization) { source in
            IDEDatabaseVisualizationSheet(source: source, query: chartQuery, runQuery: runChartQuery.map { run in
                { sql, binding in
                    visualization = nil
                    run(sql, binding)
                }
            }) { row in
                guard support.resultSet(for: consoleID).result.storage == source.storage else { return }
                revealRow(row)
                visualization = nil
            }
        }
        .sheet(item: $editDraft) { draft in
            if let pending = result.pendingEdits {
                let existing = pending.edits[.init(row: draft.row, column: draft.column.index)]?.replacement
                IDEDatabaseCellEditSheet(draft: draft, existing: existing, allowsClock: pending.target.allowsExpressions, revert: existing == nil ? nil : { row in
                    pending.revert(row: draft.row, column: row ? nil : draft.column.index)
                }) { value in
                    try pending.stage(draft, replacement: value)
                }
            }
        }
        .sheet(item: $insertDraft) { draft in
            if let pending = result.pendingEdits {
                IDEDatabaseInsertSheet(title: draft.title, columns: pending.target.insertColumns, initial: draft.initial) { fields in
                    try pending.stageInsertion(fields)
                }
            }
        }
        .sheet(isPresented: $showsMutationPreview) {
            if let pending = result.pendingEdits, let storage = result.storage,
               let id = result.connectionID, let connection = support.catalog.connection(id: id) {
                IDEDatabaseMutationPreview(pending: pending, sourceName: connection.name, production: connection.isProduction == true,
                    inTransaction: support.sqlTransactions[id]?.isOpen == true,
                    submit: { try await support.submitEdits(pending, storage: storage, consoleID: consoleID) },
                    cancelSubmission: { Task { await support.cancelRunning() } })
            }
        }
        .sheet(item: $serverFilter) { item in
            IDEDatabaseServerFilterEditor(source: item.source) { query in
                guard support.resultSet(for: consoleID).result.storage == item.storage else { return }
                runResultQuery?(query)
            }
        }
        .onExitCommand { if inspectedValue != nil { clearInspection() } }
        .onDisappear {
            filterTask?.cancel()
            filterTask = nil
            isFiltering = false
            pasteTask?.cancel()
            clearInspection()
        }
    }

    private func revealRow(_ row: Int) {
        presentation = .table
        if let rowProjection, !rowProjection.indices.contains(row) { clearLoadedFilter() }
        reveal = .init(row: row)
    }

    private func grid(_ storage: IDEDatabaseResultStorage) -> some View {
        let pending = result.pendingEdits
        let edit: ((Int, Int) -> Void)?
        let paste: ((IDEDatabaseGridPaste) -> Void)?
        let rowAction: ((IDEDatabaseResultGrid.RowAction, [Int]) -> Void)?
        if pending?.isLocal == true, !support.isRunning, matchesScope {
            edit = { row, column in editValue(row: row, column: column) }
            paste = stagePaste
            rowAction = pending?.target.allowsRowChanges == true ? { action, rows in performRowAction(action, rows: rows) } : nil
        } else {
            edit = nil
            paste = nil
            rowAction = nil
        }
        let canSort = result.canSort && !support.isRunning && matchesScope && pending?.hasChanges != true
        let staged = Set(pending?.edits.keys.map { $0 } ?? [])
        return IDEDatabaseResultGrid(storage: storage, columns: result.columns, rowCount: result.rowCount,
                                     canSort: canSort, onSort: previewSort, onInspect: inspect, reveal: reveal,
                                     engine: result.engine, onEdit: edit, onError: { actionMessage = $0 },
                                     stagedCells: staged, rowProjection: rowProjection, onPaste: paste,
                                     deletedRows: pending?.deletedRows ?? [], onRowAction: rowAction)
    }

    private struct InsertDraft: Identifiable {
        let id = UUID()
        let title: String
        let initial: [SQLiteInsert.Field]
    }

    private func performRowAction(_ action: IDEDatabaseResultGrid.RowAction, rows: [Int]) {
        guard let storage = result.storage, let pending = result.pendingEdits, pending.isLocal else { return }
        let target = pending.target
        switch action {
        case .insert:
            actionMessage = nil
            insertDraft = InsertDraft(title: "New Row", initial: [])
        case .revert:
            for row in rows { pending.revert(row: row) }
        case .duplicate:
            guard let row = rows.first else { return }
            Task {
                do {
                    let columns = await storage.store.snapshot.columns
                    let values = try await storage.store.mapRows(in: row..<(row + 1)) { $0 }
                    guard support.resultSet(for: consoleID).result.storage == storage, let first = values.first else { return }
                    actionMessage = nil
                    insertDraft = InsertDraft(title: "Duplicate Row \((row + 1).formatted())",
                                              initial: target.duplicate(values: first, columns: columns))
                } catch { actionMessage = error.localizedDescription }
            }
        case .delete:
            let rows = Array(rows.prefix(IDEDatabasePendingEdits.limit))
            Task {
                do {
                    let values = try await storage.store.mapRows(at: rows) { $0 }
                    guard support.resultSet(for: consoleID).result.storage == storage, pending.isLocal else { return }
                    let deletions = zip(rows, values).compactMap { target.deletion(row: $0, values: $1) }
                    if deletions.count < rows.count {
                        actionMessage = "\((rows.count - deletions.count).formatted()) rows have no complete key and were not staged."
                    } else {
                        actionMessage = nil
                    }
                    try pending.stageDeletions(deletions)
                } catch { actionMessage = error.localizedDescription }
            }
        }
    }

    private func stagePaste(_ paste: IDEDatabaseGridPaste) {
        guard let storage = result.storage, let pending = result.pendingEdits,
              !support.isRunning, matchesScope, pending.isLocal else { return }
        let target = pending.target
        let projection = rowProjection?.id
        pasteTask?.cancel()
        pasteTask = Task {
            do {
                let proposed = try await runDetached { try await paste.edits(from: storage.store, target: target) }
                guard !Task.isCancelled, support.resultSet(for: consoleID).result.storage == storage,
                      rowProjection?.id == projection, presentation == .table,
                      !support.isRunning, matchesScope else { return }
                let count = try pending.stage(proposed)
                actionMessage = count == 0 ? "The clipboard values match the destination cells." :
                    "Staged \(count.formatted()) cells. Review the changes before committing."
            } catch {
                if !Task.isCancelled { actionMessage = error.localizedDescription }
            }
        }
    }

    private func applyLoadedFilter(_ filter: IDEDatabaseLoadedFilter) {
        guard let storage = result.storage else { return }
        filterTask?.cancel()
        isFiltering = true
        actionMessage = nil
        presentation = .table
        filterTask = Task {
            do {
                let matches = try await runDetached { try await filter.apply(to: storage.store) }
                guard !Task.isCancelled, support.resultSet(for: consoleID).result.storage == storage, presentation == .table else { return }
                loadedFilter = filter
                filteredStorage = storage
                loadedMatches = matches
                isFiltering = false
                clearInspection()
            } catch {
                if !Task.isCancelled {
                    isFiltering = false
                    actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func clearLoadedFilter() {
        filterTask?.cancel()
        filterTask = nil
        isFiltering = false
        loadedFilter = nil
        filteredStorage = nil
        loadedMatches = nil
    }

    @ViewBuilder private var filterStatus: some View {
        if isFiltering || rowProjection != nil {
            HStack {
                if isFiltering {
                    ProgressView().controlSize(.small)
                    Text("Filtering loaded rows…")
                } else if let rowProjection {
                    let prefix = rowProjection.reachedMatchLimit ? "First " : ""
                    Text("\(prefix)\(rowProjection.indices.count.formatted()) matches · \(rowProjection.loadedRows.formatted()) loaded rows")
                }
                Spacer()
                Button(isFiltering ? "Cancel Filter" : "Clear Filter", action: clearLoadedFilter)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
    }

    private func editValue(row: Int, column: Int) {
        guard let storage = result.storage, let pending = result.pendingEdits,
              !support.isRunning, matchesScope, pending.isLocal else { return }
        let target = pending.target
        Task {
            do {
                let drafts = try await storage.store.mapRows(in: row..<(row + 1)) {
                    target.draft(row: row, column: column, values: $0)
                }
                guard support.resultSet(for: consoleID).result.storage == storage, !support.isRunning else { return }
                guard let first = drafts.first, let draft = first else {
                    actionMessage = target.lockedReason(forColumn: column)
                        ?? "Identity columns, generated columns, and values without complete stored data cannot be edited."
                    return
                }
                actionMessage = nil
                editDraft = draft
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private var chartQuery: IDEDatabaseChartQuery? {
        guard let connectionID = result.connectionID, result.engine != .mongo,
              !support.isRunning, result.canSort, matchesScope else { return nil }
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
                let inspected = await runDetached {
                    var inspected = IDEDatabaseInspectedValue(row: row, column: field, cell: value)
                    inspected.columnIndex = column
                    return inspected
                }
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
        fullValueTask?.cancel()
        fullValueTask = nil
        isLoadingFull = false
        fullValueError = nil
        inspectedValue = nil
    }

    /// Re-reads the one value by the row's verified key. The result keeps its stored preview and
    /// the inspector labels what it now shows as live.
    private func loadFullValue() {
        guard let current = inspectedValue, current.isPartial, !isLoadingFull,
              let storage = result.storage else { return }
        let snapshot = result
        isLoadingFull = true
        fullValueError = nil
        fullValueTask?.cancel()
        fullValueTask = Task {
            defer { isLoadingFull = false }
            do {
                let cell = try await support.fetchFullValue(in: snapshot, row: current.row, column: current.columnIndex)
                guard !Task.isCancelled, support.resultSet(for: consoleID).result.storage == storage,
                      inspectedValue?.row == current.row, inspectedValue?.columnIndex == current.columnIndex else { return }
                inspectedValue = IDEDatabaseInspectedValue(live: cell, replacing: current)
            } catch {
                if !Task.isCancelled { fullValueError = error.localizedDescription }
            }
        }
    }

    private func showStoredValue() {
        guard let current = inspectedValue, let stored = current.storedCell else { return }
        var restored = IDEDatabaseInspectedValue(row: current.row, column: current.column, cell: stored)
        restored.columnIndex = current.columnIndex
        fullValueError = nil
        inspectedValue = restored
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let history = support.navigationHistory(for: consoleID), history.entries.count > 1 {
                IDEIconButton(systemImage: "chevron.left", help: history.backTitle.map { "Back to \($0)" } ?? "Back",
                              isDisabled: !history.canGoBack || support.isRunning) {
                    Task { await support.navigateHistory(by: -1, consoleID: consoleID) }
                }
                IDEIconButton(systemImage: "chevron.right", help: history.forwardTitle.map { "Forward to \($0)" } ?? "Forward",
                              isDisabled: !history.canGoForward || support.isRunning) {
                    Task { await support.navigateHistory(by: 1, consoleID: consoleID) }
                }
                Text("\(history.index + 1) of \(history.entries.count)")
                    .font(IDEAppearance.Typography.monoSmall).foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help(history.current?.title ?? "")
            }
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
            editingControls
            filterControls
            IDEIconMenu(systemImage: "rectangle.split.2x1", help: "Result Presentation", isDisabled: result.rowCount == 0) {
                Picker("Result Presentation", selection: $presentation) {
                    ForEach(IDEDatabasePresentationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
            }
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

    private var filterControls: some View {
        IDEIconMenu(systemImage: "line.3.horizontal.decrease.circle", help: "Filter Results",
                    isDisabled: result.columns.isEmpty) {
            Button("Loaded Grid Rows…") { showsLoadedFilter = true }.disabled(result.rowCount == 0)
            if let source = serverFilterSource, let storage = result.storage {
                Button("Filter on Server…") { serverFilter = .init(source: source, storage: storage) }
            }
        }
        .popover(isPresented: $showsLoadedFilter) {
            IDEDatabaseLoadedFilterEditor(columns: result.columns, filter: loadedFilter, onApply: applyLoadedFilter)
        }
    }

    private var serverFilterSource: IDEDatabaseServerFilter? {
        guard runResultQuery != nil, result.engine != .mongo, result.canSort, matchesScope,
              !support.isRunning, let statement = result.preparedStatement, let id = result.connectionID else { return nil }
        return IDEDatabaseServerFilter(statement: statement, columns: result.columns, engine: result.engine,
                                       connectionID: id, scopeRevision: result.scopeRevision)
    }

    private struct ServerFilterPresentation: Identifiable {
        let id = UUID()
        let source: IDEDatabaseServerFilter
        let storage: IDEDatabaseResultStorage
    }

    @ViewBuilder private var editingControls: some View {
        if let pending = result.pendingEdits {
            switch pending.phase {
            case .committed:
                Label("Committed · \(pending.submittedCounts.summary.isEmpty ? "" : pending.submittedCounts.summary + " · ")Rerun to Refresh",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .submitted:
                Label("Submitted to transaction · \(pending.submittedCounts.summary) · not committed", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Applied inside your open transaction. Commit or roll back from the console's transaction menu; the grid shows the rows as loaded.")
            case .rolledBack:
                Label("Rolled back · \(pending.submittedCounts.summary)", systemImage: "arrow.uturn.backward.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Stage Again") { pending.restageRolledBack() }
            case .indeterminate:
                Label("Transaction ended · verify the data", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .help("The transaction ended without a COMMIT or ROLLBACK Umbra ran, so it cannot say whether these changes were kept. Rerun the query to see.")
            case .local:
                if pending.hasChanges {
                    Button("Review \(pending.changeCount.formatted()) Staged") { showsMutationPreview = true }
                        .disabled(support.isRunning || !matchesScope)
                } else {
                    Label("Editable", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Select a cell and press Return to stage an edit. Right-click for rows.")
                }
                IDEIconMenu(systemImage: "ellipsis", help: "Staged Change Actions", isDisabled: support.isRunning) {
                    if pending.target.allowsRowChanges {
                        Button("New Row…") { performRowAction(.insert, rows: []) }
                        Divider()
                    }
                    Button("Undo") { pending.undo() }.disabled(!pending.canUndo)
                    Button("Redo") { pending.redo() }.disabled(!pending.canRedo)
                    if pending.hasChanges {
                        Button("Revert All Changes", role: .destructive) { pending.revertAll() }
                    }
                }
                if !pending.insertions.isEmpty {
                    Text("\(pending.insertions.count.formatted()) new")
                        .font(.caption).foregroundStyle(.green)
                        .help("New rows are listed in the review sheet. They appear in the grid after the query reruns.")
                }
            }
        } else if result.rowCount > 0, !support.isRunning {
            Label("Read Only Result", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .help(result.readOnlyReason ?? "Editing needs a verified source table and row key.")
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
