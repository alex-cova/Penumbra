import Foundation

/// The glyph of a ``GutterLineMarker``. The names describe object-oriented relationships, so any
/// language can use them.
public enum GutterLineMarkerIcon: String, Hashable, Sendable, CaseIterable {
    /// A member that implements an abstract or interface member (↑).
    case implementing
    /// An abstract member or type that has implementations (↓).
    case implemented
    /// A member that overrides a concrete member (↑).
    case overriding
    /// A concrete member or class that is overridden or subclassed (↓).
    case overridden
    /// A member that implements an interface member on behalf of a subclass (↕).
    case siblingInherited
    /// A call to the method it sits in.
    case recursiveCall
}

/// An icon in the line-marker column, which sits between the line numbers and the folding ribbon.
/// A line shows at most two markers side by side.
public struct GutterLineMarker: Hashable, Sendable {
    /// Passed back to ``TextView/lineMarkerHandler`` so the host can find what the marker stands for.
    public let id: Int
    /// 1-based document line.
    public var line: Int
    public let icon: GutterLineMarkerIcon
    public let tooltip: String

    public init(id: Int, line: Int, icon: GutterLineMarkerIcon, tooltip: String) {
        self.id = id
        self.line = line
        self.icon = icon
        self.tooltip = tooltip
    }
}

/// An edit, in rows, as ``GutterLineMarkerStore/applyEdit(_:)`` needs it. Computed with a constant
/// number of line-manager lookups, however many markers there are.
struct GutterLineMarkerEdit: Equatable {
    /// 0-based row holding the edit's start, before the edit.
    var startRow: Int
    /// Rows the replaced text spanned beyond `startRow` (its line breaks).
    var removedRows: Int
    /// Change in the document's line count.
    var lineDelta: Int
    /// Whether the edit starts exactly at `startRow`'s line start.
    var startsAtLineStart: Bool
    /// Whether the replaced text ended exactly at the start of row `startRow + removedRows`, i.e.
    /// its last character was a line break.
    var endsAtLineStart: Bool
    /// Whether nothing was replaced (a pure insertion).
    var isInsertion: Bool

    /// Rows the replacement text spans beyond `startRow`.
    var insertedRows: Int {
        removedRows + lineDelta
    }
}

/// The markers of the line-marker column, sorted by line, kept on their lines while the text is
/// edited until the host sends fresh ones.
///
/// Like IntelliJ's range markers, an edit costs a constant number of line lookups (done by the
/// caller) plus shifting the markers below it; nothing walks the line tree per marker, and the
/// column width is only recounted when an edit drops or merges markers.
final class GutterLineMarkerStore {
    /// Sorted by line, then by ``GutterLineMarker/id``.
    private(set) var markers: [GutterLineMarker] = []
    /// Slots the busiest line needs, capped at ``GutterLineMarkerView/maximumSlots``.
    private(set) var slotCount = 0

    var isEmpty: Bool {
        markers.isEmpty
    }

    /// Replaces every marker. Sorting is skipped when the host already sends them in order.
    func replace(with newMarkers: [GutterLineMarker]) {
        let isSorted = zip(newMarkers, newMarkers.dropFirst()).allSatisfy { !Self.precedes($1, $0) }
        markers = isSorted ? newMarkers : newMarkers.sorted(by: Self.precedes)
        slotCount = Self.slotCount(ofSorted: markers)
    }

    /// Moves the markers through `edit`. An anchor after the edit moves with the text; one inside
    /// it is dropped when a line break after it was deleted (its line is gone), and the line the
    /// edit ends on merges into the line it starts on. Returns whether any marker moved or went.
    @discardableResult
    func applyEdit(_ edit: GutterLineMarkerEdit) -> Bool {
        let firstAffected = Self.firstIndex(in: markers, atOrAfterLine: edit.startRow + 1)
        guard firstAffected < markers.count else {
            return false
        }
        let endRow = edit.startRow + edit.removedRows
        let tailStart = Self.firstIndex(in: markers, atOrAfterLine: endRow + 2)
        var didChange = false
        var didRegroup = false
        var head: [GutterLineMarker] = []
        head.reserveCapacity(tailStart - firstAffected)
        for marker in markers[firstAffected ..< tailStart] {
            let row = marker.line - 1
            let newRow: Int?
            if row == edit.startRow {
                if edit.startsAtLineStart && edit.isInsertion {
                    newRow = row + edit.insertedRows
                } else if edit.startsAtLineStart && edit.removedRows > 0 {
                    newRow = nil
                } else {
                    newRow = row
                }
            } else if row < endRow {
                newRow = nil
            } else {
                newRow = edit.endsAtLineStart ? edit.startRow + edit.insertedRows : edit.startRow
            }
            guard let newRow else {
                didChange = true
                didRegroup = true
                continue
            }
            if newRow != row {
                didChange = true
                if row != edit.startRow && newRow == edit.startRow {
                    didRegroup = true
                }
            }
            var moved = marker
            moved.line = newRow + 1
            head.append(moved)
        }
        if didChange {
            head.sort(by: Self.precedes)
            markers.replaceSubrange(firstAffected ..< tailStart, with: head)
        }
        let delta = edit.lineDelta
        if delta != 0 {
            let shiftStart = firstAffected + head.count
            if shiftStart < markers.count {
                didChange = true
                markers.withUnsafeMutableBufferPointer { buffer in
                    for index in shiftStart ..< buffer.count {
                        buffer[index].line += delta
                    }
                }
            }
        }
        if didRegroup {
            slotCount = Self.slotCount(ofSorted: markers)
        }
        return didChange
    }

    /// Index of the first marker whose line is at least `line`.
    func firstIndex(atOrAfterLine line: Int) -> Int {
        Self.firstIndex(in: markers, atOrAfterLine: line)
    }

    static func firstIndex(in markers: [GutterLineMarker], atOrAfterLine line: Int) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].line < line { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Slots the busiest line of line-sorted `markers` needs, capped at
    /// ``GutterLineMarkerView/maximumSlots``.
    static func slotCount(ofSorted markers: [GutterLineMarker]) -> Int {
        guard !markers.isEmpty else {
            return 0
        }
        var widest = 1
        var run = 1
        for index in markers.indices.dropFirst() {
            run = markers[index].line == markers[index - 1].line ? run + 1 : 1
            widest = max(widest, run)
            if widest >= GutterLineMarkerView.maximumSlots {
                break
            }
        }
        return min(widest, GutterLineMarkerView.maximumSlots)
    }

    private static func precedes(_ lhs: GutterLineMarker, _ rhs: GutterLineMarker) -> Bool {
        lhs.line == rhs.line ? lhs.id < rhs.id : lhs.line < rhs.line
    }
}
