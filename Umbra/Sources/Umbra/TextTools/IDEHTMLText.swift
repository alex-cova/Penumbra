import Foundation

/// HTML entity encoding of editor text.
enum IDEHTMLText {
    /// Escapes the five characters that matter in markup and attribute values. Other characters,
    /// non-ASCII included, stay as they are.
    static func encode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "euro": "€", "pound": "£", "yen": "¥"
    ]

    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);")

    /// Decodes named entities from a small table and numeric ones (`&#38;`, `&#x26;`). An entity it
    /// does not know is left as written.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let body = source.substring(with: match.range(at: 1))
            if let replacement = replacement(for: body) {
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return result as String
    }

    private static func replacement(for body: String) -> String? {
        guard body.hasPrefix("#") else { return named[body] }
        let digits = body.dropFirst()
        let value: UInt32?
        if let first = digits.first, first == "x" || first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits)
        }
        guard let value, let scalar = Unicode.Scalar(value), value != 0 else { return nil }
        return String(Character(scalar))
    }
}
