@preconcurrency import AppKit
import Foundation

/// The boundaries a modified arrow key (or Home/End) moves the caret to.
enum CaretStop {
    /// ⌥←/→: the next word end or previous word start (``WordCaretStops``).
    case word
    /// ⌘←/→, Home/End: the line boundary, Smart Home style (``LineBoundaryNavigator``).
    case line
    /// ⌘↑/↓: the start or end of the document.
    case document
}

extension TextInputView {
    /// Where a caret at `location` lands when moved to `stop` in `direction`, or `nil` when the
    /// boundary can't be resolved.
    func caretStopLocation(_ stop: CaretStop, from location: Int, direction: UITextDirection) -> Int? {
        let forward = direction != .backward
        switch stop {
        case .document:
            return forward ? stringView.length : 0
        case .word:
            return wordStopLocation(from: location, forward: forward)
        case .line:
            return lineStopLocation(from: location, forward: forward)
        }
    }

    /// Moves every caret with `target`, one undo-free selection change. Non-empty selections
    /// stay put, like ``moveAllSelections(in:)``.
    func moveAllSelections(to target: (Int) -> Int?) {
        let newSelections = selectedRanges.map { range -> NSRange in
            guard range.length == 0, let location = target(range.location) else {
                return range
            }
            return NSRange(location: location, length: 0)
        }
        applySelectedRanges(MultiSelectionController.normalize(newSelections))
        if let primary = selection {
            selectionAnchor = primary.length == 0 ? primary.location : primary.upperBound
        }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    /// IntelliJ's Start New Line (⇧⏎): every caret moves to the end of its line and a
    /// language-aware line break is inserted there, so the current line is left intact and the
    /// new one gets the indentation Enter would give it. One undo step.
    func startNewLine() {
        let ranges = selectedRanges
        guard !ranges.isEmpty else {
            return
        }
        let carets = ranges.map { range -> NSRange in
            let row = lineManager.row(containingCharacterAt: range.upperBound) ?? max(lineManager.lineCount - 1, 0)
            let line = lineManager.lineInfo(atRow: row)
            return NSRange(location: line.location + line.length, length: 0)
        }
        applySelectedRanges(carets, notifyDelegate: false)
        if let primary = selection {
            selectionAnchor = primary.location
        }
        insertText(lineEndings.symbol)
    }
}

// MARK: - Word stops
private extension TextInputView {
    /// Scans at most this many UTF-16 units per press, so a huge single-line file can't stall
    /// a keystroke; a word longer than this stops at the window edge.
    static let wordStopWindow = 4096

    func wordStopLocation(from location: Int, forward: Bool) -> Int {
        let length = stringView.length
        let location = min(max(location, 0), length)
        let row = lineManager.row(containingCharacterAt: location) ?? max(lineManager.lineCount - 1, 0)
        let line = lineManager.lineInfo(atRow: row)
        let contentEnd = line.location + line.length
        let camelHumps = isCamelHumpsNavigationEnabled
        if forward {
            guard location < contentEnd else {
                // At the end of the line: the next stop is the start of the next line.
                let nextLineStart = min(line.location + line.totalLength, length)
                return foldingModel.visibleLocationForForwardNavigation(from: max(nextLineStart, location))
            }
            let windowEnd = min(contentEnd, location + Self.wordStopWindow)
            let text = utf16Units(in: NSRange(location: location, length: windowEnd - location))
            return location + WordCaretStops.nextStop(in: text, from: 0, camelHumps: camelHumps)
        }
        guard location > line.location else {
            // At the start of the line: the previous stop is the end of the previous line.
            guard row > 0 else {
                return location
            }
            let previous = lineManager.lineInfo(atRow: row - 1)
            return foldingModel.visibleLocationForBackwardNavigation(from: previous.location + previous.length)
        }
        let windowStart = max(line.location, location - Self.wordStopWindow)
        let text = utf16Units(in: NSRange(location: windowStart, length: location - windowStart))
        return windowStart + WordCaretStops.previousStop(in: text, from: text.count, camelHumps: camelHumps)
    }

    func utf16Units(in range: NSRange) -> [UInt16] {
        guard range.length > 0, let string = stringView.substring(in: range) else {
            return []
        }
        return Array(string.utf16)
    }
}

// MARK: - Line stops
private extension TextInputView {
    func lineStopLocation(from location: Int, forward: Bool) -> Int? {
        let direction: UITextDirection = forward ? .forward : .backward
        guard let fragmentBoundary = (tokenizer.position(from: IndexedPosition(index: location),
                                                         toBoundary: .line,
                                                         inDirection: direction) as? IndexedPosition)?.index else {
            return nil
        }
        guard isSmartHomeEnabled else {
            return fragmentBoundary
        }
        // The fragment boundary is on the visible line the caret is on, even when `location`
        // itself sits at the edge of a collapsed fold.
        guard let row = lineManager.row(containingCharacterAt: fragmentBoundary) else {
            return fragmentBoundary
        }
        let line = navigatorLine(atRow: row)
        let caret = min(max(location, line.start), line.contentEnd)
        if forward {
            return LineBoundaryNavigator.endTarget(caret: caret, line: line, fragmentEnd: fragmentBoundary)
        }
        return LineBoundaryNavigator.homeTarget(caret: caret, line: line, fragmentStart: fragmentBoundary)
    }

    /// The line's whitespace bounds, found by scanning only its leading and trailing
    /// whitespace, never the whole line.
    func navigatorLine(atRow row: Int) -> LineBoundaryNavigator.Line {
        let info = lineManager.lineInfo(atRow: row)
        let start = info.location
        let contentEnd = info.location + info.length
        var first = start
        while first < contentEnd, isBlank(stringView.unichar(at: first)) {
            first += 1
        }
        guard first < contentEnd else {
            return LineBoundaryNavigator.Line(start: start, contentEnd: contentEnd, firstNonWhitespace: nil, lastNonWhitespaceEnd: nil)
        }
        var lastEnd = contentEnd
        while lastEnd > first, isBlank(stringView.unichar(at: lastEnd - 1)) {
            lastEnd -= 1
        }
        return LineBoundaryNavigator.Line(start: start, contentEnd: contentEnd, firstNonWhitespace: first, lastNonWhitespaceEnd: lastEnd)
    }

    func isBlank(_ unit: unichar?) -> Bool {
        unit == 0x20 || unit == 0x09
    }
}
