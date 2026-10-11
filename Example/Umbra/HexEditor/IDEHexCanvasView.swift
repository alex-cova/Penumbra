import AppKit
import HexKit
import Penumbra

/// Viewport-sized hex rows. Scroll position is a row index, so the view stays short for a multi-gigabyte file.
@MainActor
final class IDEHexCanvasView: NSView {
    weak var session: IDEHexSession? {
        didSet { needsDisplay = true; updateScroller() }
    }

    private let scroller = NSScroller()
    private var wheelRows: CGFloat = 0
    /// Byte where the current drag started. Kept stable so a backward drag still covers that byte.
    private var dragOriginByte: Int64?
    private let rowCacheLimit = 256
    private var rowCache: [Int64: NSAttributedString] = [:]
    private var cacheGeneration: Int = -1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        addSubview(scroller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 14
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        session?.setBytesPerRow(auto: contentWidth, charWidth: charWidth)
        updateScroller()
    }

    override func draw(_ dirtyRect: NSRect) {
        IDEAppearance.NSToken.editor.setFill()
        dirtyRect.fill()
        guard let session else { return }
        let font = editorFont
        let line = rowHeight
        let metrics = session.metrics(charWidth: charWidth)
        drawHeader(metrics: metrics, font: font, session: session)
        let rows = visibleRowCount
        let generation = session.renderGeneration ^ session.bytesPerRow ^ session.groupSize
        if generation != cacheGeneration {
            rowCache.removeAll(keepingCapacity: true)
            cacheGeneration = generation
        }
        drawUnderlays(session: session, metrics: metrics, rowHeight: line, rows: rows)
        for index in 0..<rows {
            let row = session.topRow + Int64(index)
            guard row < session.rowCount || (session.document.count == 0 && index == 0) else { break }
            let y = line * CGFloat(index + 1)
            if y > dirtyRect.maxY || y + line < dirtyRect.minY { continue }
            lineString(row: row, session: session, metrics: metrics, font: font).draw(at: NSPoint(x: 8, y: y))
        }
        drawCaret(session: session, metrics: metrics, rowHeight: line, rows: rows)
        if rowCache.count > rowCacheLimit { rowCache.removeAll(keepingCapacity: true) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let session else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = locatedByte(at: point, session: session) else {
            dragOriginByte = nil
            return
        }
        let byte = hit.offset
        if event.clickCount >= 2 {
            dragOriginByte = nil
            session.selectGroup(at: byte)
        } else if event.modifierFlags.contains(.shift), !session.selection.isEmpty {
            dragOriginByte = nil
            session.shiftClick(byte: byte)
        } else if event.modifierFlags.contains(.shift) {
            dragOriginByte = session.anchor
            session.selectBytes(from: session.anchor, through: byte)
        } else {
            session.click(byte: byte, pane: hit.pane)
            dragOriginByte = session.anchor
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = locatedByte(at: point, session: session) {
            let byte = hit.offset
            if let origin = dragOriginByte {
                session.selectBytes(from: origin, through: byte)
            } else {
                session.shiftClick(byte: byte)
            }
            needsDisplay = true
        }
        if point.y < 0 || point.y > bounds.height {
            let direction: Int64 = point.y < 0 ? -1 : 1
            session.topRow = max(0, session.topRow + direction)
            session.revealCaret(visibleRows: Int64(visibleRowCount))
            updateScroller()
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginByte = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        wheelRows += event.scrollingDeltaY / rowHeight
        let rows = Int64(wheelRows)
        guard rows != 0 else { return }
        wheelRows -= CGFloat(rows)
        let maxTop = max(0, session.rowCount - Int64(visibleRowCount))
        session.topRow = min(maxTop, max(0, session.topRow - rows))
        updateScroller()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { super.keyDown(with: event); return }
        session.noteVisibleRows(Int64(visibleRowCount))
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extend = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.command), chars.lowercased() == "a" {
            session.selectAll()
            needsDisplay = true
            return
        }
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            session.togglePane()
            needsDisplay = true
            return
        }
        switch event.keyCode {
        case 123: // left
            if flags.contains(.option) { session.moveByGroup(direction: -1, extend: extend) }
            else { session.move(by: -1, extend: extend) }
        case 124:
            if flags.contains(.option) { session.moveByGroup(direction: 1, extend: extend) }
            else { session.move(by: 1, extend: extend) }
        case 125: session.move(by: Int64(session.bytesPerRow), extend: extend)
        case 126: session.move(by: -Int64(session.bytesPerRow), extend: extend)
        case 116: session.page(rows: -Int64(visibleRowCount), extend: extend) // Page Up
        case 121: session.page(rows: Int64(visibleRowCount), extend: extend) // Page Down
        case 115: session.goTo("0")
        case 119: session.goTo("end")
        case 51: session.deleteBackward()
        case 117: session.deleteForward()
        default:
            if let character = event.characters?.first {
                if session.textPaneFocused {
                    if !session.typeCharacter(character) { NSSound.beep() }
                } else if let nibble = Self.nibble(character) {
                    if !session.typeNibble(nibble) { NSSound.beep() }
                } else {
                    super.keyDown(with: event)
                    return
                }
            } else {
                super.keyDown(with: event)
                return
            }
        }
        needsDisplay = true
        updateScroller()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { session?.accessibilitySummary }

    func caretRectsForTesting() -> [NSRect] {
        guard let session else { return [] }
        return caretMarks(
            session: session,
            metrics: session.metrics(charWidth: charWidth),
            rowHeight: rowHeight,
            rows: visibleRowCount
        ).map(\.rect)
    }

    func hitForTesting(at point: NSPoint) -> HexHit? {
        guard let session else { return nil }
        return hit(at: point, session: session)
    }

    func visibleByteRange() -> Range<Int64> {
        guard let session else { return 0..<0 }
        let start = session.topRow * Int64(session.bytesPerRow)
        let end = min(session.document.count, start + Int64(visibleRowCount * session.bytesPerRow))
        return start..<max(start, end)
    }

    private var editorFont: NSFont { IDEEditorTheme.shared.current.font }
    private var charWidth: Double {
        let width = ("0" as NSString).size(withAttributes: [.font: editorFont]).width
        return width > 0 ? width : 8
    }
    private var rowHeight: CGFloat { ceil(editorFont.ascender - editorFont.descender + editorFont.leading) + 2 }
    private var contentWidth: Double { Double(max(0, bounds.width - 22)) }
    private var visibleRowCount: Int { max(1, Int((bounds.height - rowHeight) / rowHeight)) }

    private struct LocatedByte {
        var offset: Int64
        var pane: HexHit.Pane
    }

    /// File offset under the pointer. `HexHit.byteIndex` is only the column in that row.
    private func locatedByte(at point: NSPoint, session: IDEHexSession) -> LocatedByte? {
        let line = rowHeight
        guard point.y >= line else { return nil }
        let row = Int((point.y - line) / line)
        guard row >= 0, row < visibleRowCount else { return nil }
        guard let hit = session.metrics(charWidth: charWidth).hitTest(x: Double(point.x - 8)) else { return nil }
        let width = Int64(max(1, session.bytesPerRow))
        let offset = (session.topRow + Int64(row)) * width + Int64(hit.byteIndex)
        return LocatedByte(offset: offset, pane: hit.pane)
    }

    private func hit(at point: NSPoint, session: IDEHexSession) -> HexHit? {
        let line = rowHeight
        guard point.y >= line else { return nil }
        let row = Int((point.y - line) / line)
        guard row >= 0, row < visibleRowCount else { return nil }
        let metrics = session.metrics(charWidth: charWidth)
        return metrics.hitTest(x: Double(point.x - 8))
    }

    private func drawHeader(metrics: HexRowMetrics, font: NSFont, session: IDEHexSession) {
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: IDEAppearance.NSToken.muted]
        NSAttributedString(string: "offset", attributes: muted).draw(at: NSPoint(x: 8, y: 2))
        for index in 0..<metrics.bytesPerRow {
            let label = HexLayout.formatHex(UInt8(truncatingIfNeeded: index), uppercase: session.uppercase)
            let text = NSAttributedString(string: label, attributes: muted)
            text.draw(at: NSPoint(x: 8 + metrics.hexX(byte: index), y: 2))
        }
    }

    /// Row tint, edited bytes, search hits, then the selection. Glyphs paint on top of these fills.
    private func drawUnderlays(session: IDEHexSession, metrics: HexRowMetrics, rowHeight: CGFloat, rows: Int) {
        let width = Int64(max(1, session.bytesPerRow))
        let origin = session.topRow * width
        let visibleEnd = min(session.document.count, origin + Int64(rows * session.bytesPerRow))
        let visible = origin..<max(origin, visibleEnd)

        if session.selection.isEmpty {
            let caretRow = session.caret / width
            let viewRow = Int(caretRow - session.topRow)
            if viewRow >= 0, viewRow < rows {
                IDEAppearance.NSToken.accent.withAlphaComponent(0.06).setFill()
                NSRect(x: 8, y: rowHeight * CGFloat(viewRow + 1), width: metrics.rowWidth, height: rowHeight).fill()
            }
        }

        if session.document.isModified {
            IDEAppearance.NSToken.accent.withAlphaComponent(0.22).setFill()
            for range in session.document.modifiedRanges() {
                fill(
                    range.overlapping(visible),
                    session: session, metrics: metrics, rowHeight: rowHeight, width: width
                )
            }
        }

        if !session.matches.isEmpty {
            let other = NSColor.systemYellow.withAlphaComponent(0.30)
            let current = NSColor.systemOrange.withAlphaComponent(0.48)
            var index = firstMatch(in: session.matches, endingAfter: visible.lowerBound)
            while index < session.matches.count {
                let match = session.matches[index]
                if match.lowerBound >= visible.upperBound { break }
                let tint = index == session.matchIndex ? current : other
                tint.setFill()
                fill(match.overlapping(visible), session: session, metrics: metrics, rowHeight: rowHeight, width: width)
                index += 1
            }
        }

        guard !session.selection.isEmpty else { return }
        IDEAppearance.NSToken.selection.setFill()
        fill(session.selection.overlapping(visible), session: session, metrics: metrics, rowHeight: rowHeight, width: width)
    }

    private func fill(
        _ range: Range<Int64>,
        session: IDEHexSession,
        metrics: HexRowMetrics,
        rowHeight: CGFloat,
        width: Int64
    ) {
        guard !range.isEmpty else { return }
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let row = cursor / width
            let rowEnd = min(range.upperBound, (row + 1) * width)
            let viewRow = Int(row - session.topRow)
            if viewRow >= 0 {
                let y = rowHeight * CGFloat(viewRow + 1)
                var column = cursor
                while column < rowEnd {
                    let byteIndex = Int(column % width)
                    NSRect(x: 8 + metrics.hexX(byte: byteIndex), y: y, width: metrics.charWidth * 2, height: rowHeight).fill()
                    NSRect(x: 8 + metrics.textX(byte: byteIndex), y: y, width: metrics.charWidth, height: rowHeight).fill()
                    column += 1
                }
            }
            cursor = rowEnd
        }
    }

