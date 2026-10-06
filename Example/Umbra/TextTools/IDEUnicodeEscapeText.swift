import Foundation

/// `\uXXXX` escapes for the non-ASCII characters of editor text, as Java source and JSON write them.
enum IDEUnicodeEscapeText {
    /// Every non-ASCII UTF-16 unit becomes `\uXXXX` (lowercase hex), so an emoji is a surrogate pair
    /// of two escapes. ASCII is untouched.
    static func escape(_ text: String) -> String {
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80, let scalar = Unicode.Scalar(unit) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }

    /// Replaces every well-formed `\uXXXX`; anything else, a malformed escape included, stays as
    /// written. Surrogate pairs written as two escapes become one character.
    static func unescape(_ text: String) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            if units[index] == 0x5C, index + 1 < units.count, units[index + 1] == 0x75,
               let value = hexUnit(in: units, at: index + 2) {
                out.append(value)
                index += 6
            } else {
                out.append(units[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The UTF-16 unit written by the four hex digits at `index`, or `nil`.
    static func hexUnit(in units: [UInt16], at index: Int) -> UInt16? {
        guard index + 4 <= units.count else { return nil }
        var value: UInt16 = 0
        for offset in 0 ..< 4 {
            guard let digit = Unicode.Scalar(units[index + offset]).flatMap({ Character($0).hexDigitValue }) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return value
    }
}
