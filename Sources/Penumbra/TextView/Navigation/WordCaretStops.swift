import Foundation

/// IntelliJ's word caret stops (`EditorActionUtil.isWordBoundary` / `isHumpBound`) over a
/// UTF-16 buffer, used by ⌥←/→, ⌥⇧←/→ and ⌥⌫/⌦.
///
/// Identifier runs (letters, digits, `_`, `$`) and punctuation runs are words; whitespace is
/// skipped. With camel humps on, `getHTTPResponse` stops at `get|HTTP|Response`, and `_`/`$`
/// separate humps. Forward movement stops at the next word end and backward movement at the
/// previous word start — the macOS defaults of IntelliJ's caret-stop options.
///
/// The functions only see `text`: both of its ends count as stops, so callers pass the line
/// (or a bounded window of it) and handle crossing line breaks themselves.
enum WordCaretStops {
    /// The first word end after `offset`, or `text.count`.
    static func nextStop(in text: [UInt16], from offset: Int, camelHumps: Bool) -> Int {
        var candidate = offset + 1
        while candidate < text.count {
            if isWordEnd(text, candidate, camelHumps: camelHumps) {
                return candidate
            }
            candidate += 1
        }
        return max(text.count, offset)
    }

    /// The first word start before `offset`, or `0`.
    static func previousStop(in text: [UInt16], from offset: Int, camelHumps: Bool) -> Int {
        var candidate = offset - 1
        while candidate > 0 {
            if isWordStart(text, candidate, camelHumps: camelHumps) {
                return candidate
            }
            candidate -= 1
        }
        return min(0, offset)
    }

    static func isWordStart(_ text: [UInt16], _ offset: Int, camelHumps: Bool) -> Bool {
        isWordBoundary(text, offset, camelHumps: camelHumps, isStart: true)
    }

    static func isWordEnd(_ text: [UInt16], _ offset: Int, camelHumps: Bool) -> Bool {
        isWordBoundary(text, offset, camelHumps: camelHumps, isStart: false)
    }

    private static func isWordBoundary(_ text: [UInt16], _ offset: Int, camelHumps: Bool, isStart: Bool) -> Bool {
        guard offset >= 0, offset <= text.count else {
            return false
        }
        let previous: UInt16? = offset > 0 ? text[offset - 1] : nil
        let current: UInt16? = offset < text.count ? text[offset] : nil
        let word = isStart ? current : previous
        let neighbor = isStart ? previous : current
        if isIdentifierPart(word) {
            if !isIdentifierPart(neighbor) {
                return true
            }
            if camelHumps, isHumpBound(text, offset, isStart: isStart) {
                return true
            }
        }
        return isPunctuation(word) && !isPunctuation(neighbor)
    }

    private static func isHumpBound(_ text: [UInt16], _ offset: Int, isStart: Bool) -> Bool {
        guard offset > 0, offset < text.count else {
            return false
        }
        let previous = text[offset - 1]
        let current = text[offset]
        let next: UInt16? = offset + 1 < text.count ? text[offset + 1] : nil
        let hump = isStart ? current : previous
        let neighbor = isStart ? previous : current
        return (isLowercaseOrDigit(previous) && isUppercase(current))
            || (neighbor == underscore && hump != underscore)
            || (neighbor == dollar && isLetterOrDigit(hump))
            || (isUppercase(previous) && isUppercase(current) && isLowercase(next))
    }

    // MARK: - Character classes

    private static let underscore: UInt16 = 0x5F
    private static let dollar: UInt16 = 0x24

    private static func isIdentifierPart(_ unit: UInt16?) -> Bool {
        guard let unit else {
            return false
        }
        if unit == underscore || unit == dollar {
            return true
        }
        // A surrogate half belongs to a supplementary character; treating it as a letter keeps
        // stops from ever landing between the two halves.
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
            return true
        }
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isWhitespace(_ unit: UInt16?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isPunctuation(_ unit: UInt16?) -> Bool {
        unit != nil && !isIdentifierPart(unit) && !isWhitespace(unit)
    }

    private static func isUppercase(_ unit: UInt16?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar.properties.isUppercase
    }

    private static func isLowercase(_ unit: UInt16?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar.properties.isLowercase
    }

    private static func isLowercaseOrDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar.properties.isLowercase || CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
