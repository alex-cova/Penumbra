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

        let startLine: DocumentLineNode
        if let line = lineManager.line(containingYOffset: max(minY, 0)) {
            startLine = line
        } else if minY > 0 {
            startLine = lineManager.lastLine
        } else {
            startLine = lineManager.firstLine
        }
        let endLine = lineManager.line(containingYOffset: maxY) ?? lineManager.lastLine
        var start = Int(startLine.location)
        var end = Int(endLine.location) + endLine.data.totalLength

        if end - start > maxWindowLength {
            let visibleY = max(viewport.minY, 0)
            let visibleLine: DocumentLineNode
            if let line = lineManager.line(containingYOffset: visibleY) {
                visibleLine = line
            } else if visibleY > 0 {
                visibleLine = lineManager.lastLine
            } else {
                visibleLine = startLine
            }
            start = Int(visibleLine.location)
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
        let endPosition = lineManager.linePosition(at: endLocation)
            ?? LinePosition(row: lineManager.lastLine.index, column: lineManager.lastLine.data.totalLength)
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
