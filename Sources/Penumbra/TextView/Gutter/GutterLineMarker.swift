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

/// Keeps markers on their lines while the text is edited, until the host sends fresh ones.
enum GutterLineMarkerIndex {
    /// The markers after `range` (whose old text was `deletedText`) was replaced with
    /// `replacementLength` characters. Each marker is anchored at its line's start offset,
    /// `lineStarts[i]` before the edit: an anchor after the edit moves with the text, and an anchor
    /// inside it is dropped when a line break after the anchor was deleted (its line is gone).
    /// `row(of:)` maps an offset in the edited text to its 0-based row.
    static func applyingEdit(
        to markers: [GutterLineMarker], lineStarts: [Int], range: NSRange, deletedText: String,
        replacementLength: Int, row: (Int) -> Int
    ) -> [GutterLineMarker] {
        let deleted = deletedText as NSString
        var result: [GutterLineMarker] = []
        result.reserveCapacity(markers.count)
        for (marker, start) in zip(markers, lineStarts) {
            let newStart: Int
            if start < range.location {
                result.append(marker)
                continue
            } else if start >= range.upperBound {
                newStart = start - range.length + replacementLength
            } else {
                let tail = deleted.substring(from: min(start - range.location, deleted.length))
                if tail.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) { continue }
                newStart = range.location
            }
            var moved = marker
            moved.line = row(newStart) + 1
            result.append(moved)
        }
        return result
    }

    /// Slots the widest line needs, capped at ``GutterLineMarkerView/maximumSlots``.
    static func slotCount(of markers: [GutterLineMarker]) -> Int {
        var perLine: [Int: Int] = [:]
        var widest = 0
        for marker in markers {
            let count = (perLine[marker.line] ?? 0) + 1
            perLine[marker.line] = count
            widest = max(widest, count)
            if widest >= GutterLineMarkerView.maximumSlots { break }
        }
        return min(widest, GutterLineMarkerView.maximumSlots)
    }
}
