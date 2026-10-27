import Foundation
import GhosttyVt

/// 8-bit RGB color resolved by libghostty-vt (palette indices already flattened).
struct GhosttyRGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

extension GhosttyRGB {
    init(_ c: GhosttyColorRgb) {
        self.init(r: c.r, g: c.g, b: c.b)
    }
}

/// Cell width class, mirroring `GhosttyCellWide` without leaking the C API.
enum GhosttyCellWidth: Equatable, Sendable {
    case narrow
    case wide
    case spacerTail
    case spacerHead
}

/// Cursor shape, mirroring `GhosttyRenderStateCursorVisualStyle`.
enum GhosttyCursorShape: Equatable, Sendable {
    case block
    case bar
    case underline
    case hollow
}

/// One grid cell in a render snapshot.
struct GhosttySnapshotCell: Sendable {
    /// Full grapheme cluster as text. Empty for spacer/wide-tail cells.
    var text: String = ""
    var wide: GhosttyCellWidth = .narrow
    /// Resolved colors; nil means "use the terminal default".
    var fg: GhosttyRGB?
    var bg: GhosttyRGB?
    var bold = false
    var italic = false
    var faint = false
    var blink = false
    var inverse = false
    var invisible = false
    var strikethrough = false
    var overline = false
    /// One of `GHOSTTY_SGR_UNDERLINE_*`; 0/1 roughly means off/single.
    var underline = 0
}

struct GhosttySnapshotRow: Sendable {
    var cells: [GhosttySnapshotCell] = []
    /// True when this row continues a soft-wrapped line from the row above.
    var wrapContinuation = false
}

struct GhosttySnapshotCursor: Sendable {
    var x = 0
    var y = 0
    var hasPosition = false
    var visible = false
    var blinking = false
    var style: GhosttyCursorShape = .block
}

struct GhosttyRenderSnapshot: Sendable {
    var cols = 0
    var rows = 0
    var grid: [GhosttySnapshotRow] = []
    var cursor = GhosttySnapshotCursor()
    var fg = GhosttyRGB(r: 255, g: 255, b: 255)
    var bg = GhosttyRGB(r: 0, g: 0, b: 0)
}

extension GhosttyVtTerminal {
    /// Pulls a full-grid value snapshot through the render state.
    ///
    /// Must be called from outside the terminal queue (it hops there); the
    /// result is a plain value snapshot safe to read on any thread (e.g.
    /// the main thread during `draw`). Cost is O(visible rows × cols).
    /// Per-frame dirty-region optimization (`next_dirty` + `clean`) is
    /// future work for the view; correctness first.
    func renderSnapshot() -> GhosttyRenderSnapshot? {
        queue.sync {
            guard let term = self.terminal, let state = self.renderState else { return nil }
            guard ghostty_render_state_update(state, term) == GHOSTTY_SUCCESS else { return nil }

            var snapshot = GhosttyRenderSnapshot()
            var cols: UInt16 = 0
            var rows: UInt16 = 0
            guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) == GHOSTTY_SUCCESS,
                  ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS
            else { return nil }
            snapshot.cols = Int(cols)
            snapshot.rows = Int(rows)

            var colors = GhosttyRenderStateColors()
            colors.size = MemoryLayout<GhosttyRenderStateColors>.size
            if ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) == GHOSTTY_SUCCESS {
                snapshot.fg = GhosttyRGB(colors.foreground)
                snapshot.bg = GhosttyRGB(colors.background)
            }

            var cursor = GhosttyRenderStateCursor()
            cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
            if ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS {
                snapshot.cursor = GhosttySnapshotCursor(
                    x: Int(cursor.viewport_x),
                    y: Int(cursor.viewport_y),
                    hasPosition: cursor.viewport_has_value,
                    visible: cursor.visible,
                    blinking: cursor.blinking,
                    style: GhosttyCursorShape(cursor.visual_style)
                )
            }

