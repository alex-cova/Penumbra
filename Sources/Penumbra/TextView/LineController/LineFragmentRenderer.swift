import Foundation
import CoreText
@preconcurrency import AppKit

protocol LineFragmentRendererDelegate: AnyObject {
    func string(in lineFragmentRenderer: LineFragmentRenderer) -> String?
}

final class LineFragmentRenderer: @unchecked Sendable {
    weak var delegate: LineFragmentRendererDelegate?
    var lineFragment: LineFragment
    let invisibleCharacterConfiguration: InvisibleCharacterConfiguration
    var markedRange: NSRange?
    var markedTextBackgroundColor: UIColor = .systemFill
    var markedTextBackgroundCornerRadius: CGFloat = 0
    var highlightedRangeFragments: [HighlightedRangeFragment] = []
    /// Alpha applied to glyphs outside `focusedRanges` when Focus Mode is enabled. `1` (the
    /// default) disables dimming entirely and keeps the original single-pass draw.
    var unfocusedAlpha: CGFloat = 1
    /// Ranges, in the same line-local coordinates as `highlightedRangeFragments`, that stay at
    /// full opacity while `unfocusedAlpha < 1`. Empty means the entire fragment is dimmed.
    var focusedRanges: [NSRange] = []
    /// Text drawn right after this fragment's content, used to indicate a collapsed fold whose
    /// header line is this fragment's line. `nil` on every other line fragment.
    var foldPlaceholderText: String?
    var foldPlaceholderColor: UIColor = .secondaryLabelColor
    var foldPlaceholderBackgroundColor: UIColor = .quaternaryLabelColor

    private var showInvisibleCharacters: Bool {
        invisibleCharacterConfiguration.showTabs
            || invisibleCharacterConfiguration.showSpaces
            || invisibleCharacterConfiguration.showLineBreaks
            || invisibleCharacterConfiguration.showSoftLineBreaks
    }

    init(lineFragment: LineFragment, invisibleCharacterConfiguration: InvisibleCharacterConfiguration) {
        self.lineFragment = lineFragment
        self.invisibleCharacterConfiguration = invisibleCharacterConfiguration
    }

    func draw(to context: CGContext, inCanvasOfSize canvasSize: CGSize) {
        drawHighlightedRanges(to: context, inCanvasOfSize: canvasSize)
        drawMarkedRange(to: context)
        drawGlyphs(to: context)
        drawFoldPlaceholder(to: context)
    }
}

private extension LineFragmentRenderer {
    /// Draws invisible characters and text, dimmed outside `focusedRanges` when Focus Mode is
    /// enabled. Highlighted ranges, the marked-text background, and the fold placeholder are
    /// deliberately drawn outside of this (at full opacity, see `draw(to:inCanvasOfSize:)`) so
    /// selection, find matches, and diagnostics stay legible regardless of focus.
    private func drawGlyphs(to context: CGContext) {
        guard unfocusedAlpha < 1 else {
            drawInvisibleCharacters(to: context)
            drawText(to: context)
            return
        }
        let fullRange = lineFragment.range
        let focused = mergedAndClamped(focusedRanges, to: fullRange)
        let dimmed = complementSpans(of: focused, in: fullRange)
        guard !dimmed.isEmpty else {
            // The entire fragment is focused; draw once at full opacity.
            drawInvisibleCharacters(to: context)
            drawText(to: context)
            return
        }
        for span in dimmed {
            drawGlyphs(to: context, clippedTo: span, alpha: unfocusedAlpha)
        }
        for span in focused {
            drawGlyphs(to: context, clippedTo: span, alpha: 1)
        }
    }

    private func drawGlyphs(to context: CGContext, clippedTo lineLocalRange: NSRange, alpha: CGFloat) {
        context.saveGState()
        let startX = CTLineGetOffsetForStringIndex(lineFragment.line, lineLocalRange.lowerBound, nil)
        let endX = CTLineGetOffsetForStringIndex(lineFragment.line, lineLocalRange.upperBound, nil)
        let clipRect = CGRect(x: startX, y: 0, width: max(endX - startX, 0), height: lineFragment.scaledSize.height)
        context.clip(to: clipRect)
        context.setAlpha(alpha)
        drawInvisibleCharacters(to: context)
        drawText(to: context)
        context.restoreGState()
    }

