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
}

/// A drawn band behind one contiguous run of blocks at a given blockquote depth — the visual
/// affordance for `>`, `>>`, `>>>`. Absolute document coordinates, so Metal tiling clips it like
/// any other paint call.
struct MarkdownPreviewQuoteDecoration: Equatable {
    var band: CGRect
    var depth: Int
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
        highlightedCode: [Int: NSAttributedString] = [:]
    ) -> MarkdownPreviewLayout {
        let inset = style.contentInset
        var y = inset
        var layouts: [MarkdownPreviewBlockLayout] = []

        for (index, block) in document.blocks.enumerated() {
            let spacing = style.blockSpacing
            let quoteOffset = CGFloat(block.quoteDepth) * style.quoteIndent
            let contentX = inset + quoteOffset
            let contentWidth = max(width - inset * 2 - quoteOffset, 1)

            switch block.kind {
            case .heading(let level, let text):
                let font = headingFont(level: level, style: style)
                let height = measure(text: text, font: font, style: style, width: contentWidth)
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .paragraph(let text):
                let height = measure(text: text, font: style.bodyFont, style: style, width: contentWidth)
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .list(let list):
                var itemTextFrames: [CGRect] = []
                var itemMarkerFrames: [CGRect] = []
                var listHeight: CGFloat = 0
                for item in list.items {
                    let indent = CGFloat(item.level) * style.listIndent
                    let markerX = contentX + indent
                    let itemX = markerX + style.listIndent
                    let itemWidth = max(contentWidth - indent - style.listIndent, 1)
                    let itemHeight = measure(text: item.text, font: style.bodyFont, style: style, width: itemWidth)
                    itemTextFrames.append(CGRect(x: itemX, y: y + listHeight, width: itemWidth, height: itemHeight))
                    itemMarkerFrames.append(CGRect(x: markerX, y: y + listHeight, width: style.listIndent - 6, height: itemHeight))
                    listHeight += itemHeight + 4
                }
                if !list.items.isEmpty { listHeight -= 4 }
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: listHeight)
                layouts.append(MarkdownPreviewBlockLayout(
                    block: block, frame: frame, textFrames: itemTextFrames, markerFrames: itemMarkerFrames
                ))
                y += listHeight + spacing

            case .table(let table):
                let geometry = MarkdownPreviewTableLayout.geometry(for: table, style: style, width: contentWidth)
                let frame = CGRect(x: contentX, y: y, width: geometry.totalSize.width, height: geometry.totalSize.height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [], table: geometry))
                y += geometry.totalSize.height + spacing

            case .thematicBreak:
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: 1)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: []))
                y += 1 + spacing

            case .codeBlock(_, let source):
                let textWidth = contentWidth - style.codePadding * 2
                let textHeight: CGFloat
                if let attributed = highlightedCode[index] {
                    textHeight = measure(attributed: attributed, width: textWidth)
                } else {
                    let lines = max(1, source.components(separatedBy: "\n").count)
                    let lineHeight = style.codeFont.ascender - style.codeFont.descender + 2
                    textHeight = CGFloat(lines) * lineHeight
                }
                let height = textHeight + style.codePadding * 2
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .image:
                let height = imageHeights[index] ?? 120
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .mermaid, .mermaidError:
                let height = mermaidHeights[index] ?? 200
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .footnotes(let footnotes):
                let footnoteFont = style.footnoteFont(for: style.bodyFont)
                var entryTextFrames: [CGRect] = []
                var entryMarkerFrames: [CGRect] = []
                var footnotesHeight: CGFloat = 0
                for entry in footnotes {
                    let textX = contentX + style.footnoteMarkerWidth
                    let textWidth = max(contentWidth - style.footnoteMarkerWidth, 1)
                    let entryHeight = measure(text: entry.text, font: footnoteFont, style: style, width: textWidth)
                    entryTextFrames.append(CGRect(x: textX, y: y + footnotesHeight, width: textWidth, height: entryHeight))
                    entryMarkerFrames.append(CGRect(x: contentX, y: y + footnotesHeight, width: style.footnoteMarkerWidth, height: entryHeight))
                    footnotesHeight += entryHeight + style.footnoteSpacing
                }
                if !footnotes.isEmpty { footnotesHeight -= style.footnoteSpacing }
                let frame = CGRect(x: contentX, y: y, width: contentWidth, height: footnotesHeight)
                layouts.append(MarkdownPreviewBlockLayout(
                    block: block, frame: frame, textFrames: entryTextFrames, markerFrames: entryMarkerFrames
                ))
                y += footnotesHeight + spacing
            }
        }

        y += inset
        let contentSize = CGSize(width: width, height: max(y, inset * 2))
        let decorations = quoteDecorations(for: layouts, style: style, width: width, inset: inset)
        return MarkdownPreviewLayout(blockLayouts: layouts, quoteDecorations: decorations, contentSize: contentSize)
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

    private static func headingFont(level: Int, style: MarkdownPreviewStyle) -> NSFont {
        let index = min(max(level - 1, 0), style.headingScale.count - 1)
        let scale = style.headingScale[index]
        return NSFontManager.shared.convert(style.bodyFont, toSize: style.bodyFont.pointSize * scale)
    }

    private static func measure(
        text: AttributedString,
        font: NSFont,
        style: MarkdownPreviewStyle,
        width: CGFloat
    ) -> CGFloat {
        let framesetter = framesetter(for: text, baseFont: font, style: style)
        let constraints = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            &fitRange
        )
        return max(size.height, font.ascender - font.descender)
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
