@preconcurrency import AppKit
import Foundation

/// Turns a parsed markdown `AttributedString` fragment (heading text, a paragraph, a list item, a
/// table cell) into a styled `NSAttributedString`, honoring `inlinePresentationIntent` (bold,
/// italic, inline code, strikethrough), `link`, and `footnoteMarker` (a resolved `[^1]` reference,
/// substituted by ``MarkdownPreviewFootnotes`` before this ever sees the run).
///
/// Used by both `MarkdownPreviewLayout` (measurement) and `MarkdownPreviewCGRenderer` (painting)
/// so the two can never disagree about a run's font/size and therefore its wrapped height.
enum MarkdownPreviewInlineStyler {
    static func attributedString(
        _ text: AttributedString,
        baseFont: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .natural,
        style: MarkdownPreviewStyle
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        paragraphStyle.alignment = alignment

        let result = NSMutableAttributedString()
        for run in text.runs {
            let substring = String(text[run.range].characters)
            guard !substring.isEmpty else { continue }

            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraphStyle]
            let intent = run.inlinePresentationIntent ?? []

            if run.footnoteMarker != nil {
                let referenceFont = NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize * style.footnoteReferenceScale)
                attributes[.font] = referenceFont
                attributes[.foregroundColor] = style.linkColor
                attributes[.baselineOffset] = baseFont.pointSize * style.footnoteReferenceBaselineRatio
                result.append(NSAttributedString(string: substring, attributes: attributes))
                continue
            }

            if intent.contains(.code) {
                attributes[.font] = NSFontManager.shared.convert(style.codeFont, toSize: baseFont.pointSize)
                attributes[.backgroundColor] = style.codeBackgroundColor
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                attributes[.font] = traits.isEmpty ? baseFont : NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
            }

            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            if let link = run.link {
                attributes[.foregroundColor] = style.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.link] = link
            } else {
                attributes[.foregroundColor] = color
            }

            result.append(NSAttributedString(string: substring, attributes: attributes))
        }

        if result.length == 0 {
            // A genuinely empty fragment (e.g. a ragged table cell) still needs a font attribute
            // so downstream `CTFramesetter`/`.attribute(at: 0, ...)` calls don't fail on an
            // out-of-range index.
            result.append(NSAttributedString(string: "", attributes: [
                .font: baseFont,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]))
        }

        return result
    }
}
