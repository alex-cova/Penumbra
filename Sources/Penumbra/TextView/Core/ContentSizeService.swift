import Foundation
import Combine

final class ContentSizeService {
    var safeAreaInset: UIEdgeInsets = .zero
    var textContainerInset: UIEdgeInsets = .zero
    var scrollViewWidth: CGFloat = 0 {
        didSet {
            if scrollViewWidth != oldValue && isLineWrappingEnabled {
                invalidateContentSize()
            }
        }
    }
    var isLineWrappingEnabled = true {
        didSet {
            if isLineWrappingEnabled != oldValue {
                invalidateContentSize()
            }
        }
    }
    let invisibleCharacterConfiguration: InvisibleCharacterConfiguration
    var lineManager: LineManager {
        didSet {
            if lineManager !== oldValue {
                reset()
            }
        }
    }
    var contentWidth: CGFloat {
        let minimumWidth = scrollViewWidth - safeAreaInset.left - safeAreaInset.right
        if isLineWrappingEnabled {
            return minimumWidth
        } else {
            let textContentWidth = longestLineWidth ?? scrollViewWidth
            let preferredWidth = ceil(
                textContentWidth
                + gutterWidthService.gutterWidth
                + textContainerInset.left
                + textContainerInset.right
                + invisibleCharacterConfiguration.maximumLineBreakSymbolWidth
            )
            return max(preferredWidth, minimumWidth)
        }
    }
    var contentHeight: CGFloat {
        ceil(totalLinesHeight + textContainerInset.top + textContainerInset.bottom)
    }
    var contentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }
    @Published private(set) var isContentSizeInvalid = false

    private let lineControllerStorage: LineControllerStorage
    private let gutterWidthService: GutterWidthService
    private var lineIDTrackingWidth: DocumentLineNodeID?
    private var lineWidths: [DocumentLineNodeID: CGFloat] = [:]
    private var longestLineWidth: CGFloat? {
        if let longestLineWidth = _longestLineWidth {
            return longestLineWidth
        } else if let lineIDTrackingWidth = lineIDTrackingWidth, let lineWidth = lineWidths[lineIDTrackingWidth] {
            let longestLineWidth = lineWidth
            _longestLineWidth = longestLineWidth
            if _totalLinesHeight != nil {
                isContentSizeInvalid = false
            }
            return longestLineWidth
        } else {
            lineIDTrackingWidth = nil
            var longestLineWidth: CGFloat?
            for (lineID, lineWidth) in lineWidths {
                if let currentLongestLineWidth = longestLineWidth {
                    if lineWidth > currentLongestLineWidth {
                        lineIDTrackingWidth = lineID
                        longestLineWidth = lineWidth
                    }
                } else {
                    lineIDTrackingWidth = lineID
                    longestLineWidth = lineWidth
                }
            }
            _longestLineWidth = longestLineWidth
            if longestLineWidth != nil && _totalLinesHeight != nil {
                isContentSizeInvalid = false
            }
            return longestLineWidth
        }
    }
    private var totalLinesHeight: CGFloat {
        if let totalLinesHeight = _totalLinesHeight {
            return totalLinesHeight
        } else {
            let totalLinesHeight = lineManager.contentHeight
            _totalLinesHeight = totalLinesHeight
            if _longestLineWidth != nil {
                isContentSizeInvalid = false
            }
            return totalLinesHeight
        }
    }
    private var _longestLineWidth: CGFloat? {
        didSet {
            if _longestLineWidth != oldValue {
                isContentSizeInvalid = _totalLinesHeight == nil || _longestLineWidth == nil
            }
        }
    }
    private var _totalLinesHeight: CGFloat? {
        didSet {
            if _totalLinesHeight != oldValue {
                isContentSizeInvalid = _totalLinesHeight == nil || _longestLineWidth == nil
            }
        }
    }

    init(lineManager: LineManager,
         lineControllerStorage: LineControllerStorage,
         gutterWidthService: GutterWidthService,
         invisibleCharacterConfiguration: InvisibleCharacterConfiguration) {
        self.lineManager = lineManager
        self.lineControllerStorage = lineControllerStorage
        self.gutterWidthService = gutterWidthService
        self.invisibleCharacterConfiguration = invisibleCharacterConfiguration
    }

    func invalidateContentSize() {
        _longestLineWidth = nil
        _totalLinesHeight = nil
    }

    /// Discards every per-line measurement, not just the derived totals `invalidateContentSize()`
    /// clears. Use this whenever the document's lines are rebuilt wholesale (`TextView.text =`,
    /// `setState`): `DocumentLineNodeID`s are recycled by `LineManager.rebuild()`, so a stale
    /// `lineWidths` / `lineIDTrackingWidth` entry keyed by an old id would otherwise be read back
    /// as the width of an unrelated new line and skew `contentWidth`.
    func reset() {
        lineWidths = [:]
        lineIDTrackingWidth = nil
        invalidateContentSize()
        storeWidthOfInitiallyLongestLine()
    }

    func removeLine(withID lineID: DocumentLineNodeID) {
        lineWidths.removeValue(forKey: lineID)
        if lineID == lineIDTrackingWidth {
            lineIDTrackingWidth = nil
            _longestLineWidth = nil
        }
    }

    /// Evicts cached line widths for lines that aren't currently visible, mirroring
    /// `LineControllerStorage.removeAllLineControllers(exceptLinesWithID:)`. Without this,
    /// `lineWidths` gains one entry per line ever visited and is never reclaimed — unbounded for a
    /// user paging through a huge non-wrapped file, and each subsequent invalidation (e.g. a window
    /// resize) re-scans all of it in `longestLineWidth`'s linear fallback. See
    /// PERFORMANCE_AUDIT.md, Phase 1 §5/Phase 2 finding on `ContentSizeService`.
    func removeLineWidths(exceptLinesWithID exceptionLineIDs: Set<DocumentLineNodeID>) {
        var lineIDsToRelease = Set(lineWidths.keys).subtracting(exceptionLineIDs)
        // Never evict the line currently tracked as longest: `setSize(of:to:)` reads
        // `lineWidths[lineIDTrackingWidth]` as the "current maximum" to compare newly-measured
        // lines against — losing that entry would make it read as 0 and incorrectly treat almost
        // any subsequently-measured line as the new longest. It would also silently shrink the
        // reported content width until that happened.
        if let lineIDTrackingWidth {
            lineIDsToRelease.remove(lineIDTrackingWidth)
        }
        guard !lineIDsToRelease.isEmpty else {
            return
        }
        for lineID in lineIDsToRelease {
            lineWidths.removeValue(forKey: lineID)
        }
    }

    func setSize(of line: DocumentLineNode, to newSize: CGSize) {
        let lineWidth = newSize.width
        if lineWidths[line.id] != lineWidth {
            lineWidths[line.id] = lineWidth
            if let lineIDTrackingWidth = lineIDTrackingWidth {
                let maximumLineWidth = lineWidths[lineIDTrackingWidth] ?? 0
                if line.id == lineIDTrackingWidth || lineWidth > maximumLineWidth {
                    self.lineIDTrackingWidth = line.id
                    _longestLineWidth = nil
                }
            } else if !isLineWrappingEnabled {
                _longestLineWidth = nil
            }
        }
        let didUpdateHeight = lineManager.setHeight(of: line, to: newSize.height)
        if didUpdateHeight {
            _totalLinesHeight = nil
        }
    }
}

private extension ContentSizeService {
    private func storeWidthOfInitiallyLongestLine() {
        if let longestLine = lineManager.initialLongestLine {
            lineIDTrackingWidth = longestLine.id
            let lineController = lineControllerStorage.getOrCreateLineController(for: longestLine)
            lineController.invalidateEverything()
            lineWidths[longestLine.id] = lineController.lineWidth
            if !isLineWrappingEnabled {
                _longestLineWidth = nil
            }
        }
    }
}