    /// Clamps `ranges` to `fullRange`, drops empty results, sorts, and merges overlaps/adjacency
    /// so the spans that follow (focused and dimmed alike) are disjoint and ordered.
    private func mergedAndClamped(_ ranges: [NSRange], to fullRange: NSRange) -> [NSRange] {
        let capped = ranges.map { $0.capped(to: fullRange) }.filter { $0.length > 0 }
        let sorted = capped.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(last.upperBound, range.upperBound) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The gaps between `ranges` (assumed disjoint and sorted) within `fullRange`.
    private func complementSpans(of ranges: [NSRange], in fullRange: NSRange) -> [NSRange] {
        var spans: [NSRange] = []
        var cursor = fullRange.location
        for range in ranges {
            if range.location > cursor {
                spans.append(NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < fullRange.upperBound {
            spans.append(NSRange(location: cursor, length: fullRange.upperBound - cursor))
        }
        return spans
    }
}

private extension LineFragmentRenderer {
    private func drawHighlightedRanges(to context: CGContext, inCanvasOfSize canvasSize: CGSize) {
        guard !highlightedRangeFragments.isEmpty else {
            return
        }
        context.saveGState()
        for highlightedRange in highlightedRangeFragments {
            switch highlightedRange.style {
            case .standard:
                drawStandardHighlight(highlightedRange, in: context, canvasSize: canvasSize)
            case .underline:
                drawUnderlineHighlight(highlightedRange, in: context)
            case .squiggle:
                drawSquiggleHighlight(highlightedRange, in: context)
            case .outline(_, let fill):
                drawOutlineHighlight(highlightedRange, in: context, fill: fill)
            }
        }
        context.restoreGState()
    }

    private func drawStandardHighlight(_ highlightedRange: HighlightedRangeFragment, in context: CGContext, canvasSize: CGSize) {
        let startX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.lowerBound, nil)
        let endX: CGFloat
        if shouldHighlightLineEnding(for: highlightedRange) {
            endX = canvasSize.width
        } else {
            endX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.upperBound, nil)
        }
        let rect = CGRect(x: startX, y: 0, width: endX - startX, height: lineFragment.scaledSize.height)
        let roundedCorners = highlightedRange.roundedCorners
        let fillColor = highlightedRange.isInactive ? highlightedRange.color.withAlphaComponent(0.25) : highlightedRange.color
        context.setFillColor(fillColor.cgColor)
        if !roundedCorners.isEmpty && highlightedRange.cornerRadius > 0 {
            let cornerRadii = CGSize(width: highlightedRange.cornerRadius, height: highlightedRange.cornerRadius)
            let bezierPath = UIBezierPath(roundedRect: rect, byRoundingCorners: roundedCorners, cornerRadii: cornerRadii)
            context.addPath(bezierPath.cgPath)
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    private func drawUnderlineHighlight(_ highlightedRange: HighlightedRangeFragment, in context: CGContext) {
        drawLineHighlight(highlightedRange, in: context, wavy: false)
    }

    private func drawSquiggleHighlight(_ highlightedRange: HighlightedRangeFragment, in context: CGContext) {
        drawLineHighlight(highlightedRange, in: context, wavy: true)
    }

    private func drawLineHighlight(_ highlightedRange: HighlightedRangeFragment, in context: CGContext, wavy: Bool) {
        let startX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.lowerBound, nil)
        let endX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.upperBound, nil)
        let y = lineFragment.scaledSize.height - 2
        context.setStrokeColor(highlightedRange.color.cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if wavy {
            let amplitude: CGFloat = 1.5
            let wavelength: CGFloat = 4
            var x = startX
            context.move(to: CGPoint(x: x, y: y))
            while x < endX {
                let midX = min(x + wavelength / 2, endX)
                let nextX = min(x + wavelength, endX)
                context.addQuadCurve(to: CGPoint(x: midX, y: y + amplitude), control: CGPoint(x: (x + midX) / 2, y: y - amplitude))
                context.addQuadCurve(to: CGPoint(x: nextX, y: y), control: CGPoint(x: (midX + nextX) / 2, y: y + amplitude))
                x = nextX
            }
        } else {
            context.move(to: CGPoint(x: startX, y: y))
            context.addLine(to: CGPoint(x: endX, y: y))
        }
        context.strokePath()
    }

    private func drawOutlineHighlight(_ highlightedRange: HighlightedRangeFragment, in context: CGContext, fill: Bool) {
        let startX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.lowerBound, nil)
        let endX = CTLineGetOffsetForStringIndex(lineFragment.line, highlightedRange.range.upperBound, nil)
        let inset: CGFloat = 1
        let rect = CGRect(x: startX - inset,
                          y: inset,
                          width: max(endX - startX + inset * 2, 2),
                          height: lineFragment.scaledSize.height - inset * 2)
        let path = CGPath(roundedRect: rect,
                          cornerWidth: highlightedRange.cornerRadius,
                          cornerHeight: highlightedRange.cornerRadius,
                          transform: nil)
        if fill {
            context.setFillColor(highlightedRange.color.withAlphaComponent(0.2).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.setStrokeColor(highlightedRange.color.cgColor)
        context.setLineWidth(0.5)
        context.addPath(path)
        context.strokePath()
    }

    private func drawMarkedRange(to context: CGContext) {
        if let markedRange = markedRange {
            context.saveGState()
            let startX = CTLineGetOffsetForStringIndex(lineFragment.line, markedRange.lowerBound, nil)
            let endX = CTLineGetOffsetForStringIndex(lineFragment.line, markedRange.upperBound, nil)
            let rect = CGRect(x: startX, y: 0, width: endX - startX, height: lineFragment.scaledSize.height)
            context.setFillColor(markedTextBackgroundColor.cgColor)
            if markedTextBackgroundCornerRadius > 0 {
                let cornerRadius = markedTextBackgroundCornerRadius
                let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.addPath(path)
                context.fillPath()
            } else {
                context.fill(rect)
            }
            context.restoreGState()
        }
    }

    private func drawFoldPlaceholder(to context: CGContext) {
        guard let foldPlaceholderText else {
            return
        }
        context.saveGState()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: foldPlaceholderColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .medium)
        ]
        let size = foldPlaceholderText.size(withAttributes: attrs)
        let endOfLineX = CGFloat(CTLineGetTypographicBounds(lineFragment.line, nil, nil, nil))
        let padding: CGFloat = 4
        let backgroundRect = CGRect(x: endOfLineX + padding,
                                    y: (lineFragment.scaledSize.height - size.height) / 2 - 1,
                                    width: size.width + padding * 2,
                                    height: size.height + 2)
        let cornerRadius = backgroundRect.height / 2
        let backgroundPath = CGPath(roundedRect: backgroundRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(foldPlaceholderBackgroundColor.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()
        let textRect = CGRect(x: backgroundRect.minX + padding,
                              y: (lineFragment.scaledSize.height - size.height) / 2,
                              width: size.width,
                              height: size.height)
        foldPlaceholderText.draw(in: textRect, withAttributes: attrs)
        context.restoreGState()
    }

    private func drawInvisibleCharacters(to context: CGContext) {
        guard let string = delegate?.string(in: self) else {
            return
        }
        if showInvisibleCharacters || !invisibleCharacterConfiguration.warningCharacters.isEmpty {
            drawInvisibleCharacters(in: string, context: context)
        }
    }

    private func drawText(to context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: lineFragment.scaledSize.height)
        context.scaleBy(x: 1, y: -1)
        let yPosition = lineFragment.descent + (lineFragment.scaledSize.height - lineFragment.baseSize.height) / 2
        context.textPosition = CGPoint(x: 0, y: yPosition)
        CTLineDraw(lineFragment.line, context)
        context.restoreGState()
    }

    private func drawInvisibleCharacters(in string: String, context: CGContext) {
        // Shared with the Metal decoration builder so the two paths cannot disagree on which
        // markers appear or where they sit.
        let layout = InvisibleCharacterLayout.resolve(
            fragmentString: string,
            lineFragment: lineFragment,
            configuration: invisibleCharacterConfiguration
        )
        for warning in layout.warnings {
            drawWarningBorder(atX: warning.x, in: context)
        }
        for mark in layout.symbols {
            draw(mark.string, atX: mark.x, color: mark.color)
        }
    }

    private func drawWarningBorder(atX xPosition: CGFloat, in context: CGContext) {
        let size = CGSize(width: max(invisibleCharacterConfiguration.font.pointSize * 0.55, 6), height: invisibleCharacterConfiguration.font.pointSize)
        let rect = CGRect(x: xPosition, y: (lineFragment.scaledSize.height - size.height) / 2, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.saveGState()
        context.setStrokeColor(invisibleCharacterConfiguration.warningBorderColor.cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func draw(_ symbol: String, atX xPosition: CGFloat, color: UIColor? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color ?? invisibleCharacterConfiguration.textColor,
            .font: invisibleCharacterConfiguration.font
        ]
        let size = symbol.size(withAttributes: attrs)
        let yPosition = (lineFragment.scaledSize.height - size.height) / 2
        let rect = CGRect(x: xPosition, y: yPosition, width: size.width, height: size.height)
        symbol.draw(in: rect, withAttributes: attrs)
    }

    private func shouldHighlightLineEnding(for highlightedRangeFragment: HighlightedRangeFragment) -> Bool {
        guard highlightedRangeFragment.range.upperBound == lineFragment.range.upperBound else {
            return false
        }
        guard let string = delegate?.string(in: self), let lastCharacter = string.last else {
            return false
        }
        return isLineBreak(lastCharacter)
    }

    private func isLineBreak(_ string: String.Element) -> Bool {
        string == Symbol.Character.lineFeed || string == Symbol.Character.carriageReturn || string == Symbol.Character.carriageReturnLineFeed
    }
}
