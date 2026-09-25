import Foundation
import Combine

/// Computes and tracks the document's foldable regions, and drives collapsing/expanding them.
///
/// Collapsing a fold is implemented by setting each of its hidden lines' height to zero
/// (`LineManager.setHeight(of:to:)`). The line manager's red-black tree is already augmented with
/// each line's accumulated height, so a zero-height line contributes nothing to
/// `contentHeight`/`line(containingYOffset:)`/etc. for free — no separate "is this y-offset inside
/// a fold" bookkeeping is needed for scrolling or hit-testing. `LayoutManager` still needs to know
/// to *skip* hidden lines while walking rows during layout (see `isLineHidden(_:)`), since that walk
/// advances row-by-row rather than purely by y-offset.
///
/// Deviations from the plan this was ported from, both made to keep this a safe, well-scoped first
/// cut rather than introducing new concurrency risk into a codebase whose edit pipeline is
/// synchronous end-to-end (see the same reasoning in the Phase 1 log for why 1c/1d/1e were
/// descoped):
/// - Fold storage is a simple array sorted by starting line, not the `RedBlackTree` used elsewhere.
///   That tree is built for partitioning a contiguous space (document lines/bytes); folds are a
///   sparse, small (hundreds, not millions) set of possibly-nested ranges, which the tree's
///   `ClosedRangeValueDescriptor` search machinery isn't shaped for. A sorted array with binary
///   search is simpler and fast enough at this scale.
/// - Recomputation is synchronous, not the actor-based chunked design in the plan. `LineManager` is
///   a plain (non-`Sendable`) class mutated only on the main thread as a direct consequence of each
///   edit; making the recompute genuinely async would mean holding `DocumentLineNode` references (or
///   line indices) across a suspension point where another edit could land and delete/shift the very
///   lines being examined, which is a correctness hazard, not just a performance one, given
///   recomputation mutates `LineManager` heights. Instead, recomputation is a plain synchronous pass
///   (the same cost class as `LineManager.rebuild()`, which is already synchronous), and is
///   coalesced via a dirty flag consumed lazily from `LayoutManager.layoutIfNeeded()` rather than run
///   on every keystroke, so idle typing doesn't pay for it repeatedly within one layout pass.
final class FoldingController {
    var lineManager: LineManager
    var stringView: StringView
    let lineControllerStorage: LineControllerStorage
    let contentSizeService: ContentSizeService
    var foldProvider: LineFoldProvider = LineIndentationFoldProvider()
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            if isEnabled {
                needsRecompute = true
                pendingFullRecompute = true
                pendingDirtyRows = nil
            } else {
                expandAll()
                folds = []
            }
            didChangeFolds.send()
        }
    }

    private(set) var folds: [FoldRange] = []
    let didChangeFolds = PassthroughSubject<Void, Never>()

    private var hiddenLineIDs: Set<DocumentLineNodeID> = []
    private var collapsedFoldByHiddenLineID: [DocumentLineNodeID: FoldRange] = [:]
    private var collapsedFoldByHeaderLineID: [DocumentLineNodeID: FoldRange] = [:]
    private var needsRecompute = false
    private var pendingFullRecompute = false
    private var pendingDirtyRows: ClosedRange<Int>?
    /// Lines visited by the most recent recompute. Tests use this to lock incremental scanning.
    private(set) var lastScannedLineCount = 0

    init(lineManager: LineManager,
         stringView: StringView,
         lineControllerStorage: LineControllerStorage,
         contentSizeService: ContentSizeService) {
        self.lineManager = lineManager
        self.stringView = stringView
        self.lineControllerStorage = lineControllerStorage
        self.contentSizeService = contentSizeService
    }

    func setNeedsRecompute() {
        guard isEnabled else {
            return
        }
        needsRecompute = true
        pendingFullRecompute = true
        pendingDirtyRows = nil
    }

    /// Marks a slice of the document dirty. Successive calls union the ranges until the next
    /// ``recomputeIfNeeded()``. A full ``setNeedsRecompute()`` still wins.
    func setNeedsRecompute(rows: ClosedRange<Int>) {
        guard isEnabled else {
            return
        }
        needsRecompute = true
        if pendingFullRecompute {
            return
        }
        if let existing = pendingDirtyRows {
            pendingDirtyRows = min(existing.lowerBound, rows.lowerBound) ... max(existing.upperBound, rows.upperBound)
        } else {
            pendingDirtyRows = rows
        }
    }

    /// Shifts stored fold row ranges after a line insertion (`delta > 0`) or deletion (`delta < 0`).
    func applyLineDelta(at row: Int, delta: Int) {
        guard isEnabled, delta != 0 else {
            return
        }
        var shifted: [FoldRange] = []
        shifted.reserveCapacity(folds.count)
        for fold in folds {
            var lower = fold.lineRange.lowerBound
            var upper = fold.lineRange.upperBound
            if lower >= row {
                lower += delta
            }
            if upper >= row {
                upper += delta
            }
            guard lower >= 0, upper > lower else {
                continue
            }
            var updated = fold
            updated.lineRange = lower ... upper
            shifted.append(updated)
        }
        folds = shifted
    }

    func recomputeIfNeeded() {
        guard isEnabled, needsRecompute else {
            return
        }
        needsRecompute = false
        recompute()
    }

    func isLineHidden(_ lineID: DocumentLineNodeID) -> Bool {
        isEnabled && hiddenLineIDs.contains(lineID)
    }

    /// The collapsed fold whose header is this line, if any — used to draw the placeholder pill.
    func collapsedFold(withHeaderLineID lineID: DocumentLineNodeID) -> FoldRange? {
        collapsedFoldByHeaderLineID[lineID]
    }

    /// The collapsed fold hiding this line, if any — used by caret movement to jump over it.
    func collapsedFold(hidingLineID lineID: DocumentLineNodeID) -> FoldRange? {
        collapsedFoldByHiddenLineID[lineID]
    }

    /// The deepest fold covering the given row, preferring a collapsed fold if one applies —
    /// used by the ribbon view to decide what a click on a given row should toggle.
    func deepestFold(atRow row: Int) -> FoldRange? {
        var best: FoldRange?
        for fold in folds where fold.lineRange.contains(row) {
            if best == nil {
                best = fold
            } else if fold.isCollapsed != best!.isCollapsed {
                if fold.isCollapsed {
                    best = fold
                }
            } else if fold.depth > best!.depth {
                best = fold
            }
        }
        return best
    }

    func toggleCollapse(_ fold: FoldRange) {
        guard let index = folds.firstIndex(where: { $0.id == fold.id }) else {
            return
        }
        folds[index].isCollapsed.toggle()
        if folds[index].isCollapsed {
            hide(folds[index])
        } else {
            reveal(folds[index])
        }
        didChangeFolds.send()
    }

    /// Returns a caret location that's always on a visible line. If `location` falls inside a
    /// collapsed fold's hidden lines, this returns the end of that fold's header line.
    func visibleCaretLocation(for location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let fold = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        return endOfHeaderLine(for: fold)
    }

    /// Maps a selection so neither bound falls inside a collapsed fold's hidden lines.
    func adjustedSelection(_ range: NSRange) -> NSRange {
        guard isEnabled, range.length >= 0 else {
            return range
        }
        if range.length == 0 {
            let location = visibleCaretLocation(for: range.location)
            return NSRange(location: location, length: 0)
        }
        let start = visibleCaretLocation(for: range.location)
        let end = visibleCaretLocation(for: range.upperBound)
        if start > end {
            return NSRange(location: start, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    /// When walking forward through the document (e.g. paragraph navigation), returns the first
    /// location outside a collapsed fold if `location` is inside one.
    func visibleLocationForForwardNavigation(from location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let fold = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        let afterRow = fold.lineRange.upperBound + 1
        if afterRow < lineManager.lineCount {
            return lineManager.location(ofRow: afterRow)
        }
        return stringView.length
    }

    /// When walking backward through the document, returns the end of the fold header if
    /// `location` is inside a collapsed fold's hidden lines.
    func visibleLocationForBackwardNavigation(from location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let fold = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        return endOfHeaderLine(for: fold)
    }

    func firstVisibleLine(atOrAfterRow row: Int) -> DocumentLineNode? {
        guard isEnabled else {
            guard row >= 0 && row < lineManager.lineCount else {
                return nil
            }
            return lineManager.line(atRow: row)
        }
        var currentRow = max(row, 0)
        while currentRow < lineManager.lineCount {
            let line = lineManager.line(atRow: currentRow)
            if !isLineHidden(line.id) {
                return line
            }
            currentRow += 1
        }
        return nil
    }

    func lastVisibleLine(atOrBeforeRow row: Int) -> DocumentLineNode? {
        guard isEnabled else {
            guard row >= 0 && row < lineManager.lineCount else {
                return nil
            }
            return lineManager.line(atRow: row)
        }
        var currentRow = min(row, lineManager.lineCount - 1)
        while currentRow >= 0 {
            let line = lineManager.line(atRow: currentRow)
            if !isLineHidden(line.id) {
                return line
            }
            currentRow -= 1
        }
        return nil
    }
}

private extension FoldingController {
    /// No handle: this runs for every selection bound (Select All Occurrences sanitizes each
    /// match).
    private func lineID(containingCharacterAt location: Int) -> DocumentLineNodeID? {
        guard location >= 0 else {
            return nil
        }
        let safeLocation = min(location, max(stringView.length - 1, 0))
        guard stringView.length > 0, let row = lineManager.row(containingCharacterAt: safeLocation) else {
            return nil
        }
        return lineManager.lineID(atRow: row)
    }

    private func endOfHeaderLine(for fold: FoldRange) -> Int {
        lineManager.contentRange(atRow: fold.lineRange.lowerBound).upperBound
    }

    private func expandAll() {
        for fold in folds where fold.isCollapsed {
            reveal(fold)
        }
    }

    private func hide(_ fold: FoldRange) {
        guard let hiddenLineRange = fold.hiddenLineRange else {
            return
        }
        for row in hiddenLineRange where row < lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            lineManager.setHeight(of: line, to: 0)
            hiddenLineIDs.insert(line.id)
            collapsedFoldByHiddenLineID[line.id] = fold
        }
        contentSizeService.invalidateContentSize()
        let headerLine = lineManager.line(atRow: fold.lineRange.lowerBound)
        collapsedFoldByHeaderLineID[headerLine.id] = fold
    }

    /// Restores a fold's hidden lines to a real (typesettable) height. Rather than trying to
    /// remember each line's pre-collapse height ourselves, this invalidates the line and resets
    /// its height to the shared estimate — the same state a freshly-inserted line starts in — so
    /// the next `layoutLinesInViewport()` pass naturally re-typesets it and self-corrects, exactly
    /// like an ordinary newly-scrolled-into-view line does.
    private func reveal(_ fold: FoldRange) {
        guard let hiddenLineRange = fold.hiddenLineRange else {
            return
        }
        for row in hiddenLineRange where row < lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            hiddenLineIDs.remove(line.id)
            collapsedFoldByHiddenLineID.removeValue(forKey: line.id)
            let lineController = lineControllerStorage.getOrCreateLineController(for: line)
            lineController.invalidateEverything()
            lineManager.setHeight(of: line, to: lineController.lineHeight)
        }
        contentSizeService.invalidateContentSize()
        if fold.lineRange.lowerBound < lineManager.lineCount {
            let headerLine = lineManager.line(atRow: fold.lineRange.lowerBound)
            collapsedFoldByHeaderLineID.removeValue(forKey: headerLine.id)
        }
        for nested in folds where nested.isCollapsed
            && nested.id != fold.id
            && fold.lineRange.lowerBound <= nested.lineRange.lowerBound
            && nested.lineRange.upperBound <= fold.lineRange.upperBound {
            hide(nested)
        }
    }

    private func recompute() {
        PenumbraSignposts.interval("FoldingController.recompute") {
            let lineCount = lineManager.lineCount
            if lineCount > EditorPerformanceConstants.maxFoldRecomputeLineCount {
                pendingFullRecompute = false
                pendingDirtyRows = nil
                lastScannedLineCount = 0
                applyRecomputedFolds([])
                return
            }
            if pendingFullRecompute || pendingDirtyRows == nil || lineCount == 0 {
                pendingFullRecompute = false
                pendingDirtyRows = nil
                recomputeFull()
                return
            }
            let dirty = pendingDirtyRows!
            pendingDirtyRows = nil
            recomputeIncremental(rows: dirty)
        }
    }

    private func recomputeFull() {
        let lineCount = lineManager.lineCount
        lastScannedLineCount = lineCount
        var scanner = FoldScanner(nextID: 0)
        var row = 0
        while row < lineCount {
            let events = foldProvider.foldEvents(atLine: row, previousDepth: scanner.currentDepth, in: lineManager, stringView: stringView)
            scanner.apply(events: events, row: row)
            row += 1
        }
        scanner.closeRemaining(endRow: lineCount - 1)
        applyRecomputedFolds(scanner.folds)
    }

    private func recomputeIncremental(rows: ClosedRange<Int>) {
        let lineCount = lineManager.lineCount
        guard lineCount > 0 else {
            lastScannedLineCount = 0
            applyRecomputedFolds([])
            return
        }
        let start = max(0, rows.lowerBound)
        let end = min(lineCount - 1, max(start, rows.upperBound))
        if end - start + 1 >= min(lineCount / 2, 8_192) && end - start + 1 >= 512 {
            pendingFullRecompute = false
            recomputeFull()
            return
        }
        var openFolds: [Int: Int] = [:]
        for fold in folds where fold.lineRange.lowerBound < start && fold.lineRange.upperBound >= start {
            openFolds[fold.depth] = fold.lineRange.lowerBound
        }
        var scanner = FoldScanner(openFolds: openFolds, currentDepth: openFolds.keys.max() ?? 0, nextID: (folds.map(\.id).max() ?? -1) + 1)
        let startDepth = scanner.currentDepth
        var row = start
        while row < lineCount {
            let events = foldProvider.foldEvents(atLine: row, previousDepth: scanner.currentDepth, in: lineManager, stringView: stringView)
            scanner.apply(events: events, row: row)
            row += 1
            let onlyPreWindowOpen = scanner.openFolds.values.allSatisfy { $0 < start }
            if row > end && scanner.currentDepth <= startDepth && onlyPreWindowOpen {
                break
            }
        }
        let lastRow = row - 1
        lastScannedLineCount = max(0, lastRow - start + 1)
        if lastRow == lineCount - 1 {
            scanner.closeRemaining(endRow: lastRow)
        }
        spliceFolds(discovered: scanner.folds, scanned: start ... max(start, lastRow))
    }

    /// Replaces folds that overlap `scanned` with `discovered`, keeping folds entirely outside
    /// the scan window (including pre-window folds that stayed open through it).
    private func spliceFolds(discovered: [FoldRange], scanned: ClosedRange<Int>) {
        var kept: [FoldRange] = []
        kept.reserveCapacity(folds.count)
        let discoveredStarts = Set(discovered.map(\.lineRange.lowerBound))
        for fold in folds {
            if fold.lineRange.upperBound < scanned.lowerBound {
                kept.append(fold)
                continue
            }
            if fold.lineRange.lowerBound > scanned.upperBound {
                kept.append(fold)
                continue
            }
            if fold.lineRange.lowerBound < scanned.lowerBound && !discoveredStarts.contains(fold.lineRange.lowerBound) {
                kept.append(fold)
            }
        }
        var merged = kept + discovered
        merged.sort { $0.lineRange.lowerBound < $1.lineRange.lowerBound }
        applyRecomputedFolds(merged, restoreRows: scanned)
    }

    /// Reconciles freshly-recomputed (always-uncollapsed) folds against the previous collapse
    /// state, matching by which lines were hidden before rather than by fold identity — fold IDs
    /// are freshly assigned on every recompute, but `DocumentLineNodeID`s survive edits to
    /// unrelated lines, so a fold whose exact line range is unaffected by the edit keeps its
    /// collapsed state. A fold whose range shifted because of the edit is treated as new (and
    /// starts expanded) — a known, minor rough edge rather than a correctness issue.
    private func applyRecomputedFolds(_ newFolds: [FoldRange], restoreRows: ClosedRange<Int>? = nil) {
        let previouslyHiddenLineIDs = hiddenLineIDs
        hiddenLineIDs = []
        collapsedFoldByHiddenLineID = [:]
        collapsedFoldByHeaderLineID = [:]
        var resultFolds: [FoldRange] = []
        resultFolds.reserveCapacity(newFolds.count)
        let lineCount = lineManager.lineCount
        for fold in newFolds {
            var updatedFold = fold
            updatedFold.isCollapsed = false
            // Runs on every edit, over every fold's rows (nested folds cover most lines several
            // times). With nothing hidden before, no fold can be collapsed, so skip the walk; and
            // read IDs without creating line handles until a fold really is collapsed.
            if !previouslyHiddenLineIDs.isEmpty, let hiddenLineRange = fold.hiddenLineRange,
               hiddenLineRange.lowerBound < lineCount {
                let rows = hiddenLineRange.lowerBound ... min(hiddenLineRange.upperBound, lineCount - 1)
                let wasCollapsed = rows.allSatisfy { previouslyHiddenLineIDs.contains(lineManager.lineID(atRow: $0)) }
                updatedFold.isCollapsed = wasCollapsed
                if wasCollapsed {
                    for row in rows {
                        let line = lineManager.line(atRow: row)
                        lineManager.setHeight(of: line, to: 0)
                        hiddenLineIDs.insert(line.id)
                        collapsedFoldByHiddenLineID[line.id] = updatedFold
                    }
                    collapsedFoldByHeaderLineID[lineManager.lineID(atRow: fold.lineRange.lowerBound)] = updatedFold
                }
            }
            resultFolds.append(updatedFold)
        }
        // Any previously-hidden line that isn't covered by a still-collapsed fold needs to be
        // restored to a real height. Incremental recomputes only walk the scanned rows; a full
        // recompute still walks the document when collapse state actually changed.
        let stillHiddenLineIDs = hiddenLineIDs
        if previouslyHiddenLineIDs.contains(where: { !stillHiddenLineIDs.contains($0) }) {
            restoreHeights(of: previouslyHiddenLineIDs.subtracting(stillHiddenLineIDs), in: restoreRows)
        }
        folds = resultFolds
        contentSizeService.invalidateContentSize()
        didChangeFolds.send()
    }

    private func restoreHeights(of lineIDs: Set<DocumentLineNodeID>, in rows: ClosedRange<Int>?) {
        if let rows {
            for row in rows where row < lineManager.lineCount {
                let line = lineManager.line(atRow: row)
                if lineIDs.contains(line.id) {
                    let lineController = lineControllerStorage.getOrCreateLineController(for: line)
                    lineController.invalidateEverything()
                    lineManager.setHeight(of: line, to: lineController.lineHeight)
                }
            }
            return
        }
        let iterator = lineManager.createLineIterator()
        while let line = iterator.next() {
            if lineIDs.contains(line.id) {
                let lineController = lineControllerStorage.getOrCreateLineController(for: line)
                lineController.invalidateEverything()
                lineManager.setHeight(of: line, to: lineController.lineHeight)
            }
        }
    }
}

private struct FoldScanner {
    var openFolds: [Int: Int]
    var currentDepth: Int
    var nextID: Int
    var folds: [FoldRange] = []

    init(openFolds: [Int: Int] = [:], currentDepth: Int = 0, nextID: Int = 0) {
        self.openFolds = openFolds
        self.currentDepth = currentDepth
        self.nextID = nextID
    }

    mutating func apply(events: [LineFoldEvent], row: Int) {
        for event in events {
            switch event {
            case .startFold(let depth):
                openFolds[depth] = row
            case .endFold(let depth):
                for (openDepth, startRow) in openFolds where openDepth > depth {
                    openFolds.removeValue(forKey: openDepth)
                    if row - 1 > startRow {
                        folds.append(FoldRange(id: nextID, depth: openDepth, lineRange: startRow ... (row - 1), isCollapsed: false))
                        nextID += 1
                    }
                }
            }
            currentDepth = event.depth
        }
    }

    mutating func closeRemaining(endRow: Int) {
        for (depth, startRow) in openFolds {
            if endRow > startRow {
                folds.append(FoldRange(id: nextID, depth: depth, lineRange: startRow ... endRow, isCollapsed: false))
                nextID += 1
            }
        }
        openFolds.removeAll()
    }
}
