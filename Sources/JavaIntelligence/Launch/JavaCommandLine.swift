import Foundation

/// Splitting what the user typed into a run configuration's argument fields.
public enum JavaCommandLine {
    /// Splits `text` into arguments the way a shell would, without running one: whitespace separates,
    /// single quotes keep everything inside literally, double quotes keep whitespace and let `\"` and
    /// `\\` through, and a backslash outside quotes escapes the next character. An unfinished quote
    /// ends at the end of the text. `"two words"` is one argument; `""` is an empty one.
    public static func split(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\" {
                    guard let next = iterator.next() else {
                        current.append(character)
                        break
                    }
                    if next == "\"" || next == "\\" {
                        current.append(next)
                    } else {
                        current.append(character)
                        current.append(next)
                    }
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasToken = true
            case "\\":
                hasToken = true
                if let next = iterator.next() { current.append(next) } else { current.append(character) }
            case _ where character.isWhitespace:
                if hasToken {
                    arguments.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { arguments.append(current) }
        return arguments
    }

    /// One line of a JDK `@argfile`: `value` in double quotes with `\` and `"` escaped, which is how
    /// the launcher reads a path with spaces or backslashes.
    static func argFileQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
