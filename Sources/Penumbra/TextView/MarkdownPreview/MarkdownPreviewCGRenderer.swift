import CoreText
@preconcurrency import AppKit

enum MarkdownPreviewCGRenderer {
    static func draw(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString] = [:],
        in context: CGContext,
        bounds: CGRect,
        clip: CGRect? = nil
    ) {
        context.saveGState()
        context.setFillColor(style.backgroundColor.cgColor)
        context.fill(bounds)

        for decoration in layout.quoteDecorations {
            if let clip, !decoration.band.insetBy(dx: -2, dy: -2).intersects(clip) {
                continue
            }
            drawQuoteDecoration(decoration, style: style, in: context)
        }

        for (index, blockLayout) in layout.blockLayouts.enumerated() {
            // Decorations (e.g. the checkbox glyph) can extend a few points outside `frame`;
            // inflate before testing so a block right at the tile/dirty-rect edge still paints.
            if let clip, !blockLayout.frame.insetBy(dx: -8, dy: -8).intersects(clip) {
                continue
            }
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

    private static func drawQuoteDecoration(
        _ decoration: MarkdownPreviewQuoteDecoration,
        style: MarkdownPreviewStyle,
        in context: CGContext
    ) {
        guard !style.quoteTints.isEmpty, decoration.band.width > 0, decoration.band.height > 0 else { return }
        let tint = style.quoteTints[(decoration.depth - 1) % style.quoteTints.count]

        context.setFillColor(tint.withAlphaComponent(0.06).cgColor)
        context.fill(decoration.band)

        let barRect = CGRect(x: decoration.band.minX, y: decoration.band.minY, width: style.quoteBarWidth, height: decoration.band.height)
        let barPath = CGPath(
            roundedRect: barRect,
            cornerWidth: style.quoteBarWidth / 2,
            cornerHeight: style.quoteBarWidth / 2,
            transform: nil
        )
        context.addPath(barPath)
        context.setFillColor(tint.withAlphaComponent(0.8).cgColor)
        context.fillPath()
    }

    private static func drawBlock(
        blockLayout: MarkdownPreviewBlockLayout,
        style: MarkdownPreviewStyle,
        rasterImage: CGImage?,
        highlightedCode: NSAttributedString?,
        in context: CGContext
    ) {
        let frame = blockLayout.frame
        switch blockLayout.block.kind {
        case .heading(let level, let text):
            let font = headingFont(level: level, style: style)
            drawText(text, font: font, style: style, in: context, frame: frame)

        case .paragraph(let text):
            drawText(text, font: style.bodyFont, style: style, in: context, frame: frame)

        case .list(let list):
            drawList(list, layout: blockLayout, style: style, in: context)

        case .table(let table):
            if let geometry = blockLayout.table {
                drawTable(table, geometry: geometry, origin: frame.origin, style: style, in: context)
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
                drawImage(image, in: context, frame: frame)
            } else {
                context.setFillColor(style.codeBackgroundColor.cgColor)
                context.fill(frame)
            }

        case .mermaid:
            if let image = rasterImage {
                drawImage(image, in: context, frame: frame)
            } else {
                context.setFillColor(style.codeBackgroundColor.cgColor)
                context.fill(frame)
            }

        case .mermaidError(let source, let message):
            context.setFillColor(style.codeBackgroundColor.cgColor)
            context.fill(frame)
            let text = "\(source)\n\n\(message)"
            drawPlain(
                text, font: style.codeFont, color: .systemRed, in: context,
                frame: frame.insetBy(dx: style.codePadding, dy: style.codePadding)
            )

        case .footnotes(let footnotes):
            drawFootnotes(footnotes, layout: blockLayout, style: style, in: context)
        }
    }

    // MARK: - Footnotes

    private static func drawFootnotes(
        _ footnotes: [MarkdownPreviewFootnote],
        layout: MarkdownPreviewBlockLayout,
        style: MarkdownPreviewStyle,
        in context: CGContext
    ) {
        let footnoteFont = style.footnoteFont(for: style.bodyFont)
        let markerColor = style.bodyColor.withAlphaComponent(0.6)
        for (entryIndex, entry) in footnotes.enumerated() {
            guard entryIndex < layout.textFrames.count, entryIndex < layout.markerFrames.count else { continue }
            let textFrame = layout.textFrames[entryIndex]
            let markerFrame = layout.markerFrames[entryIndex]
            drawPlain("\(entry.number).", font: footnoteFont, color: markerColor, in: context, frame: markerFrame)
            drawText(entry.text, font: footnoteFont, style: style, in: context, frame: textFrame)
        }
    }

    // MARK: - Lists

    private static let bulletGlyphs = ["•", "◦", "▪"]

    private static func drawList(
        _ list: MarkdownPreviewList,
        layout: MarkdownPreviewBlockLayout,
        style: MarkdownPreviewStyle,
        in context: CGContext
    ) {
        for (itemIndex, item) in list.items.enumerated() {
            guard itemIndex < layout.textFrames.count, itemIndex < layout.markerFrames.count else { continue }
            let textFrame = layout.textFrames[itemIndex]
            let markerFrame = layout.markerFrames[itemIndex]

            switch item.marker {
            case .bullet:
                let glyph = bulletGlyphs[min(item.level, bulletGlyphs.count - 1)]
                drawPlain(glyph, font: style.bodyFont, color: style.bodyColor, in: context, frame: markerFrame)
            case .ordered(let n):
                drawPlain("\(n).", font: style.bodyFont, color: style.bodyColor, in: context, frame: markerFrame)
            case .task(let checked):
                drawCheckbox(checked: checked, style: style, in: context, frame: markerFrame)
            }

            let isCheckedTask: Bool = {
                if case .task(true) = item.marker { return true }
                return false
            }()
            let color = (style.dimsCompletedTasks && isCheckedTask) ? style.bodyColor.withAlphaComponent(0.55) : nil
            drawText(item.text, font: style.bodyFont, color: color, style: style, in: context, frame: textFrame)
        }
    }

    private static func drawCheckbox(checked: Bool, style: MarkdownPreviewStyle, in context: CGContext, frame: CGRect) {
        let size = min(style.checkboxSize, frame.height)
        guard size > 0 else { return }
        let rect = CGRect(x: frame.minX, y: frame.midY - size / 2, width: size, height: size)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)

        if checked {
            context.addPath(path)
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillPath()

            let check = CGMutablePath()
            check.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.52))
            check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.28))
            check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.72))
            context.addPath(check)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(max(1.2, size * 0.12))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(style.bodyColor.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    // MARK: - Tables

    private static func drawTable(
        _ table: MarkdownPreviewTable,
        geometry: MarkdownPreviewTableGeometry,
        origin: CGPoint,
        style: MarkdownPreviewStyle,
        in context: CGContext
    ) {
        guard geometry.totalSize.width > 0, geometry.totalSize.height > 0 else { return }

        func absolute(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX, y: origin.y + rect.minY, width: rect.width, height: rect.height)
        }

        if let headerFrame = geometry.headerFrame {
            context.setFillColor(style.codeBackgroundColor.cgColor)
            context.fill(absolute(headerFrame))
        }

        for (index, cellFrame) in geometry.headerCellFrames.enumerated() where index < table.header.count {
            drawCellText(
                table.header[index], bold: true, alignment: textAlignment(for: table, column: index),
                style: style, in: context, frame: absolute(cellFrame).insetBy(dx: style.tableCellPadding, dy: style.tableCellPadding)
            )
        }
        for (rowIndex, row) in table.rows.enumerated() where rowIndex < geometry.cellFrames.count {
            for (columnIndex, cellFrame) in geometry.cellFrames[rowIndex].enumerated() {
                let text = columnIndex < row.count ? row[columnIndex] : AttributedString()
                drawCellText(
                    text, bold: false, alignment: textAlignment(for: table, column: columnIndex),
                    style: style, in: context, frame: absolute(cellFrame).insetBy(dx: style.tableCellPadding, dy: style.tableCellPadding)
                )
            }
        }

        context.setStrokeColor(style.tableBorderColor.cgColor)
        context.setLineWidth(1)
        let totalRect = absolute(CGRect(origin: .zero, size: geometry.totalSize))
        context.addRect(totalRect)
        if let headerFrame = geometry.headerFrame {
            let y = origin.y + headerFrame.maxY
            context.move(to: CGPoint(x: totalRect.minX, y: y))
            context.addLine(to: CGPoint(x: totalRect.maxX, y: y))
        }
        for rowFrame in geometry.rowFrames.dropLast() {
            let y = origin.y + rowFrame.maxY
            context.move(to: CGPoint(x: totalRect.minX, y: y))
            context.addLine(to: CGPoint(x: totalRect.maxX, y: y))
        }
        for columnFrame in geometry.columnFrames.dropLast() {
            let x = origin.x + columnFrame.maxX
            context.move(to: CGPoint(x: x, y: totalRect.minY))
            context.addLine(to: CGPoint(x: x, y: totalRect.maxY))
        }
        context.strokePath()
    }

    private static func textAlignment(for table: MarkdownPreviewTable, column: Int) -> NSTextAlignment {
        guard column < table.columns.count else { return .natural }
        switch table.columns[column].alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    private static func drawCellText(
        _ text: AttributedString,
        bold: Bool,
        alignment: NSTextAlignment,
        style: MarkdownPreviewStyle,
        in context: CGContext,
        frame: CGRect
    ) {
        let font = bold ? NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .boldFontMask) : style.bodyFont
        let framesetter = MarkdownPreviewLayout.framesetter(for: text, baseFont: font, style: style, alignment: alignment)
        drawFramesetter(framesetter, in: context, frame: frame)
    }

    // MARK: - Text / image primitives

    private static func drawText(
        _ text: AttributedString,
        font: NSFont,
        color: NSColor? = nil,
        style: MarkdownPreviewStyle,
        in context: CGContext,
        frame: CGRect
    ) {
        let framesetter = MarkdownPreviewLayout.framesetter(for: text, baseFont: font, style: style, color: color)
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

    /// Draws `image` aspect-fit and centered within `frame`, never upscaled beyond `frame`.
    ///
    /// Applies the same local un-flip `drawFramesetter` uses: both this function's caller and
    /// `MarkdownPreviewMetalRenderer.makeTileImage` hand `draw(layout:...)` a top-down (flipped)
    /// `CGContext`, and `context.draw(_:in:)` places image row 0 at the *bottom* of a flipped CTM
    /// — without this, mermaid diagrams and markdown images render vertically mirrored.
    private static func drawImage(_ image: CGImage, in context: CGContext, frame: CGRect) {
        guard frame.width > 0, frame.height > 0, image.width > 0, image.height > 0 else { return }
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let fitScale = min(frame.width / imageWidth, frame.height / imageHeight)
        let drawWidth = imageWidth * fitScale
        let drawHeight = imageHeight * fitScale
        let rect = CGRect(
            x: frame.minX + (frame.width - drawWidth) / 2,
            y: frame.minY + (frame.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        context.saveGState()
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    private static func headingFont(level: Int, style: MarkdownPreviewStyle) -> NSFont {
        let index = min(max(level - 1, 0), style.headingScale.count - 1)
        let scale = style.headingScale[index]
        return NSFontManager.shared.convert(style.bodyFont, toSize: style.bodyFont.pointSize * scale)
    }
}
