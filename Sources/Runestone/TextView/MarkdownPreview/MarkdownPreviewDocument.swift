import Foundation

/// A single block in the rendered markdown preview.
public enum MarkdownPreviewBlock: Sendable, Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case unorderedList([AttributedString])
    case orderedList([AttributedString])
    case blockquote(AttributedString)
    case thematicBreak
    case codeBlock(language: String?, source: String)
    case image(alt: String, reference: String)
    case mermaid(source: String)
    case mermaidError(source: String, message: String)
}

/// Parsed markdown ready for layout and painting.
public struct MarkdownPreviewDocument: Sendable, Equatable {
    public var blocks: [MarkdownPreviewBlock]

    public init(blocks: [MarkdownPreviewBlock] = []) {
        self.blocks = blocks
    }

    /// Parses CommonMark-ish markdown into preview blocks. Mermaid fences are extracted first.
    public static func parse(_ source: String) -> MarkdownPreviewDocument {
        var blocks: [MarkdownPreviewBlock] = []
        for segment in MermaidFenceExtractor.segments(in: source) {
            switch segment {
            case .prose(let prose):
                blocks.append(contentsOf: parseProse(prose))
            case .fencedCode(let language, let body):
                if MermaidFenceExtractor.isMermaidFence(language) {
                    blocks.append(.mermaid(source: body))
                } else {
                    blocks.append(.codeBlock(language: language, source: body))
                }
            }
        }
        return MarkdownPreviewDocument(blocks: blocks)
    }

    private static func parseProse(_ prose: String) -> [MarkdownPreviewBlock] {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var blocks: [MarkdownPreviewBlock] = []
        let paragraphs = trimmed.components(separatedBy: "\n\n")

        for paragraph in paragraphs {
            let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }

            if lines.count == 1, lines[0].trimmingCharacters(in: .whitespaces) == "---" {
                blocks.append(.thematicBreak)
                continue
            }

            if lines.count == 1, let image = parseImageLine(lines[0]) {
                blocks.append(.image(alt: image.alt, reference: image.reference))
                continue
            }

            if let heading = parseHeading(lines[0]) {
                blocks.append(.heading(level: heading.level, text: inlineMarkdown(heading.text)))
                if lines.count > 1 {
                    let tail = lines.dropFirst().joined(separator: "\n")
                    blocks.append(.paragraph(inlineMarkdown(tail)))
                }
                continue
            }

            if lines.allSatisfy({ $0.hasPrefix("> ") || $0 == ">" }) {
                let quote = lines.map { line in
                    line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                }.joined(separator: "\n")
                blocks.append(.blockquote(inlineMarkdown(quote)))
                continue
            }

            if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("+ ") }) {
                let items = lines.map { inlineMarkdown(String($0.dropFirst(2))) }
                blocks.append(.unorderedList(items))
                continue
            }

            if lines.allSatisfy({ $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }) {
                let items = lines.map { line in
                    let stripped = line.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression)
                    return inlineMarkdown(stripped)
                }
                blocks.append(.orderedList(items))
                continue
            }

            blocks.append(.paragraph(inlineMarkdown(paragraph)))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level > 0, level <= 6, line.count > level else { return nil }
        let index = line.index(line.startIndex, offsetBy: level)
        guard line[index] == " " else { return nil }
        return (level, String(line[line.index(after: index)...]))
    }

    private static func parseImageLine(_ line: String) -> (alt: String, reference: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["),
              let closeAlt = trimmed.firstIndex(of: "]"),
              trimmed[trimmed.index(after: closeAlt)] == "(",
              let closeRef = trimmed.lastIndex(of: ")") else { return nil }
        let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let alt = String(trimmed[altStart..<closeAlt])
        let refStart = trimmed.index(after: closeAlt)
        let reference = String(trimmed[trimmed.index(after: refStart)..<closeRef])
        return (alt, reference)
    }

    /// Accessibility text for each block, in document order.
    public var accessibilityDescriptions: [String] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text):
                return "Heading \(level): \(String(text.characters))"
            case .paragraph(let text), .blockquote(let text):
                return String(text.characters)
            case .unorderedList(let items), .orderedList(let items):
                return items.map { String($0.characters) }.joined(separator: ", ")
            case .thematicBreak:
                return "Thematic break"
            case .codeBlock(_, let source):
                return "Code block: \(source)"
            case .image(let alt, let reference):
                return alt.isEmpty ? "Image: \(reference)" : alt
            case .mermaid(let source), .mermaidError(let source, _):
                return "Mermaid diagram: \(source)"
            }
        }
    }

    private static func inlineMarkdown(_ source: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}
