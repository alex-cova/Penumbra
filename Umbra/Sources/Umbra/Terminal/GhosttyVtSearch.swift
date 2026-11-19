import Foundation
import GhosttyVt

/// One match drawn in the viewport: inclusive cell range in viewport coordinates.
struct GhosttySearchHighlight: Equatable, Sendable {
    var from: GhosttyCellPoint
    var to: GhosttyCellPoint
    var isSelected: Bool
}

/// A cell position in viewport coordinates.
struct GhosttyCellPoint: Equatable, Sendable {
    var col: Int
    var row: Int
}

/// What the find bar shows and the view draws, read after a search step.
struct GhosttySearchState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Still reading scrollback; more matches may come.
        case searching
        /// Caught up with the terminal as of the last feed.
        case complete
    }

    var status: Status = .complete
    /// Matches on the active screen (primary screen with its scrollback, or the alternate screen).
    var total = 0
    /// Newest-to-oldest index of the selected match (0 is the newest), nil when none is selected.
    var selectedIndex: Int?
    /// Matches on the rows the viewport shows, clipped to it.
    var highlights: [GhosttySearchHighlight] = []

    static let idle = GhosttySearchState()
}

/// Find-bar search over the terminal's screen and scrollback, through libghostty-vt's own
/// `ghostty_search_*` (search.h). Nothing here keeps a copy of the output: the library searches the
/// terminal's pages and keeps its results in step with scrollback eviction.
///
/// Every call reads or writes the terminal, so all of them run on the terminal queue. Grid
/// references are converted to viewport points before leaving the queue (they are only valid until
/// the next mutation).
extension GhosttyVtTerminal {
    /// Sets what to look for; nil or empty clears the search and its results. Setting the same
    /// needle again (ASCII case aside) keeps the results.
    func setSearchNeedle(_ needle: String?) {
        queue.sync {
            guard let term = terminal else { return }
            let text = needle ?? ""
            if text.isEmpty {
                guard let search else { return }
                // A NULL value clears the needle and releases what it tracks in the terminal.
                ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
                return
            }
            if search == nil {
                var created: GhosttySearch?
                guard ghostty_search_new(nil, &created, term) == GHOSTTY_SUCCESS, let created else { return }
                search = created
            }
            guard let search else { return }
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                var value = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
                _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &value)
            }
        }
    }

    /// Catches the search up with the terminal by one bounded step: one feed (re-scans the active
    /// area and the viewport, hands the next chunk of scrollback over), then up to `tickBudget`
    /// ticks. Call again while the result says `.searching`.
    func stepSearch(tickBudget: Int = 64) -> GhosttySearchState {
        queue.sync {
            guard let search, terminal != nil else { return .idle }
            ghostty_search_feed(search)
            var status = GHOSTTY_SEARCH_STATUS_RUNNING
            var ticks = 0
            while ticks < tickBudget {
                guard ghostty_search_tick(search, &status) == GHOSTTY_SUCCESS else { break }
                ticks += 1
                if status != GHOSTTY_SEARCH_STATUS_RUNNING { break }
            }
            return readSearchState(search)
        }
    }

    /// Selects the next match toward older output (`forward`, what Return does) or the previous one
    /// toward newer output, wrapping at either end, and scrolls the viewport to it when it is not
    /// already showing.
    func selectSearchMatch(forward: Bool) -> GhosttySearchState {
        queue.sync {
            guard let search, terminal != nil else { return .idle }
            _ = forward ? ghostty_search_select_next(search) : ghostty_search_select_prev(search)
            // Selecting scrolls the viewport; the viewport match list is refreshed by a feed.
            ghostty_search_feed(search)
            return readSearchState(search)
        }
    }

    /// Runs on the queue.
    private func readSearchState(_ search: GhosttySearch) -> GhosttySearchState {
        var state = GhosttySearchState()
        var status = GHOSTTY_SEARCH_STATUS_COMPLETE
        if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_STATUS, &status) == GHOSTTY_SUCCESS {
            state.status = status == GHOSTTY_SEARCH_STATUS_COMPLETE ? .complete : .searching
        }
        var total = 0
        if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total) == GHOSTTY_SUCCESS {
            state.total = total
        }
        var index = 0
        if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS {
            state.selectedIndex = index
        }
        guard let term = terminal else { return state }
        let viewportRows = viewportRowCount(term)

        var selected: (GhosttyCellPoint, GhosttyCellPoint)?
        var match = GhosttySelection()
        if state.selectedIndex != nil,
           ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == GHOSTTY_SUCCESS {
            selected = viewportRange(match, terminal: term, rows: viewportRows)
        }

        var query = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        let first = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &query)
        var matches: [GhosttySelection] = []
        if first == GHOSTTY_OUT_OF_SPACE, query.len > 0 {
            matches = [GhosttySelection](repeating: GhosttySelection(), count: query.len)
            let written = matches.withUnsafeMutableBufferPointer { buffer -> Int in
                var out = GhosttySelectionBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &out) == GHOSTTY_SUCCESS else { return 0 }
                return out.len
            }
            matches = Array(matches.prefix(written))
        }
        var highlights: [GhosttySearchHighlight] = []
        highlights.reserveCapacity(matches.count)
        for candidate in matches {
            guard let range = viewportRange(candidate, terminal: term, rows: viewportRows) else { continue }
            let isSelected = selected.map { $0.0 == range.0 && $0.1 == range.1 } ?? false
            highlights.append(GhosttySearchHighlight(from: range.0, to: range.1, isSelected: isSelected))
        }
        // The selected match is drawn even if the page-level viewport list missed it.
        if let selected, !highlights.contains(where: \.isSelected) {
            highlights.append(GhosttySearchHighlight(from: selected.0, to: selected.1, isSelected: true))
        }
        state.highlights = highlights
        return state
    }

    private func viewportRowCount(_ term: GhosttyTerminal) -> Int {
        var rows: UInt16 = 0
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &rows) == GHOSTTY_SUCCESS else { return 0 }
        return Int(rows)
    }

    /// The match's cells in viewport coordinates, clipped to the viewport: an end that scrolled out
    /// becomes the viewport's first or last cell; a match with both ends out is not shown.
    private func viewportRange(
        _ selection: GhosttySelection, terminal term: GhosttyTerminal, rows: Int
    ) -> (GhosttyCellPoint, GhosttyCellPoint)? {
        func point(_ ref: GhosttyGridRef) -> GhosttyCellPoint? {
            var ref = ref
            var coordinate = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(term, &ref, GHOSTTY_POINT_TAG_VIEWPORT, &coordinate) == GHOSTTY_SUCCESS,
                  Int(coordinate.y) < rows
            else { return nil }
            return GhosttyCellPoint(col: Int(coordinate.x), row: Int(coordinate.y))
        }
        let start = point(selection.start)
        let end = point(selection.end)
        switch (start, end) {
        case let (start?, end?):
            return (start, end)
        case let (nil, end?):
            return (GhosttyCellPoint(col: 0, row: 0), end)
        case let (start?, nil) where rows > 0:
            return (start, GhosttyCellPoint(col: Int(UInt16.max), row: rows - 1))
        default:
            return nil
        }
    }
}
