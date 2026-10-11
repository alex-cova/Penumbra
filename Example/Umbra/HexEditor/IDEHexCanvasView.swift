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
        drawSelection(session: session, metrics: metrics, rowHeight: line, rows: rows)
        for index in 0..<rows {
            let row = session.topRow + Int64(index)
            guard row < session.rowCount || (session.document.count == 0 && index == 0) else { break }
            let y = line * CGFloat(index + 1)
            if y > dirtyRect.maxY || y + line < dirtyRect.minY { continue }
            lineString(row: row, session: session, metrics: metrics, font: font).draw(at: NSPoint(x: 8, y: y))
        }
        if rowCache.count > rowCacheLimit { rowCache.removeAll(keepingCapacity: true) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let session else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hit(at: point, session: session) else { return }
        let byte = session.topRow * Int64(session.bytesPerRow) + Int64(hit.byteIndex)
        if event.clickCount >= 2 {
            session.selectGroup(at: byte)
        } else if event.modifierFlags.contains(.shift) {
            session.shiftClick(byte: byte)
        } else {
            session.click(byte: byte, pane: hit.pane)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hit(at: point, session: session) {
            let byte = session.topRow * Int64(session.bytesPerRow) + Int64(hit.byteIndex)
            session.shiftClick(byte: byte)
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

    private func drawSelection(session: IDEHexSession, metrics: HexRowMetrics, rowHeight: CGFloat, rows: Int) {
        guard !session.selection.isEmpty else { return }
        IDEAppearance.NSToken.selection.setFill()
        let width = Int64(session.bytesPerRow)
        for index in 0..<rows {
            let row = session.topRow + Int64(index)
            let rowStart = row * width
            let y = rowHeight * CGFloat(index + 1)
            for byteIndex in 0..<session.bytesPerRow {
                let absolute = rowStart + Int64(byteIndex)
                guard session.selection.contains(absolute) else { continue }
                NSRect(x: 8 + metrics.hexX(byte: byteIndex), y: y, width: metrics.charWidth * 2, height: rowHeight).fill()
                NSRect(x: 8 + metrics.textX(byte: byteIndex), y: y, width: metrics.charWidth, height: rowHeight).fill()
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

extension IDEHexCanvasView {
    /// Moves the scroller to `fraction` (0 top, 1 bottom) the way a knob drag does.
    func seek(to fraction: Double) {
        scroller.doubleValue = fraction
        scrollerMoved(scroller)
    }
}
