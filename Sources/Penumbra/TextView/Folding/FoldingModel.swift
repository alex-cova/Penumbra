import Combine
import EditorIntelligence
import Foundation

/// Editor-side fold region model: collapse state, line-height hiding, and caret/navigation helpers.
final class FoldingModel {
    var lineManager: LineManager
    var stringView: StringView
    let lineControllerStorage: LineControllerStorage
    let contentSizeService: ContentSizeService

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            if isEnabled {
                needsReconcile = true
            } else {
                expandAll()
                regions = []
            }
            didChangeFolds.send()
        }
    }

    private(set) var regions: [FoldRegion] = []
    let didChangeFolds = PassthroughSubject<Void, Never>()

    private var hiddenLineIDs: Set<DocumentLineNodeID> = []
    private var collapsedRegionByHiddenLineID: [DocumentLineNodeID: FoldRegion] = [:]
    private var collapsedRegionByHeaderLineID: [DocumentLineNodeID: FoldRegion] = [:]
    private var batchDepth = 0
    private var needsReconcile = false
    private(set) var lastScannedLineCount = 0

    init(
        lineManager: LineManager,
        stringView: StringView,
        lineControllerStorage: LineControllerStorage,
        contentSizeService: ContentSizeService
    ) {
        self.lineManager = lineManager
        self.stringView = stringView
        self.lineControllerStorage = lineControllerStorage
        self.contentSizeService = contentSizeService
    }

    var folds: [FoldRegion] { regions }

    func runBatchFoldingOperation(_ operation: () -> Void) {
        batchDepth += 1
        operation()
        batchDepth -= 1
        if batchDepth == 0 {
            contentSizeService.invalidateContentSize()
            didChangeFolds.send()
        }
    }

    func applyLineDelta(at row: Int, delta: Int) {
        guard isEnabled, delta != 0 else {
            return
        }
        // In place: copying every region (and its placeholder string) cost more than the shift.
        var invalidIndices: [Int] = []
        for index in regions.indices {
            let range = regions[index].lineRange
            guard range.upperBound >= row else {
                continue
            }
            let lower = range.lowerBound >= row ? range.lowerBound + delta : range.lowerBound
            let upper = range.upperBound + delta
            guard lower >= 0, upper > lower else {
                invalidIndices.append(index)
                continue
            }
            regions[index].lineRange = lower ... upper
        }
        for index in invalidIndices.reversed() {
            regions.remove(at: index)
        }
    }

    func isLineHidden(_ lineID: DocumentLineNodeID) -> Bool {
        isEnabled && hiddenLineIDs.contains(lineID)
    }

    func collapsedFold(withHeaderLineID lineID: DocumentLineNodeID) -> FoldRegion? {
        collapsedRegionByHeaderLineID[lineID]
    }

    func collapsedFold(hidingLineID lineID: DocumentLineNodeID) -> FoldRegion? {
        collapsedRegionByHiddenLineID[lineID]
    }

    func deepestFold(atRow row: Int) -> FoldRegion? {
        var best: FoldRegion?
        for region in regions where region.lineRange.contains(row) {
            if best == nil {
                best = region
            } else if region.isCollapsed != best!.isCollapsed {
                if region.isCollapsed {
                    best = region
                }
            } else if region.depth > best!.depth {
                best = region
            }
        }
        return best
    }

    func foldRegion(atOffset offset: Int) -> FoldRegion? {
        guard let row = lineManager.row(containingCharacterAt: max(0, offset)) else {
            return nil
        }
        return deepestFold(atRow: row)
    }

    func collapsedRegion(atOffset offset: Int) -> FoldRegion? {
        guard let region = foldRegion(atOffset: offset), region.isCollapsed else {
            return nil
        }
        return region
    }

    func toggleCollapse(_ region: FoldRegion) {
        guard let index = regions.firstIndex(where: { $0.id == region.id }) else {
            return
        }
        setExpanded(at: index, expanded: !regions[index].isExpanded)
    }

    func setExpanded(_ region: FoldRegion, expanded: Bool) {
        guard let index = regions.firstIndex(where: { $0.id == region.id }) else {
            return
        }
        setExpanded(at: index, expanded: expanded)
    }

    func collapseRegion(atCaret offset: Int) {
        guard let region = deepestExpandedFold(atOffset: offset) else {
            return
        }
        setExpanded(region, expanded: false)
    }

    func expandRegion(atCaret offset: Int) {
        guard let region = deepestCollapsedFold(atOffset: offset) else {
            return
        }
        setExpanded(region, expanded: true)
    }

    func collapseAllRegions() {
        runBatchFoldingOperation {
            for index in regions.indices where regions[index].isExpanded {
                collapseRegion(at: index, notify: false)
            }
        }
    }

    func expandAllRegions() {
        runBatchFoldingOperation {
            for index in regions.indices where regions[index].isCollapsed {
                revealRegion(at: index, notify: false)
            }
        }
    }

    func collapseRegionRecursively(atCaret offset: Int) {
        guard let target = deepestExpandedFold(atOffset: offset) else {
            return
        }
        runBatchFoldingOperation {
            for index in regions.indices where regions[index].isExpanded
                && target.lineRange.lowerBound <= regions[index].lineRange.lowerBound
                && regions[index].lineRange.upperBound <= target.lineRange.upperBound {
                collapseRegion(at: index, notify: false)
            }
        }
    }

    func expandRegionRecursively(atCaret offset: Int) {
        guard let target = deepestCollapsedFold(atOffset: offset) ?? deepestExpandedFold(atOffset: offset) else {
            return
        }
        runBatchFoldingOperation {
            for index in regions.indices where regions[index].isCollapsed
                && target.lineRange.lowerBound <= regions[index].lineRange.lowerBound
                && regions[index].lineRange.upperBound <= target.lineRange.upperBound {
                revealRegion(at: index, notify: false)
            }
        }
    }

    func visibleCaretLocation(for location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let region = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        return endOfHeaderLine(for: region)
    }

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

    func visibleLocationForForwardNavigation(from location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let region = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        let afterRow = region.lineRange.upperBound + 1
        if afterRow < lineManager.lineCount {
            return lineManager.location(ofRow: afterRow)
        }
        return stringView.length
    }

    func visibleLocationForBackwardNavigation(from location: Int) -> Int {
        guard isEnabled else {
            return location
        }
        guard let hiddenLineID = lineID(containingCharacterAt: location),
              isLineHidden(hiddenLineID),
              let region = collapsedFold(hidingLineID: hiddenLineID) else {
            return location
        }
        return endOfHeaderLine(for: region)
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

    func reconcile(
        descriptors: [FoldingDescriptor],
        incrementalScannedRows: ClosedRange<Int>? = nil
    ) {
        let lineCount = lineManager.lineCount
        if lineCount > EditorPerformanceConstants.maxFoldRecomputeLineCount {
            lastScannedLineCount = 0
            applyReconciledRegions([], restoreRows: nil)
            return
        }

        // Each descriptor is converted to rows once; depths come from one sweep over the result.
        var lineRanges: [ClosedRange<Int>?] = []
        lineRanges.reserveCapacity(descriptors.count)
        // A node and its body often cover the same lines (`function f() {…}` and its `{…}`). Keep
        // the first (outermost) of each line range: duplicates would each take a collapse or expand,
        // so ⌘- and ⌘+ would do nothing visible every other press.
        var seenLineRanges = Set<ClosedRange<Int>>()
        for descriptor in descriptors {
            let lineRange = FoldingDescriptorConversion.lineRange(for: descriptor, in: lineManager)
            if let lineRange, !seenLineRanges.insert(lineRange).inserted {
                lineRanges.append(nil)
            } else {
                lineRanges.append(lineRange)
            }
        }
        let depths = Self.nestingDepths(of: lineRanges)
        var candidateRegions: [FoldRegion] = []
        candidateRegions.reserveCapacity(descriptors.count)
        for (index, descriptor) in descriptors.enumerated() {
            guard let lineRange = lineRanges[index], lineRange.upperBound > lineRange.lowerBound else {
                continue
            }
            if let scanned = incrementalScannedRows,
               lineRange.upperBound < scanned.lowerBound || lineRange.lowerBound > scanned.upperBound {
                // Providers describe the whole document; outside the window the existing regions stay.
                continue
            }
            candidateRegions.append(
                FoldRegion(
                    depth: depths[index],
                    lineRange: lineRange,
                    placeholder: descriptor.placeholder,
                    groupID: descriptor.groupID,
                    isExpanded: !descriptor.collapsedByDefault
                )
            )
        }
        candidateRegions.sort { $0.lineRange.lowerBound < $1.lineRange.lowerBound }

        if let incrementalScannedRows {
            spliceRegions(discovered: candidateRegions, scanned: incrementalScannedRows)
        } else {
            lastScannedLineCount = lineCount
            applyReconciledRegions(candidateRegions, restoreRows: nil)
        }
    }
}

