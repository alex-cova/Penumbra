@preconcurrency import AppKit
import CoreText
import Foundation

struct MarkdownPreviewBlockLayout: Equatable {
    var block: MarkdownPreviewBlock
    var frame: CGRect
    var textFrames: [CGRect]
    /// One frame per list item's marker (bullet/ordinal/checkbox) gutter, parallel to
    /// `textFrames`. Empty for non-list blocks.
    var markerFrames: [CGRect] = []
    /// Column/row/cell geometry, present only for `.table` blocks.
    var table: MarkdownPreviewTableGeometry?
    /// The block's typeset text, reused by every paint. `nil` for a hand-built layout, which
    /// the renderer then typesets as it draws. Derived from the other fields and the style, so
    /// it takes no part in equality.
    var text: MarkdownPreviewBlockText?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.frame == rhs.frame && lhs.textFrames == rhs.textFrames
            && lhs.markerFrames == rhs.markerFrames && lhs.table == rhs.table
    }
}

/// Typeset text of one block, each `CTFrame` framed at the origin with the size of the rect it is
/// drawn into (see ``MarkdownPreviewCGRenderer``). CoreText frames are immutable, so tiles may be
/// painted from them on any thread.
final class MarkdownPreviewBlockText: @unchecked Sendable {
    /// Parallel to `textFrames` (for a code block or mermaid error: its inset text rect).
    let frames: [CTFrame]
    /// Parallel to `markerFrames`; `nil` where the marker is drawn, not typeset (a checkbox).
    let markers: [CTFrame?]
    /// Table cells: the header row (when present) first, then each body row.
    let cells: [[CTFrame]]

    init(frames: [CTFrame] = [], markers: [CTFrame?] = [], cells: [[CTFrame]] = []) {
        self.frames = frames
        self.markers = markers
        self.cells = cells
    }
}

/// A drawn band behind one contiguous run of blocks at a given blockquote depth — the visual
/// affordance for `>`, `>>`, `>>>`. Absolute document coordinates, so Metal tiling clips it like
/// any other paint call.
struct MarkdownPreviewQuoteDecoration: Equatable {
    var band: CGRect
    var depth: Int
}

/// Per-block measurements from the previous layout, keyed by block content and width, so a layout
/// after an edit only measures and typesets the blocks that changed. Valid for one style; holds
/// only the blocks of the most recent layout.
final class MarkdownPreviewMeasureCache {
    /// Keyed by the block's content hash rather than its content: comparing or hashing the
    /// attributed text itself costs more than measuring it. Two different blocks would need
    /// colliding 64-bit hashes to be confused.
    struct Key: Hashable {
        var content: Int
        var width: CGFloat
        /// A raster (mermaid/image) block's height, which comes from outside the block.
        var fixedHeight: CGFloat?
        /// The highlighted code a code block is drawn with (kept alive by `Entry.code`).
        var code: ObjectIdentifier?
    }

    struct Entry {
        /// Block size with frames relative to the block origin.
        var size: CGSize
        var textFrames: [CGRect]
        var markerFrames: [CGRect]
        var table: MarkdownPreviewTableGeometry?
        var text: MarkdownPreviewBlockText?
        var code: NSAttributedString?
    }

    private var style: MarkdownPreviewStyle?
    private var entries: [Key: Entry] = [:]
    private var nextEntries: [Key: Entry] = [:]
    /// Blocks measured (cache misses) by the last layout. Tests and benchmarks read it.
    private(set) var lastMissCount = 0

    func removeAll() {
        entries.removeAll()
        style = nil
    }

    fileprivate func begin(style: MarkdownPreviewStyle) {
        if self.style != style {
            entries.removeAll()
            self.style = style
        }
        nextEntries.removeAll(keepingCapacity: true)
        lastMissCount = 0
    }

    fileprivate func entry(for key: Key, measure: () -> Entry) -> Entry {
        if let entry = nextEntries[key] ?? entries[key] {
            nextEntries[key] = entry
            return entry
        }
        lastMissCount += 1
        let entry = measure()
        nextEntries[key] = entry
        return entry
    }

    fileprivate func end() {
        swap(&entries, &nextEntries)
        nextEntries.removeAll(keepingCapacity: true)
    }
}

struct MarkdownPreviewLayout: Equatable {
    var blockLayouts: [MarkdownPreviewBlockLayout]
    var quoteDecorations: [MarkdownPreviewQuoteDecoration] = []
    var contentSize: CGSize

