import CoreText
@preconcurrency import AppKit

enum MarkdownPreviewCGRenderer {
    static func draw(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString] = [:],
        in context: CGContext,
        bounds: CGRect
    ) {
        context.saveGState()
        context.setFillColor(style.backgroundColor.cgColor)
        context.fill(bounds)

        for (index, blockLayout) in layout.blockLayouts.enumerated() {
            drawBlock(
                blockLayout: blockLayout,
                style: style,
                rasterImage: rasterImages[index],
                highlightedCode: highlightedCode[index],
                in: context
            )
        }
        context.restoreGState()
    }

    private static func drawBlock(
        blockLayout: MarkdownPreviewBlockLayout,
        style: MarkdownPreviewStyle,
        rasterImage: CGImage?,
        highlightedCode: NSAttributedString?,
        in context: CGContext
    ) {
        let frame = blockLayout.frame
        switch blockLayout.block {
        case .heading(let level, let text):
            let font = headingFont(level: level, style: style)
            drawText(text, font: font, color: style.bodyColor, in: context, frame: frame)

        case .paragraph(let text), .blockquote(let text):
            if case .blockquote = blockLayout.block {
                context.setFillColor(style.codeBackgroundColor.cgColor)
                context.fill(frame.insetBy(dx: -6, dy: -4))
            }
            drawText(text, font: style.bodyFont, color: style.bodyColor, in: context, frame: frame)

        case .unorderedList(let items), .orderedList(let items):
            for (itemIndex, itemFrame) in blockLayout.textFrames.enumerated() {
                let marker = blockLayout.block.isOrderedList ? "\(itemIndex + 1)." : "•"
                let markerRect = CGRect(
                    x: frame.minX,
                    y: itemFrame.minY,
                    width: style.listIndent - 6,
                    height: itemFrame.height
                )
                drawPlain(marker, font: style.bodyFont, color: style.bodyColor, in: context, frame: markerRect)
                if itemIndex < items.count {
                    drawText(items[itemIndex], font: style.bodyFont, color: style.bodyColor, in: context, frame: itemFrame)
                }
            }

        case .thematicBreak:
            context.setStrokeColor(style.bodyColor.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: frame.minX, y: frame.midY))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            context.strokePath()

        case .codeBlock(_, let source):
            context.setFillColor(style.codeBackgroundColor.cgColor)
            context.fill(frame)
            let textRect = frame.insetBy(dx: style.codePadding, dy: style.codePadding)
            if let highlightedCode {
                drawAttributed(highlightedCode, in: context, frame: textRect)
            } else {
                drawPlain(source, font: style.codeFont, color: style.bodyColor, in: context, frame: textRect)
            }

        case .image:
            if let image = rasterImage {
                context.draw(image, in: frame)
            } else {
                context.setFillColor(style.codeBackgroundColor.cgColor)
                context.fill(frame)
            }

        case .mermaid:
            if let image = rasterImage {
                context.draw(image, in: frame)
            } else {
                context.setFillColor(style.codeBackgroundColor.cgColor)
                context.fill(frame)
            }

        case .mermaidError(let source, let message):
            context.setFillColor(style.codeBackgroundColor.cgColor)
            context.fill(frame)
            let text = "\(source)\n\n\(message)"
            drawPlain(text, font: style.codeFont, color: .systemRed, in: context, frame: frame.insetBy(dx: style.codePadding, dy: style.codePadding))
        }
    }

    private static func drawText(
        _ text: AttributedString,
        font: NSFont,
        color: NSColor,
        in context: CGContext,
        frame: CGRect
    ) {
        let framesetter = MarkdownPreviewLayout.framesetter(for: text, baseFont: font, color: color)
        drawFramesetter(framesetter, in: context, frame: frame)
    }

    private static func drawAttributed(
        _ attributed: NSAttributedString,
        in context: CGContext,
        frame: CGRect
    ) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        drawFramesetter(framesetter, in: context, frame: frame)
    }

    private static func drawPlain(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in context: CGContext,
        frame: CGRect
    ) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        drawFramesetter(framesetter, in: context, frame: frame)
    }

    private static func drawFramesetter(_ framesetter: CTFramesetter, in context: CGContext, frame: CGRect) {
        context.saveGState()
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(ctFrame, context)
        context.restoreGState()
    }

    private static func headingFont(level: Int, style: MarkdownPreviewStyle) -> NSFont {
        let index = min(max(level - 1, 0), style.headingScale.count - 1)
        let scale = style.headingScale[index]
        return NSFontManager.shared.convert(style.bodyFont, toSize: style.bodyFont.pointSize * scale)
    }
}

private extension MarkdownPreviewBlock {
    var isOrderedList: Bool {
        if case .orderedList = self { return true }
        return false
    }
}
