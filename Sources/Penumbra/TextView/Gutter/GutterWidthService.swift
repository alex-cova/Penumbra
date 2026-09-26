import Foundation
import Combine

final class GutterWidthService {
    var lineManager: LineManager {
        didSet {
            if lineManager !== oldValue {
                _lineNumberWidth = nil
            }
        }
    }
    var font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet {
            if font != oldValue {
                _lineNumberWidth = nil
                widthByCharacterCount.removeAll()
            }
        }
    }
    var showLineNumbers = false {
        didSet {
            if showLineNumbers != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    var showFoldingRibbon = false {
        didSet {
            if showFoldingRibbon != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    var showGutterDecorations = false {
        didSet {
            if showGutterDecorations != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    var gutterDecorationColumnWidth: CGFloat = 16 {
        didSet {
            if gutterDecorationColumnWidth != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    /// Width of the line-marker column between the line numbers and the folding ribbon; 0 hides it.
    var lineMarkerColumnWidth: CGFloat = 0 {
        didSet {
            if lineMarkerColumnWidth != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    var foldingRibbonWidth: CGFloat = 9 {
        didSet {
            if foldingRibbonWidth != oldValue {
                sendGutterWidthUpdatedIfNeeded()
            }
        }
    }
    var gutterLeadingPadding: CGFloat = 0
    var gutterTrailingPadding: CGFloat = 0
    var gutterWidth: CGFloat {
        var width: CGFloat = 0
        if showLineNumbers {
            width += lineNumberWidth + gutterLeadingPadding + gutterTrailingPadding
        }
        if showGutterDecorations {
            width += gutterDecorationColumnWidth
        }
        width += lineMarkerColumnWidth
        if showFoldingRibbon {
            width += foldingRibbonWidth
        }
        return width
    }
    var gutterMinimumCharacterCount: Int? {
        didSet {
            if gutterMinimumCharacterCount != oldValue {
                _lineNumberWidth = nil
                widthByCharacterCount.removeAll()
            }
        }
    }
    var lineNumberWidth: CGFloat {
        let lineCount = lineManager.lineCount
        let hasLineCountChanged = lineCount != previousLineCount
        // Read for every laid-out line: compare identity first, `!=` is an `isEqual:` round trip.
        let hasFontChanged = font !== previousFont && font != previousFont
        if let lineNumberWidth = _lineNumberWidth, !hasLineCountChanged && !hasFontChanged {
            return lineNumberWidth
        } else {
            let lineNumberWidth = computeLineNumberWidth()
            _lineNumberWidth = lineNumberWidth
            previousFont = font
            previousLineCount = lineManager.lineCount
            sendGutterWidthUpdatedIfNeeded()
            return lineNumberWidth
        }
    }
    let didUpdateGutterWidth = PassthroughSubject<Void, Never>()

    private var _lineNumberWidth: CGFloat?
    private var previousLineCount = 0
    private var previousFont: UIFont?
    private var previouslySentGutterWidth: CGFloat?
    /// Measured widths by digit count. Every added or removed line invalidates the width, and
    /// measuring a string was a measurable part of each Return.
    private var widthByCharacterCount: [Int: CGFloat] = [:]

    init(lineManager: LineManager) {
        self.lineManager = lineManager
    }

    func invalidateLineNumberWidth() {
        _lineNumberWidth = nil
    }
}

private extension GutterWidthService {
    private func computeLineNumberWidth() -> CGFloat {
        var characterCount = "\(lineManager.lineCount)".count
        if let gutterMinimumCharacterCount = gutterMinimumCharacterCount, gutterMinimumCharacterCount > characterCount {
            characterCount = gutterMinimumCharacterCount
        }
        if let width = widthByCharacterCount[characterCount] {
            return width
        }
        let wideLineNumberNSString = String(repeating: "8", count: characterCount) as NSString
        let size = wideLineNumberNSString.size(withAttributes: [.font: font])
        let width = ceil(size.width)
        widthByCharacterCount[characterCount] = width
        return width
    }

    private func sendGutterWidthUpdatedIfNeeded() {
        if gutterWidth != previouslySentGutterWidth {
            didUpdateGutterWidth.send()
            previouslySentGutterWidth = gutterWidth
        }
    }
}