    static func layout(
        document: MarkdownPreviewDocument,
        style: MarkdownPreviewStyle,
        width: CGFloat,
        mermaidHeights: [Int: CGFloat] = [:],
        imageHeights: [Int: CGFloat] = [:],
        highlightedCode: [Int: NSAttributedString] = [:],
        cache: MarkdownPreviewMeasureCache? = nil
    ) -> MarkdownPreviewLayout {
        let cache = cache ?? MarkdownPreviewMeasureCache()
        cache.begin(style: style)
        defer { cache.end() }
        let fonts = Fonts(style: style)
        let inset = style.contentInset
        var y = inset
        var layouts: [MarkdownPreviewBlockLayout] = []
        layouts.reserveCapacity(document.blocks.count)

        for (index, block) in document.blocks.enumerated() {
            let quoteOffset = CGFloat(block.quoteDepth) * style.quoteIndent
            let contentX = inset + quoteOffset
            let contentWidth = max(width - inset * 2 - quoteOffset, 1)

            var fixedHeight: CGFloat?
            var code: NSAttributedString?
            switch block.kind {
            case .image: fixedHeight = imageHeights[index] ?? 120
            case .mermaid, .mermaidError: fixedHeight = mermaidHeights[index] ?? 200
            case .codeBlock: code = highlightedCode[index]
            default: break
            }
            let key = MarkdownPreviewMeasureCache.Key(
                content: block.resolvedContentHash, width: contentWidth, fixedHeight: fixedHeight, code: code.map(ObjectIdentifier.init)
            )
            let entry = cache.entry(for: key) {
                measure(block.kind, width: contentWidth, fixedHeight: fixedHeight, code: code, style: style, fonts: fonts)
            }

            let origin = CGPoint(x: contentX, y: y)
            func offset(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: origin.x, dy: origin.y) }
            layouts.append(MarkdownPreviewBlockLayout(
                block: block,
                frame: CGRect(origin: origin, size: entry.size),
                textFrames: entry.textFrames.map(offset),
                markerFrames: entry.markerFrames.map(offset),
                table: entry.table,
                text: entry.text
            ))
            y += entry.size.height + style.blockSpacing
        }

