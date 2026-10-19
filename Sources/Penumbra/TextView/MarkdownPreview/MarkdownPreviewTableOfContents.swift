import Foundation

/// Expands the `{{TOC}}` instruction into a bare-bones hierarchical table of contents.
///
/// A line holding exactly `{{TOC}}` (up to 3 leading spaces, like an ATX heading) is
/// replaced with a nested bullet list linking to every ATX heading (`#` through `######`) in
/// the document, e.g. `- [Getting Started](#getting-started)`, indented two spaces per level
/// below the shallowest heading. Both consumers of ``MarkdownPreviewDocument/parse(_:)`` — the
/// on-screen preview and PDF export — render the result with no further work, since the
/// generated entries are ordinary markdown links (see ``MarkdownPreviewInlineStyler``).
///
/// Bare-bones on purpose: ATX headings only (no Setext underline headings), plain-text entry
/// titles (inline formatting is stripped), GitHub-style slugs, and no click-to-scroll — the
/// preview's links are painted, not hit-tested, today. A `{{TOC}}` line or `#` heading inside
/// a fenced code block is left alone, as is a `{{TOC}}` line indented as code.
enum MarkdownPreviewTableOfContents {
    /// A line that is exactly this (after trimming whitespace) marks where the TOC goes.
    private static let marker = "{{TOC}}"

    private static let closingHashes = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    private static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^[^\]\s]+\]"#)
    private static let fenceLine = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)

    /// Returns `source` with every `{{TOC}}` marker line (outside fenced code) replaced by the
    /// generated list. Returns `source` unchanged when it contains no marker at all, so
    /// documents without the instruction pay for one substring search and nothing more.
    static func expanded(_ source: String) -> String {
        guard source.contains(marker) else { return source }
        let lines = source.components(separatedBy: "\n")
        var headings: [(level: Int, title: String)] = []
        var markerLines: [Int] = []
        var fenceMarker: String?

        for (index, line) in lines.enumerated() {
            if let open = fenceMarker {
                if isClosingFence(line, opening: open) { fenceMarker = nil }
                continue
            }
            if isFenceLine(line) {
                fenceMarker = openingFenceMarker(line)
                continue
            }
            if isMarkerLine(line) {
                markerLines.append(index)
                continue
            }
            if let heading = parseHeading(line) {
                headings.append(heading)
            }
        }

        guard !markerLines.isEmpty else { return source }

        let list = tocMarkdown(for: headings)
        var output = lines
        for index in markerLines {
            output[index] = list
        }
        return output.joined(separator: "\n")
    }

    /// A `{{TOC}}` instruction: the whole line (up to 3 leading spaces, like an ATX heading)
    /// is the marker. Deeper indentation is an indented code block, and a tab stop is too.
    private static func isMarkerLine(_ line: String) -> Bool {
        var rest = line[...]
        var spaces = 0
        while rest.first == " " {
            spaces += 1
            rest = rest.dropFirst()
        }
        guard spaces <= 3, rest.first != "\t" else { return false }
        return String(rest).trimmingCharacters(in: .whitespaces) == marker
    }

    // MARK: - Heading scanning

    /// An ATX heading outside fenced code: up to 3 leading spaces, an optional blockquote
    /// prefix, 1–6 `#` followed by whitespace or end of line, and a non-empty title with any
    /// closing hash run stripped.
    static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        var rest = line[...]
        var spaces = 0
        while rest.first == " " {
            spaces += 1
            rest = rest.dropFirst()
        }
        guard spaces <= 3 else { return nil }
        // Quoted headings (`> # Title`) still render as headings, so they belong in the TOC.
        while rest.first == ">" {
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        }
        var level = 0
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1 ... 6).contains(level) else { return nil }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = String(rest).trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }
        let ns = title as NSString
        if let match = closingHashes.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) {
            title = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    // MARK: - TOC generation

    /// Nested markdown list for `headings`, normalized so the shallowest heading starts at
    /// column 0. Empty when there are no headings (the marker line is then just removed).
    static func tocMarkdown(for headings: [(level: Int, title: String)]) -> String {
        guard let minLevel = headings.map(\.level).min() else { return "" }
        var usedSlugs = Set<String>()
        return headings.map { heading in
            let plain = plainText(heading.title)
            let slug = slug(for: plain, used: &usedSlugs)
            let indent = String(repeating: "  ", count: heading.level - minLevel)
            return "\(indent)- [\(escapeLinkText(plain))](#\(slug))"
        }.joined(separator: "\n")
    }

    /// The heading's visible text with inline markdown resolved: `**bold**` and `[text](url)`
    /// contribute their rendered characters, so slugs and titles match what the reader sees.
    /// Footnote references (`[^1]`) never resolve here and are dropped from the slug input.
    static func plainText(_ markdown: String) -> String {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.trimmingCharacters(in: .whitespaces)
        }
        var plain = String(parsed.characters)
        let ns = plain as NSString
        let range = NSRange(location: 0, length: ns.length)
        plain = footnoteReference.stringByReplacingMatches(in: plain, range: range, withTemplate: "")
        return plain.trimmingCharacters(in: .whitespaces)
    }

    /// GitHub-style anchor: lowercase, keep Unicode letters/numbers plus space, `-` and `_`,
    /// spaces become `-`, duplicates gain `-1`, `-2`, … suffixes.
    static func slug(for plain: String, used: inout Set<String>) -> String {
        let lowered = plain.lowercased()
        var slug = String(lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }.map(Character.init))
        slug = slug.replacingOccurrences(of: " ", with: "-")
        if slug.isEmpty { slug = "section" }
        var candidate = slug
        var suffix = 1
        while used.contains(candidate) {
            suffix += 1
            candidate = "\(slug)-\(suffix - 1)"
        }
        used.insert(candidate)
        return candidate
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - Fence tracking

    /// Same fence model as ``MarkdownPreviewFootnotes`` (which tracks fences independently of
    /// `MermaidFenceExtractor` so `~~~` fences are protected too).
    private static func isFenceLine(_ line: String) -> Bool {
        let ns = line as NSString
        return fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func openingFenceMarker(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " })
        guard let fenceChar = trimmed.first else { return "```" }
        return String(trimmed.prefix(while: { $0 == fenceChar }))
    }

    private static func isClosingFence(_ line: String, opening marker: String) -> Bool {
        guard let fenceChar = marker.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == fenceChar else { return false }
        let run = trimmed.prefix(while: { $0 == fenceChar })
        guard run.count >= marker.count else { return false }
        return trimmed.dropFirst(run.count).isEmpty
    }
}
