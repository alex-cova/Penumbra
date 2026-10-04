import Foundation

/// A transcript's Markdown, split into the blocks a view draws. Inline styling (bold, code, links)
/// stays in the text and is drawn by `AttributedString(markdown:)`; this only finds the blocks.
enum IDEAgentMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is `•` for a bullet, or the number as written (`1.`).
    case listItem(marker: String, indent: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule
    /// Cells of each row; the header separator row is dropped.
    case table(rows: [[String]])
}

enum IDEAgentMarkdown {
    static func parse(_ text: String) -> [IDEAgentMarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [IDEAgentMarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                flushQuote()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                index += 1  // the closing fence, or past the end
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = trimmed.dropFirst()
                if content.hasPrefix(" ") { content = content.dropFirst() }
                quote.append(String(content))
                index += 1
                continue
            }
            flushQuote()

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                flushParagraph()
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|"), row.hasSuffix("|"), row.count > 1 else { break }
                    if !isTableSeparator(row) { rows.append(cells(row)) }
                    index += 1
                }
                blocks.append(.table(rows: rows))
                continue
            } else {
                paragraph.append(line.trimmingCharacters(in: .newlines))
            }
            index += 1
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) { return fence }
        return nil
    }

    private static func heading(_ trimmed: String) -> IDEAgentMarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let characters = Set(trimmed.filter { $0 != " " })
        return trimmed.filter { $0 != " " }.count >= 3 && characters.count == 1 && ["-", "*", "_"].contains(characters.first!)
    }

    private static func listItem(_ line: String) -> IDEAgentMarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let rest = line.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .listItem(marker: "•", indent: indent, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, let punctuation = rest.dropFirst(digits.count).first, ".)".contains(punctuation),
           rest.dropFirst(digits.count + 1).first == " " {
            return .listItem(marker: "\(digits).", indent: indent, text: rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func isTableSeparator(_ row: String) -> Bool {
        let body = row.dropFirst().dropLast()
        return !body.isEmpty && body.allSatisfy { "-:| ".contains($0) } && body.contains("-")
    }

    private static func cells(_ row: String) -> [String] {
        row.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A table as aligned monospaced lines, which is how it is drawn.
    static func alignedTable(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) } }
        return rows.map { row in
            (0..<columns).map { index in
                let cell = index < row.count ? row[index] : ""
                return cell + String(repeating: " ", count: widths[index] - cell.count)
            }.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}
