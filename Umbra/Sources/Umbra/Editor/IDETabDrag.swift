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

    /// Where a tab starts in the bar, scroll included.
    func minX(of tab: UUID) -> CGFloat? {
        var leading = inset - scrollOffset
        for other in tabs {
            if other == tab { return leading }
            leading += (widths[other] ?? 0) + spacing
        }
        return nil
    }

    /// Where a dragged tab whose centre is at `x` would sit among the other tabs: how many of them
    /// have their middle before it. Worked out on the row without the dragged tab and without any
    /// gap, so it does not move with the tabs it makes room by.
    func insertionIndex(forCenterX x: CGFloat, excluding dragged: UUID?) -> Int {
        var leading = inset - scrollOffset
        var index = 0
        for tab in tabs where tab != dragged {
            let width = widths[tab] ?? 0
            guard x > leading + width / 2 else { break }
            index += 1
            leading += width + spacing
        }
        return index
    }

    /// How far each tab sits from its place in the row while a tab is being dragged: the row
    /// closes over `dragged` (when it belongs to this bar) and opens a gap `gapWidth` wide before
    /// the tab at `index` among the others (none when `index` is nil, or past the last tab).
    /// One rule for the three cases: the gap moving in the bar the tab came from, closing when the
    /// tab leaves it, and opening in a bar it is over. Tabs that stay put have no entry.
    func gapOffsets(excluding dragged: UUID?, insertingAt index: Int?, gapWidth: CGFloat) -> [UUID: CGFloat] {
        guard dragged != nil || index != nil else { return [:] }
        let gap = gapWidth + spacing
        var current = inset - scrollOffset
        var shifted = current
        var slot = 0
        var offsets: [UUID: CGFloat] = [:]
        for tab in tabs {
            let width = widths[tab] ?? 0
            if tab != dragged {
                if slot == index { shifted += gap }
                let delta = shifted - current
                if delta != 0 { offsets[tab] = delta }
                shifted += width + spacing
                slot += 1
            }
            current += width + spacing
        }
        return offsets
    }

    /// Where the row should be scrolled to after `elapsed` seconds of a dragged tab being held at
    /// `x` (in the bar) near one of its ends; `nil` when the row needn't move.
    func autoscrollOffset(pointerX x: CGFloat, elapsed: TimeInterval) -> CGFloat? {
        guard barWidth > 0 else { return nil }
        let zone: CGFloat = 40
        let rate: CGFloat = 10
        let depth = x > barWidth / 2 ? max(x - (barWidth - zone), 0) : min(x - zone, 0)
        let speed = min(max(depth, -2 * zone), 2 * zone) * rate
        let rowWidth = tabs.reduce(2 * inset - spacing) { $0 + (widths[$1] ?? 0) + spacing }
        let target = min(max(scrollOffset + speed * CGFloat(elapsed), 0), max(rowWidth - barWidth, 0))
        return target == scrollOffset ? nil : target
    }
}

/// A tab bar's layout and where its row starts in the editor panes' space, which is where a drag's
/// pointer is measured.
struct IDETabBarGeometry: Equatable {
    var layout: IDETabBarLayout
    var origin: CGPoint
}
