import Foundation

/// Turns the body of a Javadoc comment (as `JavaSourceStubBuilder` stores it: the `/** */` and the
/// leading `*` already stripped, block tags left as written) into Markdown for a hover popup.
///
/// This covers what API docs actually use: `{@code}`, `{@link}`, the common HTML tags, and the
/// `@param` / `@return` / `@throws` / `@see` / `@deprecated` block tags. Anything else is dropped
/// rather than shown raw.
enum JavadocMarkdown {
    static func format(_ javadoc: String) -> String {
        let (description, tags) = split(javadoc)
        var sections: [String] = []

        if let deprecated = tags.first(where: { $0.name == "deprecated" }) {
            let text = inline(deprecated.text)
            sections.append(text.isEmpty ? "**Deprecated.**" : "**Deprecated.** \(text)")
        }
        let body = blocks(description)
        if !body.isEmpty { sections.append(body) }

        let parameters = tags.filter { $0.name == "param" }
        if !parameters.isEmpty {
            sections.append("**Parameters**\n" + parameters.map { "- \(entry($0.text))" }.joined(separator: "\n"))
        }
        if let returns = tags.first(where: { $0.name == "return" }) {
            sections.append("**Returns** \(inline(returns.text))")
        }
        let thrown = tags.filter { $0.name == "throws" || $0.name == "exception" }
        if !thrown.isEmpty {
            sections.append("**Throws**\n" + thrown.map { "- \(entry($0.text))" }.joined(separator: "\n"))
        }
        let see = tags.filter { $0.name == "see" }
        if !see.isEmpty {
            sections.append("**See also** " + see.map { reference($0.text) }.joined(separator: ", "))
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Splitting

    private struct Tag {
        let name: String
        let text: String
    }

    /// The description and the block tags. A tag runs until the next line that starts with `@`.
    private static func split(_ javadoc: String) -> (String, [Tag]) {
        var description: [String] = []
        var tags: [Tag] = []
        var currentName: String?
        var currentLines: [String] = []
        func flush() {
            if let name = currentName {
                tags.append(Tag(name: name, text: currentLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
            }
            currentName = nil
            currentLines = []
        }
        var insidePre = false
        for rawLine in javadoc.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.contains("<pre") { insidePre = true }
            if !insidePre, line.hasPrefix("@"), let match = line.range(of: #"^@(\w+)\s*"#, options: .regularExpression) {
                flush()
                let header = String(line[match])
                currentName = String(header.dropFirst().trimmingCharacters(in: .whitespaces))
                currentLines = [String(line[match.upperBound...])]
                continue
            }
            if lower.contains("</pre>") { insidePre = false }
            if currentName != nil {
                currentLines.append(line)
            } else {
                description.append(rawLine)
            }
        }
        flush()
        return (description.joined(separator: "\n"), tags)
    }

    // MARK: - Inline and block conversion

    /// A tag's `name description`: the name in code, the description converted.
    private static func entry(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first else { return "" }
        let rest = parts.count > 1 ? inline(String(parts[1])) : ""
        let code = "`\(name.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))`"
        return rest.isEmpty ? code : "\(code) — \(rest)"
    }

    private static func reference(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<") || trimmed.hasPrefix("\"") { return inline(trimmed) }
        return "`\(linkTarget(trimmed))`"
    }

    private static let listMarker = "\u{E002}"

    /// The description as Markdown: paragraphs, lists and `<pre>` blocks kept.
    private static func blocks(_ description: String) -> String {
        var protected: [String] = []
        var text = description
        // Preformatted blocks become fenced code, set aside so nothing else touches them. A
        // `{@code ...}` inside is verbatim (it may hold `<String>`); otherwise real HTML is stripped.
        text = replacing(#"(?is)<pre[^>]*>\s*(?:<code[^>]*>)?(.*?)(?:</code>)?\s*</pre>"#, in: text) { groups in
            var body = groups[1]
            if let literal = firstMatch(#"(?s)\{@(?:code|literal)\s+(.*)\}"#, in: body) {
                body = literal
            } else {
                body = decodeEntities(stripTags(body, keepingNewlines: true))
            }
            protected.append("```java\n\(body.trimmingCharacters(in: .newlines))\n```")
            return "\n\n\(placeholder(protected.count - 1))\n\n"
        }
        text = inline(text, protecting: &protected)
        text = replacing(#"(?i)<\s*p\s*/?>"#, in: text) { _ in "\n\n" }
        text = replacing(#"(?i)<\s*/p\s*>"#, in: text) { _ in "" }
        text = replacing(#"(?i)<\s*br\s*/?>"#, in: text) { _ in "  \n" }
        text = replacing(#"(?i)<\s*li[^>]*>"#, in: text) { _ in "\n\(listMarker)" }
        text = replacing(#"(?i)<\s*/?(ul|ol)[^>]*>"#, in: text) { _ in "\n\n" }
        text = replacing(#"(?i)<\s*h[1-6][^>]*>"#, in: text) { _ in "\n\n**" }
        text = replacing(#"(?i)<\s*/h[1-6]\s*>"#, in: text) { _ in "**\n\n" }
        text = stripTags(text, keepingNewlines: true)
        text = decodeEntities(text)
        return restore(collapse(text), from: protected)
    }

    /// Joins the source's line wrapping into paragraphs, and consecutive list items into a list.
    private static func collapse(_ text: String) -> String {
        var blocks: [String] = []
        var lines: [String] = []
        var isList = false
        // A blank line inside a list only ends it if something other than an item follows.
        var pendingBreak = false
        func flush() {
            if !lines.isEmpty { blocks.append(lines.joined(separator: isList ? "\n" : " ")) }
            lines = []
            isList = false
            pendingBreak = false
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if isList { pendingBreak = true } else { flush() }
            } else if line.hasPrefix(listMarker) {
                if !isList { flush() }
                isList = true
                pendingBreak = false
                lines.append("- " + line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if isList, !pendingBreak, !lines.isEmpty {
                lines[lines.count - 1] += " " + line
            } else {
                if isList { flush() }
                lines.append(line)
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    /// Inline markup only, on one line: for a tag's text.
    private static func inline(_ text: String) -> String {
        var protected: [String] = []
        var result = inline(text, protecting: &protected)
        result = stripTags(result, keepingNewlines: false)
        result = decodeEntities(result)
        result = restore(result, from: protected)
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func inline(_ text: String, protecting protected: inout [String]) -> String {
        var result = text
        // {@code x} and {@literal x}: code, verbatim.
        result = replacing(#"\{@(?:code|literal)\s+((?:[^{}]|\{[^{}]*\})*)\}"#, in: result) { groups in
            protected.append("`\(groups[1].trimmingCharacters(in: .whitespaces))`")
            return placeholder(protected.count - 1)
        }
        // {@link Target label} and {@linkplain ...}: the label, or the target, in code.
        result = replacing(#"\{@(?:link|linkplain)\s+([^\s}]+)(?:\s+([^}]*))?\}"#, in: result) { groups in
            let label = groups.count > 2 ? groups[2].trimmingCharacters(in: .whitespaces) : ""
            protected.append("`\(label.isEmpty ? linkTarget(groups[1]) : label)`")
            return placeholder(protected.count - 1)
        }
        result = replacing(#"\{@value(?:\s+[^}]*)?\}"#, in: result) { _ in "" }
        result = replacing(#"\{@\w+\s*([^}]*)\}"#, in: result) { groups in groups[1] }
        // <code>, <tt>, <b>, <i>: their Markdown equivalents.
        result = replacing(#"(?is)<\s*(?:code|tt)\s*>(.*?)<\s*/\s*(?:code|tt)\s*>"#, in: result) { groups in
            protected.append("`\(decodeEntities(stripTags(groups[1], keepingNewlines: false)))`")
            return placeholder(protected.count - 1)
        }
        result = replacing(#"(?is)<\s*(?:b|strong)\s*>(.*?)<\s*/\s*(?:b|strong)\s*>"#, in: result) { "**\($0[1])**" }
        result = replacing(#"(?is)<\s*(?:i|em)\s*>(.*?)<\s*/\s*(?:i|em)\s*>"#, in: result) { "*\($0[1])*" }
        return result
    }

    /// `java.util.List#size()` -> `java.util.List.size()`, `#size()` -> `size()`.
    private static func linkTarget(_ target: String) -> String {
        target.hasPrefix("#") ? String(target.dropFirst()) : target.replacingOccurrences(of: "#", with: ".")
    }

    // MARK: - Helpers

    private static func placeholder(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

    private static func restore(_ text: String, from protected: [String]) -> String {
        replacing("\u{E000}(\\d+)\u{E001}", in: text) { groups in
            Int(groups[1]).flatMap { protected.indices.contains($0) ? protected[$0] : nil } ?? ""
        }
    }

    private static func stripTags(_ text: String, keepingNewlines: Bool) -> String {
        let stripped = replacing(#"</?[A-Za-z][^>]*>"#, in: text) { _ in "" }
        return keepingNewlines ? stripped : stripped.replacingOccurrences(of: "\n", with: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&nbsp;", " "), ("&#64;", "@"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    /// Regex replacement where the closure gets every capture group (index 0 is the whole match).
    private static func replacing(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
