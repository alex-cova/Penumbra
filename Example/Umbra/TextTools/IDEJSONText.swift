import Foundation

/// Formats and minifies JSON by re-flowing the characters as written, instead of serializing
/// again: `JSONSerialization` would sort keys and rewrite numbers, which is wrong when editing.
/// Key order, number spelling and string escapes are kept exactly.
enum IDEJSONText {
    /// Pretty-prints `text`. Lines after the first start with `baseIndent`, so JSON inside an
    /// indented block stays aligned. `nil` when the text is not valid JSON.
    static func format(_ text: String, indentUnit: String = "  ", baseIndent: String = "") -> String? {
        reflow(text, newline: { depth in "\n" + baseIndent + String(repeating: indentUnit, count: depth) }, colon: ": ")
    }

    static func minify(_ text: String) -> String? {
        reflow(text, newline: { _ in "" }, colon: ":")
    }

    private static func reflow(_ text: String, newline: (Int) -> String, colon: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed)) != nil
        else { return nil }
        let leading = String(text.prefix { $0.isWhitespace || $0.isNewline })
        let trailing = String(String(text.reversed().prefix { $0.isWhitespace || $0.isNewline }).reversed())

        let scalars = Array(trimmed.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var index = 0
        func emit(_ string: String) { out.append(contentsOf: string.unicodeScalars) }
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(scalar) }
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                // A string is copied verbatim, up to its closing quote.
                out.append(scalar)
                index += 1
                while index < scalars.count {
                    let inner = scalars[index]
                    out.append(inner)
                    index += 1
                    if inner == "\\", index < scalars.count {
                        out.append(scalars[index])
                        index += 1
                    } else if inner == "\"" {
                        break
                    }
                }
                continue
            case "{", "[":
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                var next = index + 1
                while next < scalars.count, isSpace(scalars[next]) { next += 1 }
                if next < scalars.count, scalars[next] == close {
                    out.append(scalar)
                    out.append(close)
                    index = next + 1
                    continue
                }
                out.append(scalar)
                depth += 1
                emit(newline(depth))
            case "}", "]":
                depth -= 1
                emit(newline(depth))
                out.append(scalar)
            case ",":
                out.append(scalar)
                emit(newline(depth))
            case ":":
                emit(colon)
            default:
                if !isSpace(scalar) { out.append(scalar) }
            }
            index += 1
        }
        return leading + String(out) + trailing
    }
}
