@preconcurrency import AppKit
import CoreText
import Foundation

struct MarkdownPreviewBlockLayout: Equatable {
    var block: MarkdownPreviewBlock
    var frame: CGRect
    var textFrames: [CGRect]
}

struct MarkdownPreviewLayout: Equatable {
    var blockLayouts: [MarkdownPreviewBlockLayout]
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
        let contentWidth = max(width - inset * 2, 1)
        var y = inset
        var layouts: [MarkdownPreviewBlockLayout] = []

        for (index, block) in document.blocks.enumerated() {
            let spacing = style.blockSpacing
            switch block {
            case .heading(let level, let text):
                let font = headingFont(level: level, style: style)
                let height = measure(text: text, font: font, color: style.bodyColor, width: contentWidth)
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .paragraph(let text), .blockquote(let text):
                let height = measure(text: text, font: style.bodyFont, color: style.bodyColor, width: contentWidth)
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .unorderedList(let items), .orderedList(let items):
                var itemFrames: [CGRect] = []
                var listHeight: CGFloat = 0
                for item in items {
                    let itemWidth = contentWidth - style.listIndent
                    let itemHeight = measure(text: item, font: style.bodyFont, color: style.bodyColor, width: itemWidth)
                    let frame = CGRect(x: inset + style.listIndent, y: y + listHeight, width: itemWidth, height: itemHeight)
                    itemFrames.append(frame)
                    listHeight += itemHeight + 4
                }
                if !items.isEmpty { listHeight -= 4 }
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: listHeight)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: itemFrames))
                y += listHeight + spacing

            case .thematicBreak:
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: 1)
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
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .image:
                let height = imageHeights[index] ?? 120
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing

            case .mermaid, .mermaidError:
                let height = mermaidHeights[index] ?? 200
                let frame = CGRect(x: inset, y: y, width: contentWidth, height: height)
                layouts.append(MarkdownPreviewBlockLayout(block: block, frame: frame, textFrames: [frame]))
                y += height + spacing
            }
        }

        y += inset
        return MarkdownPreviewLayout(blockLayouts: layouts, contentSize: CGSize(width: width, height: max(y, inset * 2)))
    }

    private static func headingFont(level: Int, style: MarkdownPreviewStyle) -> NSFont {
        let index = min(max(level - 1, 0), style.headingScale.count - 1)
        let scale = style.headingScale[index]
        return NSFontManager.shared.convert(style.bodyFont, toSize: style.bodyFont.pointSize * scale)
    }

    private static func measure(
        text: AttributedString,
        font: NSFont,
        color: NSColor,
        width: CGFloat
    ) -> CGFloat {
        let framesetter = framesetter(for: text, baseFont: font, color: color)
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

    static func framesetter(
        for attributed: AttributedString,
        baseFont: NSFont,
        color: NSColor
    ) -> CTFramesetter {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: baseFont, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: color, range: fullRange)
        return CTFramesetterCreateWithAttributedString(mutable)
    }
}
