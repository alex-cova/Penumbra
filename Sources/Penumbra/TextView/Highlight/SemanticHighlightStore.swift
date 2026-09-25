import Foundation

/// Highlights a host computes outside the tree-sitter query (Java semantic tokens, say) and paints
/// over the tree-sitter colours. Positions are UTF-16 offsets into the document.
///
/// Shared between the main thread (which sets and edits it) and the line highlighter (which may
/// read it off the main thread), so access is locked. Edits keep it aligned with the text until the
/// host delivers a fresh set: highlights overlapping an edit are dropped, later ones shift.
final class SemanticHighlightStore: @unchecked Sendable {
    private let lock = NSLock()
    private var highlights: [SyntaxHighlightRange] = []

    func set(_ newHighlights: [SyntaxHighlightRange]) {
        let sorted = newHighlights.sorted { $0.range.location < $1.range.location }
        lock.lock()
        highlights = sorted
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return highlights.isEmpty
    }

    /// The highlights intersecting `range`, in position order.
    func highlights(intersecting range: NSRange) -> [SyntaxHighlightRange] {
        lock.lock()
        defer { lock.unlock() }
        // Binary search for the first highlight that could reach `range`; highlights don't nest,
        // so ordering by start is enough.
        var low = 0
        var high = highlights.count
        while low < high {
            let mid = (low + high) / 2
            if highlights[mid].range.upperBound <= range.location { low = mid + 1 } else { high = mid }
        }
        var result: [SyntaxHighlightRange] = []
        var index = low
        while index < highlights.count, highlights[index].range.location < range.upperBound {
            result.append(highlights[index])
            index += 1
        }
        return result
    }

    /// `range` of the old text was replaced by `newLength` UTF-16 units.
    func applyEdit(range: NSRange, newLength: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !highlights.isEmpty else { return }
        let delta = newLength - range.length
        var kept: [SyntaxHighlightRange] = []
        kept.reserveCapacity(highlights.count)
        for highlight in highlights {
            if highlight.range.upperBound <= range.location {
                kept.append(highlight)
            } else if highlight.range.location >= range.upperBound {
                kept.append(SyntaxHighlightRange(
                    range: NSRange(location: highlight.range.location + delta, length: highlight.range.length),
                    highlightName: highlight.highlightName
                ))
            }
        }
        highlights = kept
    }

    /// UTF-16 ranges whose semantic token spans changed between the stored set and `newHighlights`.
    func lineRanges(affectedByReplacing newHighlights: [SyntaxHighlightRange]) -> [NSRange] {
        lock.lock()
        let previous = highlights
        lock.unlock()
        let sorted = newHighlights.sorted { $0.range.location < $1.range.location }
        guard previous != sorted else {
            return []
        }
        if previous.isEmpty {
            return sorted.map(\.range)
        }
        var affected: [NSRange] = []
        for highlight in sorted where !previous.contains(highlight) {
            affected.append(highlight.range)
        }
        for highlight in previous where !sorted.contains(highlight) {
            affected.append(highlight.range)
        }
        return affected
    }
}
