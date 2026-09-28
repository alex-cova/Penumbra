import Foundation

/// Pure computation for "toggle block comment" (⌥⌘/): wraps the selection (or the caret's line) in
/// the language's block-comment delimiters, or removes them when the selection or caret is
/// already inside one. Computes edits and the selections that follow them; mutates nothing.
///
/// Comments are found by scanning text in a bounded window around each selection, so cost never
/// depends on document size. The scan does not know about strings, so a `/*` inside a string
/// literal counts as a comment start.
struct BlockCommentService {
    let delimiters: BlockCommentDelimiters
    let documentLength: Int
    /// Text of a UTF-16 range, or nil when the range is invalid.
    let substring: (NSRange) -> String?

    /// UTF-16 units read on each side of a caret.
    static let window = 4096

    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        /// For an insertion: whether a caret sitting exactly at its location ends up after the
        /// inserted text (true for an opening delimiter, false for a closing one).
        var movesCaretAtLocation = false

        var delta: Int { replacement.utf16.count - range.length }
    }

    struct Result: Equatable {
        /// Ascending, non-overlapping.
        let edits: [Edit]
        /// One per input selection, in input order, in post-edit coordinates.
        let selections: [NSRange]
    }

    private struct Plan {
        var edits: [Edit]
        var selection: NSRange
        /// A caret that lands inside its own insertion, at this offset from the insertion start.
        var caretOffsetInInsertion: Int?
    }

    func toggle(_ selections: [NSRange]) -> Result? {
        let order = selections.indices.sorted { selections[$0].location < selections[$1].location }
        var accepted: [(index: Int, plan: Plan)] = []
        var edits: [Edit] = []
        var lastEnd = 0
        for index in order {
            guard let plan = plan(for: selections[index]), let first = plan.edits.first,
                  let last = plan.edits.last, first.range.location >= lastEnd else {
                continue
            }
            edits.append(contentsOf: plan.edits)
            lastEnd = last.range.upperBound
            accepted.append((index, plan))
        }
        guard !edits.isEmpty else {
            return nil
        }
        var result = selections
        for index in selections.indices {
            let plan = accepted.first { $0.index == index }?.plan
            let original = selections[index]
            if let plan, let offset = plan.caretOffsetInInsertion, let insertion = plan.edits.first,
               let position = edits.firstIndex(of: insertion) {
                let shift = edits[..<position].reduce(0) { $0 + $1.delta }
                result[index] = NSRange(location: insertion.range.location + shift + offset, length: 0)
            } else {
                let source = plan?.selection ?? original
                let start = Self.map(source.location, through: edits)
                let end = Self.map(source.upperBound, through: edits)
                result[index] = NSRange(location: start, length: max(0, end - start))
            }
        }
        return Result(edits: edits, selections: result)
    }

    /// Where `location` ends up once `edits` (ascending, non-overlapping) are applied.
    static func map(_ location: Int, through edits: [Edit]) -> Int {
        var offset = 0
        for edit in edits {
            let lower = edit.range.location
            if edit.range.length == 0 {
                // An insertion at the location itself only moves it when it is an opening delimiter.
                if lower < location || (lower == location && edit.movesCaretAtLocation) {
                    offset += edit.delta
                } else if lower > location {
                    break
                }
            } else if edit.range.upperBound <= location {
                offset += edit.delta
            } else if lower < location {
                return lower + offset
            } else {
                break
            }
        }
        return location + offset
    }

    // MARK: - Planning

    private func plan(for range: NSRange) -> Plan? {
        guard range.location >= 0, range.upperBound <= documentLength else {
            return nil
        }
        return range.length > 0 ? planSelection(range) : planCaret(range.location)
    }

    private func planSelection(_ range: NSRange) -> Plan? {
        guard let text = substring(range) else {
            return nil
        }
        let content = text as NSString
        if let edits = unwrapEditsForSelectionEnclosingComment(range: range, content: content) {
            return Plan(edits: edits, selection: range)
        }
        if let edits = unwrapEditsForSelectionInsideComment(range: range, content: content) {
            return Plan(edits: edits, selection: range)
        }
        guard !text.contains(delimiters.close) else {
            return nil
        }
        return Plan(edits: wrapEdits(start: range.location, end: range.upperBound), selection: range)
    }

    private func wrapEdits(start: Int, end: Int) -> [Edit] {
        [
            Edit(range: NSRange(location: start, length: 0), replacement: delimiters.open + " ", movesCaretAtLocation: true),
            Edit(range: NSRange(location: end, length: 0), replacement: " " + delimiters.close)
        ]
    }

    /// The selection is `/* … */` itself (ignoring whitespace around it).
    private func unwrapEditsForSelectionEnclosingComment(range: NSRange, content: NSString) -> [Edit]? {
        var first = 0
        var last = content.length
        while first < last, Self.isWhitespace(content.character(at: first)) { first += 1 }
        while last > first, Self.isWhitespace(content.character(at: last - 1)) { last -= 1 }
        let open = delimiters.open as NSString
        let close = delimiters.close as NSString
        guard last - first >= open.length + close.length,
              content.range(of: delimiters.open, options: .anchored,
                            range: NSRange(location: first, length: last - first)).location != NSNotFound,
              content.range(of: delimiters.close, options: [.anchored, .backwards],
                            range: NSRange(location: first, length: last - first)).location != NSNotFound else {
            return nil
        }
        let closeStart = last - close.length
        // The first close after the open must be the final one, or this is two comments.
        let firstClose = content.range(of: delimiters.close,
                                       range: NSRange(location: first + open.length,
                                                      length: last - first - open.length))
        guard firstClose.location == closeStart else {
            return nil
        }
        return unwrapEdits(openStart: range.location + first, closeStart: range.location + closeStart)
    }

    /// The selection sits between `/*` and `*/` (whitespace allowed between).
    private func unwrapEditsForSelectionInsideComment(range: NSRange, content: NSString) -> [Edit]? {
        guard !(content as String).contains(delimiters.close) else {
            return nil
        }
        let beforeStart = max(0, range.location - Self.window)
        let afterEnd = min(documentLength, range.upperBound + Self.window)
        guard let before = substring(NSRange(location: beforeStart, length: range.location - beforeStart)),
              let after = substring(NSRange(location: range.upperBound, length: afterEnd - range.upperBound)) else {
            return nil
        }
        let beforeText = before as NSString
        let afterText = after as NSString
        var beforeEnd = beforeText.length
        while beforeEnd > 0, Self.isWhitespace(beforeText.character(at: beforeEnd - 1)) { beforeEnd -= 1 }
        var afterStart = 0
        while afterStart < afterText.length, Self.isWhitespace(afterText.character(at: afterStart)) { afterStart += 1 }
        let openLength = (delimiters.open as NSString).length
        guard beforeEnd >= openLength,
              beforeText.substring(with: NSRange(location: beforeEnd - openLength, length: openLength)) == delimiters.open,
              afterText.range(of: delimiters.close, options: .anchored,
                              range: NSRange(location: afterStart, length: afterText.length - afterStart)).location != NSNotFound else {
            return nil
        }
        return unwrapEdits(openStart: beforeStart + beforeEnd - openLength,
                           closeStart: range.upperBound + afterStart)
    }

    private func planCaret(_ caret: Int) -> Plan? {
        let start = max(0, caret - Self.window)
        let end = min(documentLength, caret + Self.window)
        guard let window = substring(NSRange(location: start, length: end - start)) else {
            return nil
        }
        let text = window as NSString
        let local = caret - start
        if let (openStart, closeStart) = enclosingComment(around: local, in: text) {
            guard let edits = unwrapEdits(openStart: start + openStart, closeStart: start + closeStart) else {
                return nil
            }
            return Plan(edits: edits, selection: NSRange(location: caret, length: 0))
        }
        return planLine(caret: caret, windowStart: start, windowEnd: end, text: text)
    }

    /// Local offsets of the `open` and `close` delimiters of the comment holding `caret`, if any.
    private func enclosingComment(around caret: Int, in text: NSString) -> (Int, Int)? {
        let openLength = (delimiters.open as NSString).length
        let before = text.range(of: delimiters.open, options: .backwards,
                                range: NSRange(location: 0, length: caret))
        guard before.location != NSNotFound else {
            return nil
        }
        let openEnd = before.location + openLength
        let bodyStart = min(openEnd, caret)
        // A close between the open and the caret means the comment ended before the caret.
        if text.range(of: delimiters.close,
                      range: NSRange(location: bodyStart, length: caret - bodyStart)).location != NSNotFound {
            return nil
        }
        let closeSearchStart = max(caret, openEnd)
        let after = text.range(of: delimiters.close,
                               range: NSRange(location: closeSearchStart, length: text.length - closeSearchStart))
        guard after.location != NSNotFound else {
            return nil
        }
        return (before.location, after.location)
    }

    private func planLine(caret: Int, windowStart: Int, windowEnd: Int, text: NSString) -> Plan? {
        let local = caret - windowStart
        var lineStart = local
        while lineStart > 0, !Self.isLineBreak(text.character(at: lineStart - 1)) { lineStart -= 1 }
        var lineEnd = local
        while lineEnd < text.length, !Self.isLineBreak(text.character(at: lineEnd)) { lineEnd += 1 }
        // A line running past the window is not scanned.
        guard lineStart > 0 || windowStart == 0, lineEnd < text.length || windowEnd == documentLength else {
            return nil
        }
        var first = lineStart
        var last = lineEnd
        while first < last, Self.isBlank(text.character(at: first)) { first += 1 }
        while last > first, Self.isBlank(text.character(at: last - 1)) { last -= 1 }
        if first == last {
            let inserted = delimiters.open + "  " + delimiters.close
            let edit = Edit(range: NSRange(location: caret, length: 0), replacement: inserted)
            return Plan(edits: [edit], selection: NSRange(location: caret, length: 0),
                        caretOffsetInInsertion: (delimiters.open as NSString).length + 1)
        }
        let content = text.substring(with: NSRange(location: first, length: last - first))
        guard !content.contains(delimiters.close) else {
            return nil
        }
        return Plan(edits: wrapEdits(start: windowStart + first, end: windowStart + last),
                    selection: NSRange(location: caret, length: 0))
    }

    /// Removal of the opening and closing delimiter, each with one adjoining space when present.
    private func unwrapEdits(openStart: Int, closeStart: Int) -> [Edit]? {
        let openLength = (delimiters.open as NSString).length
        let closeLength = (delimiters.close as NSString).length
        let openEnd = openStart + openLength
        guard closeStart >= openEnd else {
            return nil
        }
        var openRemoval = NSRange(location: openStart, length: openLength)
        if openEnd < closeStart, substring(NSRange(location: openEnd, length: 1)) == " " {
            openRemoval.length += 1
        }
        var closeRemoval = NSRange(location: closeStart, length: closeLength)
        if closeStart - 1 >= openRemoval.upperBound, substring(NSRange(location: closeStart - 1, length: 1)) == " " {
            closeRemoval = NSRange(location: closeStart - 1, length: closeLength + 1)
        }
        return [Edit(range: openRemoval, replacement: ""), Edit(range: closeRemoval, replacement: "")]
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }
}
