import CoreGraphics
import Foundation

/// How strongly each end of a tab row fades, from 0 (not at all) to 1.
/// Ported from Silica's `EdgeFades` (EditorArea.swift).
struct IDEEdgeFades: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    init() {}

    /// Each end fades in over the first `distance` points of row scrolled out past it.
    init(leading: CGFloat, trailing: CGFloat, over distance: CGFloat) {
        self.leading = min(max(leading / distance, 0), 1)
        self.trailing = min(max(trailing / distance, 0), 1)
    }
}

/// A tab bar's row as it's laid out, which a drag along it is worked out from.
/// Ported from Silica's `TabBarLayout`, keyed by Umbra's document IDs.
struct IDETabBarLayout: Equatable {
    let tabs: [UUID]
    /// Each tab's laid-out width.
    let widths: [UUID: CGFloat]
    /// The gap between two tabs, and the room before the first and after the last.
    let spacing: CGFloat
    let inset: CGFloat
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    let barWidth: CGFloat
    let scrollOffset: CGFloat

    /// The tab at a horizontal position in the bar, if there's one.
    func tab(at x: CGFloat) -> UUID? {
        var leading = inset - scrollOffset
        for tab in tabs {
            let width = widths[tab] ?? 0
            if x >= leading && x < leading + width { return tab }
            leading += width + spacing
        }
        return nil
    }
}

/// A tab being dragged to another place in its bar. Ported from Silica's `TabDrag`.
struct IDETabDrag: Equatable {
    let tab: UUID
    /// Horizontal distance the pointer has moved since the drag began.
    var translation: CGFloat
    /// The pointer's horizontal position in the tab bar.
    var location: CGFloat
    /// How far the row was scrolled when the drag began.
    let startScrollOffset: CGFloat

    /// Where the dragged tab would land if dropped now, and how far each tab sits
    /// from its place in the row meanwhile: the dragged one follows the pointer,
    /// and the tabs it has passed step aside by its width. The order itself
    /// changes on drop.
    func reorder(in bar: IDETabBarLayout) -> (destination: Int, offsets: [UUID: CGFloat])? {
        let tabs = bar.tabs
        guard let source = tabs.firstIndex(of: tab) else { return nil }
        let widths = tabs.map { bar.widths[$0] ?? 0 }
        let strides = widths.map { $0 + bar.spacing }
        let before = strides[..<source].reduce(0, +)
        let after = strides[(source + 1)...].reduce(0, +)

        var offset = translation + bar.scrollOffset - startScrollOffset
        if bar.barWidth > 0 {
            let leading = bar.scrollOffset - (bar.inset + before)
            offset = max(min(offset, leading + bar.barWidth - widths[source]), leading)
        }
        offset = min(max(offset, -before), after)

        // A neighbor is passed once the dragged tab's edge crosses its middle.
        let neighbors = offset > 0 ? Array((source + 1)..<tabs.count) : Array((0..<source).reversed())
        var destination = source
        var passed: CGFloat = 0
        for index in neighbors {
            guard abs(offset) > passed + bar.spacing + widths[index] / 2 else { break }
            passed += strides[index]
            destination = index
        }

        var offsets = [tab: offset]
        let slot = destination > source ? -strides[source] : strides[source]
        for index in min(source, destination)...max(source, destination) where index != source {
            offsets[tabs[index]] = slot
        }
        return (destination, offsets)
    }

    /// Where the row should be scrolled to after `elapsed` seconds of the tab
    /// being held near an end of the bar; `nil` when the row needn't move.
    func autoscrollOffset(in bar: IDETabBarLayout, elapsed: TimeInterval) -> CGFloat? {
        guard bar.barWidth > 0 else { return nil }
        let zone: CGFloat = 40
        let rate: CGFloat = 10
        var depth: CGFloat = 0
        if translation > 0 {
            depth = max(location - (bar.barWidth - zone), 0)
        } else if translation < 0 {
            depth = min(location - zone, 0)
        }
        let speed = min(max(depth, -2 * zone), 2 * zone) * rate
        let rowWidth = bar.tabs.reduce(2 * bar.inset - bar.spacing) { $0 + (bar.widths[$1] ?? 0) + bar.spacing }
        let target = min(max(bar.scrollOffset + speed * CGFloat(elapsed), 0), max(rowWidth - bar.barWidth, 0))
        return target == bar.scrollOffset ? nil : target
    }
}

enum IDETabDragEvent {
    case moved(translation: CGFloat, location: CGFloat)
    case dropped(translation: CGFloat)
    case cancelled
}
