import Foundation

/// Per-line cache of built `MinimapRow`s. Rebuilt each frame keeping only the rows actually
/// visited, so it stays O(visible band) with no fixed cap and no wholesale-clear stutter. A
/// change to any invalidation input (document epoch, theme, column budget, tab width) drops
/// everything; an edit or a reparse drops only the lines it touched (``remove(_:)``).
final class MinimapRowCache {
    private struct Stamp: Equatable {
        var documentEpoch: UInt64
        var themeGeneration: UInt64
        var maxColumns: Int
        var tabLength: Int
    }

    private var stamp: Stamp?
    private var rows: [DocumentLineNodeID: MinimapRow] = [:]
    /// Lines whose cached row is a provisional flat bar drawn while syntax was still parsing.
    private var provisional: Set<DocumentLineNodeID> = []
    private var visited: Set<DocumentLineNodeID> = []

    /// Call once at the top of a draw. Returns having cleared the cache if any invalidation
    /// input changed.
    func beginFrame(documentEpoch: UInt64,
                    themeGeneration: UInt64,
                    maxColumns: Int,
                    tabLength: Int) {
        let newStamp = Stamp(documentEpoch: documentEpoch,
                             themeGeneration: themeGeneration,
                             maxColumns: maxColumns,
                             tabLength: tabLength)
        if newStamp != stamp {
            rows.removeAll(keepingCapacity: true)
            provisional.removeAll(keepingCapacity: true)
            stamp = newStamp
        }
        visited.removeAll(keepingCapacity: true)
    }

    func cachedRow(for id: DocumentLineNodeID) -> MinimapRow? {
        guard let row = rows[id] else {
            return nil
        }
        visited.insert(id)
        return row
    }

    /// - Parameter provisional: `true` when the row is a flat bar drawn because syntax was not
    ///   ready. Such rows are dropped by ``invalidateProvisionalRows()`` once parsing finishes.
    func store(_ row: MinimapRow, for id: DocumentLineNodeID, provisional isProvisional: Bool) {
        rows[id] = row
        visited.insert(id)
        if isProvisional {
            provisional.insert(id)
        } else {
            provisional.remove(id)
        }
    }

    /// True when the cached row for this line is a provisional flat bar — the caller can then
    /// redraw it flat without re-running a doomed syntax query.
    func isProvisional(_ id: DocumentLineNodeID) -> Bool {
        provisional.contains(id)
    }

    /// Drops the rows of lines whose text or syntax colours changed.
    func remove(_ ids: Set<DocumentLineNodeID>) {
        for id in ids {
            rows.removeValue(forKey: id)
            provisional.remove(id)
        }
    }

    /// Call when a syntax parse finishes so provisional rows recolor on the next draw.
    func invalidateProvisionalRows() {
        for id in provisional {
            rows.removeValue(forKey: id)
        }
        provisional.removeAll(keepingCapacity: true)
    }

    /// Call once at the end of a draw. Evicts everything not visited this frame.
    func endFrame() {
        if rows.count != visited.count {
            rows = rows.filter { visited.contains($0.key) }
        }
        if !provisional.isEmpty {
            provisional.formIntersection(visited)
        }
    }

    func removeAll() {
        stamp = nil
        rows.removeAll(keepingCapacity: true)
        provisional.removeAll(keepingCapacity: true)
        visited.removeAll(keepingCapacity: true)
    }
}
