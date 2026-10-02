import Combine
import EditorIntelligence
import Foundation

/// Coordinates async fold-region discovery and batch application to a ``FoldingModel``.
@MainActor
final class CodeFoldingManager {
    let foldingModel: FoldingModel

    var foldingProvider: FoldingProviding = IndentationFoldingProvider()
    var treeSitterFoldingProvider: TreeSitterFoldingProvider?
    var languageIdentifier: String?

    private var foldingEngine: FoldingEngine?
    private var updateTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var needsUpdate = false
    private var pendingFullUpdate = false
    private var pendingDirtyRows: ClosedRange<Int>?
    private var pendingAfterEdit = false
    /// What the unfinished update task covers. A newer update cancels it, so it takes these over.
    private var inFlightFullUpdate = false
    private var inFlightDirtyRows: ClosedRange<Int>?
    private var hasUpdateInFlight = false
    private var contentVersion = 0

    /// Idle time after an edit before the document is snapshotted and rescanned. Snapshotting
    /// materializes the whole text and the providers walk the whole document, so neither may run
    /// per keystroke.
    static let editDebounceNanoseconds: UInt64 = 150_000_000

    var isEnabled: Bool {
        get { foldingModel.isEnabled }
        set { foldingModel.isEnabled = newValue }
    }

    var lastScannedLineCount: Int {
        foldingModel.lastScannedLineCount
    }

    init(foldingModel: FoldingModel) {
        self.foldingModel = foldingModel
        refreshEngine()
    }

    /// When set, the only provider, in place of the language's: for a host that knows the regions
    /// itself (a diff viewer folding unchanged lines).
    var overrideProvider: FoldingProviding? {
        didSet {
            setProviders(primary: languagePrimaryProvider)
            scheduleUpdate(full: true)
        }
    }

    private var languagePrimaryProvider: FoldingProviding?

    func setProviders(primary: FoldingProviding?, fallback: FoldingProviding = IndentationFoldingProvider()) {
        languagePrimaryProvider = primary
        if let overrideProvider {
            foldingProvider = overrideProvider
            foldingEngine = FoldingEngine(providers: [overrideProvider])
        } else if let primary {
            foldingProvider = primary
            foldingEngine = FoldingEngine(providers: [primary, fallback])
        } else {
            foldingProvider = fallback
            foldingEngine = FoldingEngine(providers: [fallback])
        }
    }

    /// - Parameter afterEdit: Waits for ``editDebounceNanoseconds`` of idle time before scanning.
    func scheduleUpdate(full: Bool = false, dirtyRows: ClosedRange<Int>? = nil, afterEdit: Bool = false) {
        guard foldingModel.isEnabled else {
            return
        }
        needsUpdate = true
        pendingAfterEdit = afterEdit
        contentVersion += 1
        if full {
            pendingFullUpdate = true
            pendingDirtyRows = nil
        } else if pendingFullUpdate {
            return
        } else if let dirtyRows {
            if let existing = pendingDirtyRows {
                pendingDirtyRows = min(existing.lowerBound, dirtyRows.lowerBound) ... max(existing.upperBound, dirtyRows.upperBound)
            } else {
                pendingDirtyRows = dirtyRows
            }
        }
    }

    func updateIfNeeded() {
        guard foldingModel.isEnabled, needsUpdate else {
            return
        }
        needsUpdate = false
        let currentGeneration = generation + 1
        generation = currentGeneration
        var fullUpdate = pendingFullUpdate
        var dirtyRows = pendingDirtyRows
        let delay = pendingAfterEdit ? Self.editDebounceNanoseconds : 0
        pendingFullUpdate = false
        pendingDirtyRows = nil
        pendingAfterEdit = false
        if hasUpdateInFlight {
            fullUpdate = fullUpdate || inFlightFullUpdate
            dirtyRows = Self.union(dirtyRows, inFlightDirtyRows)
        }

        let lineCount = foldingModel.lineManager.lineCount
        if lineCount > EditorPerformanceConstants.maxFoldRecomputeLineCount {
            foldingModel.reconcile(descriptors: [], incrementalScannedRows: nil)
            return
        }

        guard !fullUpdate, let dirtyRows, lineCount > 0 else {
            startUpdateTask(generation: currentGeneration, incrementalRows: nil, delay: delay)
            return
        }

        let start = max(0, dirtyRows.lowerBound)
        let end = min(lineCount - 1, max(start, dirtyRows.upperBound))
        if end - start + 1 >= min(lineCount / 2, 8_192) && end - start + 1 >= 512 {
            startUpdateTask(generation: currentGeneration, incrementalRows: nil, delay: delay)
            return
        }
        startUpdateTask(generation: currentGeneration, incrementalRows: start ... end, delay: delay)
    }

    /// Synchronous path for unit tests.
    func updateSynchronously() async {
        guard foldingModel.isEnabled else {
            return
        }
        let document = makeDocument()
        let descriptors = await fetchDescriptors(for: document)
        apply(descriptors: descriptors, generation: generation, incrementalRows: pendingDirtyRows)
        pendingDirtyRows = nil
        pendingFullUpdate = false
        needsUpdate = false
    }

    func applyLineDelta(at row: Int, delta: Int) {
        foldingModel.applyLineDelta(at: row, delta: delta)
    }

    func invalidateTreeSitterProviderForEdit(
        changedRows: ClosedRange<Int>?,
        lineCount: Int,
        previousLineCount: Int,
        spliceRow: Int
    ) {
        treeSitterFoldingProvider?.invalidateForEdit(
            changedRows: changedRows,
            lineCount: lineCount,
            previousLineCount: previousLineCount,
            spliceRow: spliceRow
        )
    }
}

private extension CodeFoldingManager {
    private func refreshEngine() {
        foldingEngine = FoldingEngine(providers: [foldingProvider, IndentationFoldingProvider()])
    }

    private func makeDocument() -> Document {
        let text = foldingModel.stringView.string as String
        let snapshot = TextSnapshot(version: contentVersion, text: text)
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            displayName: "Editor",
            contentSnapshot: snapshot,
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
            languageIdentifier: languageIdentifier
        )
    }

    private func startUpdateTask(generation: UInt, incrementalRows: ClosedRange<Int>?, delay: UInt64) {
        updateTask?.cancel()
        hasUpdateInFlight = true
        inFlightFullUpdate = incrementalRows == nil
        inFlightDirtyRows = incrementalRows
        updateTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self, !Task.isCancelled else {
                return
            }
            let descriptors = await fetchDescriptors(for: makeDocument())
            guard !Task.isCancelled else {
                return
            }
            apply(descriptors: descriptors, generation: generation, incrementalRows: incrementalRows)
        }
    }

    static func union(_ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return min(lhs.lowerBound, rhs.lowerBound) ... max(lhs.upperBound, rhs.upperBound)
    }

    private func fetchDescriptors(for document: Document) async -> [FoldingDescriptor] {
        if let engine = foldingEngine {
            return await engine.foldRegions(for: document)
        }
        return await foldingProvider.foldRegions(for: document)
    }

    private func apply(descriptors: [FoldingDescriptor], generation: UInt, incrementalRows: ClosedRange<Int>?) {
        guard generation == self.generation else {
            return
        }
        hasUpdateInFlight = false
        foldingModel.reconcile(descriptors: descriptors, incrementalScannedRows: incrementalRows)
    }
}