            var iterator: GhosttyRenderStateRowIterator?
            guard ghostty_render_state_row_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS,
                  iterator != nil
            else { return snapshot }
            defer { ghostty_render_state_row_iterator_free(iterator) }
            guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS else {
                return snapshot
            }

            var cells: GhosttyRenderStateRowCells?
            guard ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS,
                  cells != nil
            else { return snapshot }
            defer { ghostty_render_state_row_cells_free(cells) }
            guard let it = iterator, let cs = cells else { return snapshot }

            while ghostty_render_state_row_iterator_next(it) {
                var row = GhosttySnapshotRow()
                var raw = GhosttyRow(0)
                if ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
                    var cont = false
                    if ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &cont) == GHOSTTY_SUCCESS {
                        row.wrapContinuation = cont
                    }
                }
                var rowCells: GhosttyRenderStateRowCells? = cs
                if ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS,
                   let rowCells
                {
                    // Per-column select (not next-iteration): the iterator
                    // skips blank cells, which would collapse leading/interior
                    // blanks and shift every later cell left. Selecting each
                    // column keeps snapshot cells aligned 1:1 with grid columns
                    // (blank cells read back with empty text), which both the
                    // view's run layout and SelectionText rely on.
                    row.cells.reserveCapacity(Int(cols))
                    for x in 0..<Int(cols) {
                        guard ghostty_render_state_row_cells_select(rowCells, UInt16(x)) == GHOSTTY_SUCCESS else {
                            row.cells.append(GhosttySnapshotCell())
                            continue
                        }
                        row.cells.append(Self.readCell(rowCells))
                    }
                }
                snapshot.grid.append(row)
            }
            return snapshot
        }
    }

    // MARK: - C enum mapping

    private static func readCell(_ cells: GhosttyRenderStateRowCells) -> GhosttySnapshotCell {
        var cell = GhosttySnapshotCell()

        var raw = GhosttyCell(0)
        if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
            var wide = GHOSTTY_CELL_WIDE_NARROW
            if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                cell.wide = GhosttyCellWidth(wide)
            }
        }

        // Grapheme cluster as UTF-8. Stack buffer first; heap on overflow.
        var stack = [UInt8](repeating: 0, count: 32)
        let text: String? = stack.withUnsafeMutableBufferPointer { ptr in
            var buf = GhosttyBuffer(ptr: ptr.baseAddress, cap: ptr.count, len: 0)
            let result = ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf)
            if result == GHOSTTY_OUT_OF_SPACE {
                var heap = [UInt8](repeating: 0, count: buf.len)
                return heap.withUnsafeMutableBufferPointer { hptr in
                    var hbuf = GhosttyBuffer(ptr: hptr.baseAddress, cap: hptr.count, len: 0)
                    guard ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &hbuf) == GHOSTTY_SUCCESS
                    else { return nil }
                    return String(bytes: hptr.prefix(hbuf.len), encoding: .utf8)
                }
            }
            guard result == GHOSTTY_SUCCESS else { return nil }
            return String(bytes: ptr.prefix(buf.len), encoding: .utf8)
        }
        cell.text = text ?? ""

        var styled = false
        if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled) == GHOSTTY_SUCCESS,
           styled
        {
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
                cell.bold = style.bold
                cell.italic = style.italic
                cell.faint = style.faint
                cell.blink = style.blink
                cell.inverse = style.inverse
                cell.invisible = style.invisible
                cell.strikethrough = style.strikethrough
                cell.overline = style.overline
                cell.underline = Int(style.underline)
            }
        }

        var fg = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS {
            cell.fg = GhosttyRGB(fg)
        }
        var bg = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS {
            cell.bg = GhosttyRGB(bg)
        }
        return cell
    }
}

private extension GhosttyCellWidth {
    init(_ wide: GhosttyCellWide) {
        switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: self = .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: self = .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: self = .spacerHead
        default: self = .narrow
        }
    }
}

private extension GhosttyCursorShape {
    init(_ style: GhosttyRenderStateCursorVisualStyle) {
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: self = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: self = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: self = .hollow
        default: self = .block
        }
    }
}