private extension FoldingModel {
    func lineID(containingCharacterAt location: Int) -> DocumentLineNodeID? {
        guard location >= 0 else {
            return nil
        }
        let safeLocation = min(location, max(stringView.length - 1, 0))
        guard stringView.length > 0, let row = lineManager.row(containingCharacterAt: safeLocation) else {
            return nil
        }
        return lineManager.lineID(atRow: row)
    }

    func endOfHeaderLine(for region: FoldRegion) -> Int {
        lineManager.contentRange(atRow: region.lineRange.lowerBound).upperBound
    }

    func deepestExpandedFold(atOffset offset: Int) -> FoldRegion? {
        guard let row = lineManager.row(containingCharacterAt: max(0, offset)) else {
            return nil
        }
        return regions
            .filter { $0.isExpanded && $0.lineRange.contains(row) }
            .max(by: { $0.depth < $1.depth })
    }

    func deepestCollapsedFold(atOffset offset: Int) -> FoldRegion? {
        guard let row = lineManager.row(containingCharacterAt: max(0, offset)) else {
            return nil
        }
        return regions
            .filter { $0.isCollapsed && $0.lineRange.contains(row) }
            .max(by: { $0.depth < $1.depth })
    }

    func setExpanded(at index: Int, expanded: Bool) {
        guard regions[index].isExpanded != expanded else {
            return
        }
        if expanded {
            revealRegion(at: index, notify: batchDepth == 0)
        } else {
            collapseRegion(at: index, notify: batchDepth == 0)
        }
    }

