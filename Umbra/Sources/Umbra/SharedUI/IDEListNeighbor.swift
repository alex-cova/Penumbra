import Foundation

/// Moves a keyboard selection through a flat list. With none selected, down picks the first and
/// up the last; further presses stop at the ends.
enum IDEListNeighbor {
    static func move<Item: Equatable>(_ selected: Item?, in items: [Item], by delta: Int) -> Item? {
        guard !items.isEmpty else { return nil }
        if let selected, let current = items.firstIndex(of: selected) {
            return items[min(max(current + delta, 0), items.count - 1)]
        }
        return delta < 0 ? items.last : items.first
    }
}
