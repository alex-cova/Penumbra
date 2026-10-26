import Foundation

/// Case and identifier-style conversion. The identifier styles work line by line, so a selection of
/// several names converts each one and keeps its indentation.
enum IDECaseText {
    enum Style {
        case camel, pascal, snake, kebab, screamingSnake
    }

    static func uppercase(_ text: String) -> String { text.uppercased() }
    static func lowercase(_ text: String) -> String { text.lowercased() }
    static func titleCase(_ text: String) -> String { text.capitalized }

    static func convert(_ text: String, to style: Style) -> String {
        text.components(separatedBy: "\n").map { convertLine($0, to: style) }.joined(separator: "\n")
    }

    private static func convertLine(_ line: String, to style: Style) -> String {
        let leading = String(line.prefix { $0.isWhitespace })
        let trailing = String(String(line.reversed().prefix { $0.isWhitespace || $0.isNewline }).reversed())
        let words = words(in: line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !words.isEmpty else { return line }
        let body: String
        switch style {
        case .camel:
            body = words.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : capitalize($0.element) }.joined()
        case .pascal:
            body = words.map(capitalize).joined()
        case .snake:
            body = words.map { $0.lowercased() }.joined(separator: "_")
        case .kebab:
            body = words.map { $0.lowercased() }.joined(separator: "-")
        case .screamingSnake:
            body = words.map { $0.uppercased() }.joined(separator: "_")
        }
        return leading + body + trailing
    }

    private static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    /// Splits on spaces, `_`, `-` and `.`, and at camel humps. An acronym stays together:
    /// `HTTPServerURL` is `HTTP`, `Server`, `URL`. Digits stay with the word before them.
    static func words(in text: String) -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isWhitespace || character == "_" || character == "-" || character == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let previous = current.last, character.isUppercase {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