    func expandAll() {
        for index in regions.indices where regions[index].isCollapsed {
            revealRegion(at: index, notify: false)
        }
    }

    func collapseRegion(at index: Int, notify: Bool) {
        regions[index].isExpanded = false
        hide(regions[index])
        if let groupID = regions[index].groupID {
            for otherIndex in regions.indices where regions[otherIndex].groupID == groupID && otherIndex != index {
                if regions[otherIndex].isExpanded {
                    regions[otherIndex].isExpanded = false
                    hide(regions[otherIndex])
                }
            }
        }
        if notify {
            contentSizeService.invalidateContentSize()
            didChangeFolds.send()
        }
    }

    func revealRegion(at index: Int, notify: Bool) {
        let region = regions[index]
        regions[index].isExpanded = true
        reveal(region)
        if notify {
            contentSizeService.invalidateContentSize()
            didChangeFolds.send()
        }
    }

    func hide(_ region: FoldRegion) {
        guard let hiddenLineRange = region.hiddenLineRange else {
            return
        }
        for row in hiddenLineRange where row < lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            lineManager.setHeight(of: line, to: 0)
            hiddenLineIDs.insert(line.id)
            collapsedRegionByHiddenLineID[line.id] = region
        }
        let headerLine = lineManager.line(atRow: region.lineRange.lowerBound)
        collapsedRegionByHeaderLineID[headerLine.id] = region
    }

    func reveal(_ region: FoldRegion) {
        guard let hiddenLineRange = region.hiddenLineRange else {
            return
        }
        for row in hiddenLineRange where row < lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            hiddenLineIDs.remove(line.id)
            collapsedRegionByHiddenLineID.removeValue(forKey: line.id)
            let lineController = lineControllerStorage.getOrCreateLineController(for: line)
            lineController.invalidateEverything()
            lineManager.setHeight(of: line, to: lineController.lineHeight)
        }
        if region.lineRange.lowerBound < lineManager.lineCount {
            let headerLine = lineManager.line(atRow: region.lineRange.lowerBound)
            collapsedRegionByHeaderLineID.removeValue(forKey: headerLine.id)
        }
        for nested in regions where nested.isCollapsed
            && nested.id != region.id
            && region.lineRange.lowerBound <= nested.lineRange.lowerBound
            && nested.lineRange.upperBound <= region.lineRange.upperBound {
            hide(nested)
        }
    }

    func spliceRegions(discovered: [FoldRegion], scanned: ClosedRange<Int>) {
        var kept: [FoldRegion] = []
        kept.reserveCapacity(regions.count)
        let discoveredStarts = Set(discovered.map(\.lineRange.lowerBound))
        for region in regions {
            if region.lineRange.upperBound < scanned.lowerBound {
                kept.append(region)
                continue
            }
            if region.lineRange.lowerBound > scanned.upperBound {
                kept.append(region)
                continue
            }
            if region.lineRange.lowerBound < scanned.lowerBound && !discoveredStarts.contains(region.lineRange.lowerBound) {
                kept.append(region)
            }
        }
        let keptLineRanges = Set(kept.map(\.lineRange))
        var merged = kept + discovered.filter { !keptLineRanges.contains($0.lineRange) }
        merged.sort { $0.lineRange.lowerBound < $1.lineRange.lowerBound }
        lastScannedLineCount = scanned.upperBound - scanned.lowerBound + 1
        applyReconciledRegions(merged, restoreRows: scanned)
    }

    func applyReconciledRegions(_ newRegions: [FoldRegion], restoreRows: ClosedRange<Int>?) {
        let previouslyHiddenLineIDs = hiddenLineIDs
        let previouslyCollapsedStarts = Set(
            regions.filter { $0.isCollapsed }.map(\.lineRange.lowerBound)
        )
        hiddenLineIDs = []
        collapsedRegionByHiddenLineID = [:]
        collapsedRegionByHeaderLineID = [:]
        var resultRegions: [FoldRegion] = []
        resultRegions.reserveCapacity(newRegions.count)
        let lineCount = lineManager.lineCount

        for region in newRegions {
            var updated = region

            if let hiddenLineRange = region.hiddenLineRange, hiddenLineRange.lowerBound < lineCount {
                let rows = hiddenLineRange.lowerBound ... min(hiddenLineRange.upperBound, lineCount - 1)
                let wasCollapsed = rows.allSatisfy { previouslyHiddenLineIDs.contains(lineManager.lineID(atRow: $0)) }
                    || previouslyCollapsedStarts.contains(region.lineRange.lowerBound)
                    || !region.isExpanded
                if wasCollapsed {
                    updated.isExpanded = false
                    for row in rows {
                        let line = lineManager.line(atRow: row)
                        lineManager.setHeight(of: line, to: 0)
                        hiddenLineIDs.insert(line.id)
                        collapsedRegionByHiddenLineID[line.id] = updated
                    }
                    collapsedRegionByHeaderLineID[lineManager.lineID(atRow: region.lineRange.lowerBound)] = updated
                }
            } else if !region.isExpanded {
                updated.isExpanded = false
            }

            resultRegions.append(updated)
        }

        let stillHiddenLineIDs = hiddenLineIDs
        if previouslyHiddenLineIDs.contains(where: { !stillHiddenLineIDs.contains($0) }) {
            restoreHeights(of: previouslyHiddenLineIDs.subtracting(stillHiddenLineIDs), in: restoreRows)
        }
        regions = resultRegions
        if batchDepth == 0 {
            contentSizeService.invalidateContentSize()
            didChangeFolds.send()
        }
    }

    func restoreHeights(of lineIDs: Set<DocumentLineNodeID>, in rows: ClosedRange<Int>?) {
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

extension FoldingModel {
    /// For each range, the number of other ranges that start on an earlier row and end on the same
    /// row or later. O(n log n): ranges are visited by start row and counted by end row in a
    /// Fenwick tree. A pairwise count (every descriptor against every other) took seconds per
    /// reconcile with the thousands of folds in a 20k-line Java file.
    static func nestingDepths(of lineRanges: [ClosedRange<Int>?]) -> [Int] {
        var depths = [Int](repeating: 0, count: lineRanges.count)
        let indices = lineRanges.indices
            .filter { lineRanges[$0] != nil }
            .sorted { lineRanges[$0]!.lowerBound < lineRanges[$1]!.lowerBound }
        guard !indices.isEmpty else {
            return depths
        }
        let upperBounds = Array(Set(indices.map { lineRanges[$0]!.upperBound })).sorted()
        var tree = [Int](repeating: 0, count: upperBounds.count + 1)
        func slot(ofUpperBound upperBound: Int) -> Int {
            var low = 0
            var high = upperBounds.count
            while low < high {
                let mid = (low + high) / 2
                if upperBounds[mid] < upperBound {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }
        // Inserted ranges whose end row is below `upperBound`.
        func countEnding(before upperBound: Int) -> Int {
            var total = 0
            var position = slot(ofUpperBound: upperBound)
            while position > 0 {
                total += tree[position]
                position -= position & -position
            }
            return total
        }
        var inserted = 0
        var groupStart = 0
        while groupStart < indices.count {
            let lowerBound = lineRanges[indices[groupStart]]!.lowerBound
            var groupEnd = groupStart
            while groupEnd < indices.count && lineRanges[indices[groupEnd]]!.lowerBound == lowerBound {
                groupEnd += 1
            }
            // Ranges starting on the same row don't contain each other, so query the group before inserting it.
            for index in indices[groupStart ..< groupEnd] {
                depths[index] = inserted - countEnding(before: lineRanges[index]!.upperBound)
            }
            for index in indices[groupStart ..< groupEnd] {
                var position = slot(ofUpperBound: lineRanges[index]!.upperBound) + 1
                while position <= upperBounds.count {
                    tree[position] += 1
                    position += position & -position
                }
                inserted += 1
            }
            groupStart = groupEnd
        }
        return depths
    }
}