        y += inset
        let contentSize = CGSize(width: width, height: max(y, inset * 2))
        let decorations = quoteDecorations(for: layouts, style: style, width: width, inset: inset)
        return MarkdownPreviewLayout(blockLayouts: layouts, quoteDecorations: decorations, contentSize: contentSize)
    }

    /// Fonts derived from the style, converted once per layout instead of once per block.
    private struct Fonts {
        var headings: [NSFont]
        var footnote: NSFont
        var tableHeader: NSFont

        init(style: MarkdownPreviewStyle) {
            headings = style.headingScale.map {
                NSFontManager.shared.convert(style.bodyFont, toSize: style.bodyFont.pointSize * $0)
            }
            footnote = style.footnoteFont(for: style.bodyFont)
            tableHeader = NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .boldFontMask)
        }

        func heading(level: Int) -> NSFont? {
            guard !headings.isEmpty else { return nil }
            return headings[min(max(level - 1, 0), headings.count - 1)]
        }
    }

    /// Measures and typesets one block in its own coordinate space (origin at its top-left).
    private static func measure(
        _ kind: MarkdownPreviewBlock.Kind,
        width contentWidth: CGFloat,
        fixedHeight: CGFloat?,
        code: NSAttributedString?,
        style: MarkdownPreviewStyle,
        fonts: Fonts
    ) -> MarkdownPreviewMeasureCache.Entry {
        typealias Entry = MarkdownPreviewMeasureCache.Entry
        switch kind {
        case .heading(let level, let text):
            let font = fonts.heading(level: level) ?? style.bodyFont
            let typeset = typesetInline(text, font: font, color: style.bodyColor, style: style, width: contentWidth)
            let frame = CGRect(x: 0, y: 0, width: contentWidth, height: typeset.height)
            return Entry(size: frame.size, textFrames: [frame], markerFrames: [], text: MarkdownPreviewBlockText(frames: [typeset.frame]))

        case .paragraph(let text):
            let typeset = typesetInline(text, font: style.bodyFont, color: style.bodyColor, style: style, width: contentWidth)
            let frame = CGRect(x: 0, y: 0, width: contentWidth, height: typeset.height)
            return Entry(size: frame.size, textFrames: [frame], markerFrames: [], text: MarkdownPreviewBlockText(frames: [typeset.frame]))

        case .list(let list):
            var textFrames: [CGRect] = []
            var markerFrames: [CGRect] = []
            var frames: [CTFrame] = []
            var markers: [CTFrame?] = []
            var listHeight: CGFloat = 0
            for item in list.items {
                let indent = CGFloat(item.level) * style.listIndent
                let itemWidth = max(contentWidth - indent - style.listIndent, 1)
                let isCheckedTask: Bool = {
                    if case .task(true) = item.marker { return true }
                    return false
                }()
                let color = (style.dimsCompletedTasks && isCheckedTask) ? style.bodyColor.withAlphaComponent(0.55) : style.bodyColor
                let typeset = typesetInline(item.text, font: style.bodyFont, color: color, style: style, width: itemWidth)
                let markerFrame = CGRect(x: indent, y: listHeight, width: style.listIndent - 6, height: typeset.height)
                textFrames.append(CGRect(x: indent + style.listIndent, y: listHeight, width: itemWidth, height: typeset.height))
                markerFrames.append(markerFrame)
                frames.append(typeset.frame)
                switch item.marker {
                case .bullet:
                    let glyph = MarkdownPreviewCGRenderer.bulletGlyph(level: item.level)
                    markers.append(typesetPlain(glyph, font: style.bodyFont, color: style.bodyColor, size: markerFrame.size))
                case .ordered(let number):
                    markers.append(typesetPlain("\(number).", font: style.bodyFont, color: style.bodyColor, size: markerFrame.size))
                case .task:
                    markers.append(nil)
                }
                listHeight += typeset.height + 4
            }
            if !list.items.isEmpty { listHeight -= 4 }
            return Entry(
                size: CGSize(width: contentWidth, height: listHeight),
                textFrames: textFrames,
                markerFrames: markerFrames,
                text: MarkdownPreviewBlockText(frames: frames, markers: markers)
            )

        case .table(let table):
            let geometry = MarkdownPreviewTableLayout.geometry(for: table, style: style, width: contentWidth)
            func cellFrame(_ text: AttributedString, font: NSFont, column: Int, frame: CGRect) -> CTFrame {
                let rect = frame.insetBy(dx: style.tableCellPadding, dy: style.tableCellPadding)
                let attributed = MarkdownPreviewInlineStyler.attributedString(
                    text, baseFont: font, color: style.bodyColor,
                    alignment: MarkdownPreviewCGRenderer.textAlignment(for: table, column: column), style: style
                )
                return typeset(attributed, size: rect.size)
            }
            var cells: [[CTFrame]] = []
            if !geometry.headerCellFrames.isEmpty {
                cells.append(geometry.headerCellFrames.enumerated().map { column, frame in
                    cellFrame(column < table.header.count ? table.header[column] : AttributedString(),
                              font: fonts.tableHeader, column: column, frame: frame)
                })
            }
            for (rowIndex, row) in table.rows.enumerated() where rowIndex < geometry.cellFrames.count {
                cells.append(geometry.cellFrames[rowIndex].enumerated().map { column, frame in
                    cellFrame(column < row.count ? row[column] : AttributedString(), font: style.bodyFont, column: column, frame: frame)
                })
            }
            return Entry(size: geometry.totalSize, textFrames: [], markerFrames: [], table: geometry,
                         text: MarkdownPreviewBlockText(cells: cells))

        case .thematicBreak:
            return Entry(size: CGSize(width: contentWidth, height: 1), textFrames: [], markerFrames: [])

        case .codeBlock(_, let source):
            let textWidth = contentWidth - style.codePadding * 2
            let attributed: NSAttributedString
            let textHeight: CGFloat
            if let code {
                attributed = code
                textHeight = measure(attributed: code, width: textWidth)
            } else {
                attributed = NSAttributedString(string: source, attributes: [.font: style.codeFont, .foregroundColor: style.bodyColor])
                let lines = max(1, source.components(separatedBy: "\n").count)
                let lineHeight = style.codeFont.ascender - style.codeFont.descender + 2
                textHeight = CGFloat(lines) * lineHeight
            }
            let height = textHeight + style.codePadding * 2
            let frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)
            let textSize = frame.insetBy(dx: style.codePadding, dy: style.codePadding).size
            return Entry(size: frame.size, textFrames: [frame], markerFrames: [],
                         text: MarkdownPreviewBlockText(frames: [typeset(attributed, size: textSize)]), code: code)

        case .image, .mermaid:
            let frame = CGRect(x: 0, y: 0, width: contentWidth, height: fixedHeight ?? 0)
            return Entry(size: frame.size, textFrames: [frame], markerFrames: [])

        case .mermaidError(let source, let message):
            let frame = CGRect(x: 0, y: 0, width: contentWidth, height: fixedHeight ?? 0)
            let textSize = frame.insetBy(dx: style.codePadding, dy: style.codePadding).size
            let text = typesetPlain("\(source)\n\n\(message)", font: style.codeFont, color: .systemRed, size: textSize)
            return Entry(size: frame.size, textFrames: [frame], markerFrames: [], text: MarkdownPreviewBlockText(frames: [text]))

        case .footnotes(let footnotes):
            let footnoteFont = fonts.footnote
            let markerColor = style.bodyColor.withAlphaComponent(0.6)
            var textFrames: [CGRect] = []
            var markerFrames: [CGRect] = []
            var frames: [CTFrame] = []
            var markers: [CTFrame?] = []
            var footnotesHeight: CGFloat = 0
            let textWidth = max(contentWidth - style.footnoteMarkerWidth, 1)
            for entry in footnotes {
                let typeset = typesetInline(entry.text, font: footnoteFont, color: style.bodyColor, style: style, width: textWidth)
                let markerFrame = CGRect(x: 0, y: footnotesHeight, width: style.footnoteMarkerWidth, height: typeset.height)
                textFrames.append(CGRect(x: style.footnoteMarkerWidth, y: footnotesHeight, width: textWidth, height: typeset.height))
                markerFrames.append(markerFrame)
                frames.append(typeset.frame)
                markers.append(typesetPlain("\(entry.number).", font: footnoteFont, color: markerColor, size: markerFrame.size))
                footnotesHeight += typeset.height + style.footnoteSpacing
            }
            if !footnotes.isEmpty { footnotesHeight -= style.footnoteSpacing }
            return Entry(
                size: CGSize(width: contentWidth, height: footnotesHeight),
                textFrames: textFrames,
                markerFrames: markerFrames,
                text: MarkdownPreviewBlockText(frames: frames, markers: markers)
            )
        }
    }

    /// Styles, measures and typesets inline markdown text wrapped at `width` in one pass, so
    /// the framesetter used to measure is the one that lays out the drawn frame.
    private static func typesetInline(
        _ text: AttributedString,
        font: NSFont,
        color: NSColor,
        style: MarkdownPreviewStyle,
        width: CGFloat
    ) -> (frame: CTFrame, height: CGFloat) {
        let attributed = MarkdownPreviewInlineStyler.attributedString(text, baseFont: font, color: color, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), &fitRange
        )
        let height = max(size.height, font.ascender - font.descender)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        return (CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), height)
    }

    private static func typesetPlain(_ string: String, font: NSFont, color: NSColor, size: CGSize) -> CTFrame {
        typeset(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]), size: size)
    }

    static func typeset(_ attributed: NSAttributedString, size: CGSize) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: max(size.width, 0), height: max(size.height, 0))), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    }

    /// Groups blocks into maximal consecutive runs per quote depth (1 for `>`, 2 for `>>`, ...),
    /// each becoming one band. A block at depth 3 is covered by three overlapping bands (depths
    /// 1, 2, 3), which is what makes nested quotes read as nested rather than as one flat tint.
    private static func quoteDecorations(
        for layouts: [MarkdownPreviewBlockLayout],
        style: MarkdownPreviewStyle,
        width: CGFloat,
        inset: CGFloat
    ) -> [MarkdownPreviewQuoteDecoration] {
        guard !layouts.isEmpty else { return [] }
        let maxDepth = layouts.map(\.block.quoteDepth).max() ?? 0
        guard maxDepth > 0 else { return [] }
        let rightEdge = width - inset

        var decorations: [MarkdownPreviewQuoteDecoration] = []
        for depth in 1...maxDepth {
            var runStart: Int?
            func closeRun(endIndex: Int) {
                guard let start = runStart, endIndex >= start else { return }
                let minY = layouts[start].frame.minY - style.quotePadding
                let maxY = layouts[endIndex].frame.maxY + style.quotePadding
                let bandX = inset + CGFloat(depth - 1) * style.quoteIndent
                let band = CGRect(x: bandX, y: minY, width: max(rightEdge - bandX, 0), height: max(maxY - minY, 0))
                decorations.append(MarkdownPreviewQuoteDecoration(band: band, depth: depth))
                runStart = nil
            }
            for (index, layout) in layouts.enumerated() {
                if layout.block.quoteDepth >= depth {
                    if runStart == nil { runStart = index }
                } else {
                    closeRun(endIndex: index - 1)
                }
            }
            closeRun(endIndex: layouts.count - 1)
        }
        return decorations
    }

    static func measure(attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            &fitRange
        )
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        return max(size.height, font.ascender - font.descender)
    }

    /// Builds a `CTFramesetter` for a parsed markdown fragment, resolving inline styling
    /// (bold/italic/code/strikethrough/links) via ``MarkdownPreviewInlineStyler``.
    static func framesetter(
        for text: AttributedString,
        baseFont: NSFont,
        style: MarkdownPreviewStyle,
        color: NSColor? = nil,
        alignment: NSTextAlignment = .natural
    ) -> CTFramesetter {
        let attributed = MarkdownPreviewInlineStyler.attributedString(
            text, baseFont: baseFont, color: color ?? style.bodyColor, alignment: alignment, style: style
        )
        return CTFramesetterCreateWithAttributedString(attributed)
    }
}
