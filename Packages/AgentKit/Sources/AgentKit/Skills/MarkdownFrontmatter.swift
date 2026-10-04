import Foundation

/// The values a skill or command file's header can hold: text, or a list of text.
public enum FrontmatterValue: Sendable, Equatable {
    case text(String)
    case list([String])

    /// The value as one string; a list is joined with commas.
    public var string: String {
        switch self {
        case .text(let text): text
        case .list(let items): items.joined(separator: ", ")
        }
    }

    /// The value as a list: a comma-separated text is split.
    public var items: [String] {
        switch self {
        case .list(let items): items
        case .text(let text): text.isEmpty ? [] : text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}

public struct MarkdownDocument: Sendable, Equatable {
    /// Keys are lowercased.
    public var metadata: [String: FrontmatterValue]
    public var body: String

    public func text(_ key: String) -> String? {
        guard let value = metadata[key], !value.string.isEmpty else { return nil }
        return value.string
    }

    public func list(_ key: String) -> [String] { metadata[key]?.items ?? [] }
}

/// The small part of YAML that skill and command files use: `key: value` lines between two `---`
/// lines, with quoted text, `[a, b]` lists, `- item` lists under a key, and `|` or `>` blocks. A file
/// with no header, or one that never closes, is all body.
public enum MarkdownFrontmatter {
    public static func parse(_ source: String) -> MarkdownDocument {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return MarkdownDocument(metadata: [:], body: text) }

        let metadata = parseHeader(Array(lines[1..<close]))
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownDocument(metadata: metadata, body: body)
    }

    private static func parseHeader(_ lines: [String]) -> [String: FrontmatterValue] {
        var result: [String: FrontmatterValue] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            // Indented lines that follow belong to this key.
            var block: [String] = []
            while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(lines[index])
                index += 1
            }
            while block.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { block.removeLast() }

            if rest == "|" || rest == ">" || rest == "|-" || rest == ">-" {
                let pieces = block.map { $0.trimmingCharacters(in: .whitespaces) }
                result[key] = .text(pieces.joined(separator: rest.hasPrefix("|") ? "\n" : " "))
            } else if rest.isEmpty {
                let items = block.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("-") }
                    .map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                result[key] = items.isEmpty ? .text("") : .list(items)
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                let inner = rest.dropFirst().dropLast()
                result[key] = .list(splitList(String(inner)).map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
            } else {
                result[key] = .text(unquote(rest))
            }
        }
        return result
    }

    /// Splits on commas that are not inside quotes or parentheses, so `Bash(git add:*, x)` stays whole.
    private static func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "(" {
                depth += 1
                current.append(character)
            } else if character == ")" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == ",", depth == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }
}
