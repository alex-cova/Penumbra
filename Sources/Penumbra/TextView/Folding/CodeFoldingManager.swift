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
    private var contentVersion = 0

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

    func setProviders(primary: FoldingProviding?, fallback: FoldingProviding = IndentationFoldingProvider()) {
        if let primary {
            foldingProvider = primary
            foldingEngine = FoldingEngine(providers: [primary, fallback])
        } else {
            foldingProvider = fallback
            foldingEngine = FoldingEngine(providers: [fallback])
        }
    }

    func scheduleUpdate(full: Bool = false, dirtyRows: ClosedRange<Int>? = nil) {
        guard foldingModel.isEnabled else {
            return
        }
        needsUpdate = true
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
        let fullUpdate = pendingFullUpdate
        let dirtyRows = pendingDirtyRows
        pendingFullUpdate = false
        pendingDirtyRows = nil

        let lineCount = foldingModel.lineManager.lineCount
        if lineCount > EditorPerformanceConstants.maxFoldRecomputeLineCount {
            foldingModel.reconcile(descriptors: [], incrementalScannedRows: nil)
            return
        }

        if fullUpdate || dirtyRows == nil || lineCount == 0 {
            startUpdateTask(generation: currentGeneration, document: makeDocument(), incrementalRows: nil)
            return
        }

        let start = max(0, dirtyRows!.lowerBound)
        let end = min(lineCount - 1, max(start, dirtyRows!.upperBound))
        if end - start + 1 >= min(lineCount / 2, 8_192) && end - start + 1 >= 512 {
            startUpdateTask(generation: currentGeneration, document: makeDocument(), incrementalRows: nil)
            return
        }
        startUpdateTask(generation: currentGeneration, document: makeDocument(), incrementalRows: start ... end)
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

    private func startUpdateTask(generation: UInt, document: Document, incrementalRows: ClosedRange<Int>?) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else {
                return
            }
            let descriptors = await fetchDescriptors(for: document)
            guard !Task.isCancelled else {
                return
            }
            apply(descriptors: descriptors, generation: generation, incrementalRows: incrementalRows)
        }
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
        foldingModel.reconcile(descriptors: descriptors, incrementalScannedRows: incrementalRows)
    }
}
