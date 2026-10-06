import Foundation

/// Line-by-line conversions: Unix time to a date and back, and number bases. Blank lines and each
/// line's surrounding whitespace are kept, so a column of values converts as a column. A line that
/// cannot be converted makes the whole conversion `nil`.
enum IDEConversionText {
    // MARK: Unix time

    /// Unix time to ISO 8601 in UTC. A value of 12 or more digits is read as milliseconds:
    /// `1700000000` and `1700000000000` both give `2023-11-14T22:13:20Z`.
    static func epochToDate(_ text: String) -> String? {
        convertLines(text) { value in
            guard let number = Int64(value) else { return nil }
            let milliseconds = value.drop { $0 == "-" || $0 == "+" }.count >= 12
            let seconds = milliseconds ? floorDivide(number, 1000) : number
            let fraction = milliseconds ? number - seconds * 1000 : 0
            let formatter = ISO8601DateFormatter()
            let base = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
            guard fraction != 0 else { return base }
            return String(base.dropLast()) + String(format: ".%03dZ", Int(fraction))
        }
    }

    /// ISO 8601 (`Z` or an offset, optional fraction), a bare date, or `yyyy-MM-dd HH:mm:ss` to Unix
    /// seconds. Times without a zone are UTC; a fraction is dropped.
    static func dateToEpoch(_ text: String) -> String? {
        convertLines(text) { value in
            parseDate(value).map { String(Int64($0.timeIntervalSince1970.rounded(.down))) }
        }
    }

    /// `ISO8601DateFormatter` accepts a valid prefix and ignores the rest (`2023-11-14 22:13:20`
    /// would read as midnight), so every format is checked against the whole value.
    private static let isoShape = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)

    private static func parseDate(_ value: String) -> Date? {
        let whole = NSRange(location: 0, length: (value as NSString).length)
        if isoShape.firstMatch(in: value, range: whole) != nil {
            for options in [
                ISO8601DateFormatter.Options.withInternetDateTime,
                [.withInternetDateTime, .withFractionalSeconds]
            ] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: value) { return date }
            }
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            // A round trip proves the format consumed everything and the date is real (no 2023-02-31).
            if let date = formatter.date(from: value), formatter.string(from: date) == value { return date }
        }
        return nil
    }

    private static func floorDivide(_ number: Int64, _ divisor: Int64) -> Int64 {
        let quotient = number / divisor
        return number % divisor != 0 && number < 0 ? quotient - 1 : quotient
    }

    // MARK: Number bases

    static func toHex(_ text: String) -> String? {
        convertLines(text) { value in parseNumber(value).map { $0.sign + "0x" + String($0.magnitude, radix: 16) } }
    }

    static func toBinary(_ text: String) -> String? {
        convertLines(text) { value in parseNumber(value).map { $0.sign + "0b" + String($0.magnitude, radix: 2) } }
    }

    static func toDecimal(_ text: String) -> String? {
        convertLines(text) { value in parseNumber(value).map { $0.sign + String($0.magnitude) } }
    }

    /// A decimal, `0x` hex, `0b` binary or `0o` octal number, with an optional sign, Java-style `_`
    /// separators and a trailing `L`.
    private static func parseNumber(_ value: String) -> (sign: String, magnitude: UInt64)? {
        var digits = value.replacingOccurrences(of: "_", with: "")
        if let last = digits.last, last == "l" || last == "L" { digits.removeLast() }
        var sign = ""
        if let first = digits.first, first == "-" || first == "+" {
            sign = first == "-" ? "-" : ""
            digits.removeFirst()
        }
        var radix = 10
        let lowered = digits.lowercased()
        for (prefix, base) in [("0x", 16), ("0b", 2), ("0o", 8)] where lowered.hasPrefix(prefix) {
            radix = base
            digits = String(digits.dropFirst(2))
        }
        guard !digits.isEmpty, let magnitude = UInt64(digits, radix: radix) else { return nil }
        return (sign, magnitude)
    }

    // MARK: Lines

    private static func convertLines(_ text: String, _ convert: (String) -> String?) -> String? {
        var converted = 0
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                lines.append(line)
                continue
            }
            guard let result = convert(value) else { return nil }
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let trailing = String(line.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
            lines.append(leading + result + trailing)
            converted += 1
        }
        return converted > 0 ? lines.joined(separator: "\n") : nil
    }
}
