import CoreGraphics
import Foundation

/// Computes the UTF-16 window ``SyntaxParsePolicy/viewport`` should feed to
/// `ts_parser_set_included_ranges`.
enum ViewportParseWindow {
    static func utf16Range(
        lineManager: LineManager,
        stringLength: Int,
        viewport: CGRect,
        overscanScreens: CGFloat = TreeSitterPerformanceConstants.viewportOverscanScreens,
        fullParseLimit: Int = TreeSitterPerformanceConstants.maxSyncContentLength,
        maxWindowLength: Int = TreeSitterPerformanceConstants.maxViewportParseUTF16Length
    ) -> NSRange {
        guard stringLength > 0 else {
            return NSRange(location: 0, length: 0)
        }
        if stringLength <= fullParseLimit {
            return NSRange(location: 0, length: stringLength)
        }

        let (minY, maxY): (CGFloat, CGFloat)
        if viewport.height > 0 {
            let overscan = viewport.height * max(overscanScreens, 0)
            minY = viewport.minY - overscan
            maxY = viewport.maxY + overscan
        } else {
            minY = 0
            maxY = lineManager.estimatedLineHeight * 80
        }

        // Row lookups only (they clamp to the document): this runs for every viewport parse, and
        // handles would pile up for rows nothing else keeps.
        let startRow = lineManager.row(containingYOffset: minY) ?? 0
        let endRow = lineManager.row(containingYOffset: maxY) ?? max(lineManager.lineCount - 1, 0)
        let endLine = lineManager.lineInfo(atRow: endRow)
        var start = lineManager.location(ofRow: startRow)
        var end = endLine.location + endLine.totalLength

        if end - start > maxWindowLength {
            let visibleY = max(viewport.minY, 0)
            let visibleRow = lineManager.row(containingYOffset: visibleY) ?? startRow
            start = lineManager.location(ofRow: visibleRow)
            end = min(stringLength, start + maxWindowLength)
        }

        start = min(max(start, 0), stringLength)
        end = min(max(end, start), stringLength)
        if end == start {
            // Trailing empty line or a collapsed window: keep a real slice ending at `end`.
            start = max(0, end - min(maxWindowLength, end))
        }
        if end - start > maxWindowLength {
            start = max(0, end - maxWindowLength)
        }
        return NSRange(location: start, length: end - start)
    }

    static func textRange(for utf16Range: NSRange, lineManager: LineManager) -> TreeSitterTextRange? {
        guard utf16Range.length > 0,
              let startPosition = lineManager.linePosition(at: utf16Range.location) else {
            return nil
        }
        let endLocation = NSMaxRange(utf16Range)
        let endPosition = lineManager.linePosition(at: endLocation) ?? {
            let lastLine = lineManager.lineInfo(atRow: lineManager.lineCount - 1)
            return LinePosition(row: lastLine.row, column: lastLine.totalLength)
        }()
        return TreeSitterTextRange(
            startPoint: TreeSitterTextPoint(startPosition),
            endPoint: TreeSitterTextPoint(endPosition),
            startByte: ByteCount(utf16Length: utf16Range.location),
            endByte: ByteCount(utf16Length: endLocation)
        )
    }

    static func shift(_ range: NSRange, utf16Location: Int, oldLength: Int, newLength: Int) -> NSRange {
        let oldEnd = utf16Location + oldLength
        let delta = newLength - oldLength
        if range.upperBound <= utf16Location {
            return range
        }
        if range.location >= oldEnd {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let newStart = min(range.location, utf16Location)
        let shiftedEnd = max(range.upperBound + delta, utf16Location + newLength)
        return NSRange(location: newStart, length: max(0, shiftedEnd - newStart))
    }
}

extension NSRange {
    func containsUTF16Range(_ other: NSRange) -> Bool {
        other.location >= location && NSMaxRange(other) <= NSMaxRange(self)
    }
}