    /// First match whose end is past `offset`. Matches are in ascending order.
    private func firstMatch(in matches: [Range<Int64>], endingAfter offset: Int64) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].upperBound <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private struct CaretMark {
        var rect: NSRect
        var active: Bool
        var bar: Bool
    }

    /// Overwrite draws a box on the byte (or the low nibble). Insert draws a bar between bytes.
    private func caretMarks(session: IDEHexSession, metrics: HexRowMetrics, rowHeight: CGFloat, rows: Int) -> [CaretMark] {
        guard session.selection.isEmpty else { return [] }
        let width = Int64(max(1, session.bytesPerRow))
        let caret = session.caret
        let row = caret / width
        let viewRow = Int(row - session.topRow)
        guard viewRow >= 0, viewRow < rows else { return [] }
        let column = Int(caret % width)
        let y = rowHeight * CGFloat(viewRow + 1)
        // A bar sits between bytes. Overwrite boxes the byte, and a half-typed nibble boxes that digit.
        let bar = caret >= session.document.count || (session.insertMode && !session.lowNibble)
        let hexActive = !session.textPaneFocused
        return [
            mark(x: 8 + metrics.hexX(byte: column), y: y, metrics: metrics, rowHeight: rowHeight, hex: true, lowNibble: session.lowNibble && !bar, bar: bar, active: hexActive),
            mark(x: 8 + metrics.textX(byte: column), y: y, metrics: metrics, rowHeight: rowHeight, hex: false, lowNibble: false, bar: bar, active: !hexActive),
        ]
    }

    private func mark(
        x: Double,
        y: CGFloat,
        metrics: HexRowMetrics,
        rowHeight: CGFloat,
        hex: Bool,
        lowNibble: Bool,
        bar: Bool,
        active: Bool
    ) -> CaretMark {
        if bar {
            return CaretMark(
                rect: NSRect(x: x - 1, y: y + 1, width: 2, height: max(1, rowHeight - 2)),
                active: active,
                bar: true
            )
        }
        let origin = lowNibble ? x + metrics.charWidth : x
        let cell = hex ? (lowNibble ? metrics.charWidth : metrics.charWidth * 2) : metrics.charWidth
        let rect = NSRect(x: origin, y: y, width: cell, height: rowHeight).insetBy(dx: 0.5, dy: 1)
        return CaretMark(rect: rect, active: active, bar: false)
    }

    private func drawCaret(session: IDEHexSession, metrics: HexRowMetrics, rowHeight: CGFloat, rows: Int) {
        for mark in caretMarks(session: session, metrics: metrics, rowHeight: rowHeight, rows: rows) {
            let color = IDEAppearance.NSToken.accent.withAlphaComponent(mark.active ? 0.95 : 0.35)
            if mark.bar {
                color.setFill()
                mark.rect.fill()
            } else {
                let path = NSBezierPath(roundedRect: mark.rect, xRadius: 2, yRadius: 2)
                color.setStroke()
                path.lineWidth = mark.active ? 1.5 : 1
                path.stroke()
            }
        }
    }

    private func lineString(row: Int64, session: IDEHexSession, metrics: HexRowMetrics, font: NSFont) -> NSAttributedString {
        if let cached = rowCache[row] { return cached }
        let bytes = session.rowBytes(row)
        let base = row * Int64(max(1, session.bytesPerRow))
        let offset = HexLayout.formatOffset(base, digits: metrics.offsetDigits, base: session.offsetBase, uppercase: session.uppercase)
        let columns = max(1, Int((metrics.rowWidth / max(metrics.charWidth, 1)).rounded(.up)))
        var chars = Array(repeating: Character(" "), count: columns + 2)
        write(offset, into: &chars, at: 0)
        for (index, byte) in bytes.enumerated() {
            let hexColumn = Int((metrics.hexX(byte: index) / max(metrics.charWidth, 1)).rounded())
            write(HexLayout.formatHex(byte, uppercase: session.uppercase), into: &chars, at: hexColumn)
            let textColumn = Int((metrics.textX(byte: index) / max(metrics.charWidth, 1)).rounded())
            let glyph = String(session.encoding.glyph(for: byte))
            write(glyph, into: &chars, at: textColumn)
        }
        let drawn = NSMutableAttributedString(string: String(chars), attributes: [.font: font, .foregroundColor: IDEAppearance.NSToken.foreground])
        if session.colorByClass {
            for (index, byte) in bytes.enumerated() {
                let color = color(for: byte)
                let hexColumn = Int((metrics.hexX(byte: index) / max(metrics.charWidth, 1)).rounded())
                if hexColumn >= 0, hexColumn + 1 < drawn.length {
                    drawn.addAttribute(.foregroundColor, value: color, range: NSRange(location: hexColumn, length: 2))
                }
                let textColumn = Int((metrics.textX(byte: index) / max(metrics.charWidth, 1)).rounded())
                if textColumn >= 0, textColumn < drawn.length {
                    drawn.addAttribute(.foregroundColor, value: color, range: NSRange(location: textColumn, length: 1))
                }
            }
        }
        rowCache[row] = drawn
        return drawn
    }

    private func write(_ text: String, into chars: inout [Character], at column: Int) {
        guard column >= 0 else { return }
        for (offset, character) in text.enumerated() {
            let index = column + offset
            if index >= chars.count { chars.append(contentsOf: repeatElement(" ", count: index - chars.count + 1)) }
            chars[index] = character
        }
    }

    private func color(for byte: UInt8) -> NSColor {
        switch HexByteClass.classify(byte) {
        case .nul, .whitespace: return IDEAppearance.NSToken.muted
        case .control: return IDEAppearance.NSToken.error
        case .printableASCII: return IDEAppearance.NSToken.foreground
        case .high: return IDEAppearance.NSToken.accent
        }
    }

    private func updateScroller() {
        guard let session else { return }
        session.noteVisibleRows(Int64(visibleRowCount))
        let visible = Double(visibleRowCount)
        let total = Double(max(session.rowCount, 1))
        scroller.knobProportion = HexScrollerMap.knobProportion(visibleRows: visible, totalRows: total)
        scroller.doubleValue = HexScrollerMap.fraction(
            topRow: session.topRow, visibleRows: Int64(visibleRowCount), totalRows: session.rowCount
        )
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        guard let session else { return }
        session.topRow = HexScrollerMap.topRow(
            fraction: sender.doubleValue,
            visibleRows: Int64(visibleRowCount),
            totalRows: session.rowCount
        )
        needsDisplay = true
    }

    private static func nibble(_ character: Character) -> UInt8? {
        switch character {
        case "0"..."9": return UInt8(character.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(character.asciiValue! - Character("a").asciiValue!) + 10
        case "A"..."F": return UInt8(character.asciiValue! - Character("A").asciiValue!) + 10
        default: return nil
        }
    }
}

private extension Range where Bound == Int64 {
    /// The overlap, or an empty range when the two do not meet. Never walks a span larger than `other`.
    func overlapping(_ other: Range<Int64>) -> Range<Int64> {
        let lower = Swift.max(lowerBound, other.lowerBound)
        let upper = Swift.min(upperBound, other.upperBound)
        return lower..<Swift.max(lower, upper)
    }
}

extension IDEHexCanvasView {
    /// Moves the scroller to `fraction` (0 top, 1 bottom) the way a knob drag does.
    func seek(to fraction: Double) {
        scroller.doubleValue = fraction
        scrollerMoved(scroller)
    }
}
