@preconcurrency import AppKit

/// Renders the Markdown a hover provider returns into an attributed string: paragraphs, `-`
/// bullets, fenced code blocks, and inline `**bold**`, `*italic*` and `` `code` ``.
///
/// It handles the subset hover text actually uses rather than all of CommonMark, so a hover never
/// depends on a Markdown view.
enum HoverMarkdownRenderer {
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func render(_ markdown: String, isMarkdown: Bool = true) -> NSAttributedString {
        guard isMarkdown else {
            return NSAttributedString(string: markdown, attributes: baseAttributes())
        }
        let result = NSMutableAttributedString()
        func append(_ piece: NSAttributedString) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(piece)
        }

        var codeLines: [String]?
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(inline(paragraph.joined(separator: " "), style: paragraphStyle(spacingBefore: 0, spacing: 6)))
            paragraph = []
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if var code = codeLines {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    append(codeBlock(code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    code.append(raw)
                    codeLines = code
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                codeLines = []
            } else if line.isEmpty {
                flushParagraph()
            } else if line == "---" {
                flushParagraph()
                append(separator())
            } else if line.hasPrefix("- ") {
                flushParagraph()
                append(bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        if let code = codeLines { append(codeBlock(code.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }

    /// The size the rendered text needs at up to `maxWidth`, before padding.
    static func size(of text: NSAttributedString, maxWidth: CGFloat) -> NSSize {
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let natural = text.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: options)
        let width = min(ceil(natural.width) + 1, maxWidth)
        let wrapped = text.boundingRect(with: NSSize(width: width, height: 10_000), options: options)
        return NSSize(width: width, height: ceil(wrapped.height))
    }

    // MARK: - Blocks

    private static func baseAttributes(font: NSFont = bodyFont, style: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if let style { attributes[.paragraphStyle] = style }
        return attributes
    }

    private static func paragraphStyle(spacingBefore: CGFloat, spacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func codeBlock(_ code: String) -> NSAttributedString {
        let style = paragraphStyle(spacingBefore: 0, spacing: 6)
        var attributes = baseAttributes(font: codeFont, style: style)
        attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07)
        return NSAttributedString(string: code, attributes: attributes)
    }

    private static func bullet(_ text: String) -> NSAttributedString {
        let style = paragraphStyle(spacingBefore: 0, spacing: 2)
        style.firstLineHeadIndent = 2
        style.headIndent = 14
        style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        let result = NSMutableAttributedString(string: "•\t", attributes: baseAttributes(style: style))
        result.append(inline(text, style: style))
        return result
    }

    private static func separator() -> NSAttributedString {
        let style = paragraphStyle(spacingBefore: 2, spacing: 4)
        var attributes = baseAttributes(font: NSFont.systemFont(ofSize: 4), style: style)
        attributes[.foregroundColor] = NSColor.separatorColor
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        attributes[.strikethroughColor] = NSColor.separatorColor
        return NSAttributedString(string: " \u{00A0}\u{00A0} ", attributes: attributes)
    }

    // MARK: - Inline

    private static func inline(_ markdown: String, style: NSParagraphStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(style: style))
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var attributes = baseAttributes(style: style)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = codeFont
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07)
            } else {
                var font = bodyFont
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                attributes[.font] = font
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}
