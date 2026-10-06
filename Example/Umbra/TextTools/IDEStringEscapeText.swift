import Foundation

/// Escapes text for a Java or JSON string literal, and reverses it.
enum IDEStringEscapeText {
    /// `\\`, `\"`, `\n`, `\r`, `\t`, `\b`, `\f`, and `\u00XX` for other control characters. A single
    /// quote is left alone, as in a Java string or JSON.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Reads the escapes `escape` writes, plus `\'`, `\/` and `\uXXXX` (a surrogate pair written as
    /// two escapes becomes one character). `nil` for an unknown or unfinished escape.
    static func unescape(_ text: String) -> String? {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            guard unit == 0x5C else {
                out.append(unit)
                continue
            }
            guard index < units.count else { return nil }
            let code = units[index]
            index += 1
            switch Unicode.Scalar(code).map(Character.init) {
            case "\\": out.append(0x5C)
            case "\"": out.append(0x22)
            case "'": out.append(0x27)
            case "/": out.append(0x2F)
            case "n": out.append(0x0A)
            case "r": out.append(0x0D)
            case "t": out.append(0x09)
            case "b": out.append(0x08)
            case "f": out.append(0x0C)
            case "u":
                guard let value = IDEUnicodeEscapeText.hexUnit(in: units, at: index) else { return nil }
                out.append(value)
                index += 4
            default: return nil
            }
        }
        return String(decoding: out, as: UTF16.self)
    }
}
