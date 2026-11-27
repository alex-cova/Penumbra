import Foundation

/// An IEEE 754-2008 decimal128 in MongoDB's BID encoding, kept as its sixteen bytes and
/// converted to and from text exactly, with no `Double` and no `Foundation.Decimal` (which holds
/// fewer digits and a smaller exponent range).
public struct Decimal128Value: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The value as BSON stores it: little-endian, low 64 bits first.
    public let low: UInt64
    public let high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        var low: UInt64 = 0, high: UInt64 = 0
        for index in 0..<8 {
            low |= UInt64(bytes[index]) << (8 * UInt64(index))
            high |= UInt64(bytes[8 + index]) << (8 * UInt64(index))
        }
        self.init(low: low, high: high)
    }

    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: low >> (8 * UInt64($0))) }
            + (0..<8).map { UInt8(truncatingIfNeeded: high >> (8 * UInt64($0))) }
    }

    static let exponentBias = 6176
    static let maxExponent = 6111
    static let minExponent = -6176
    static let maxDigits = 34

    public var isNegative: Bool { high >> 63 == 1 }
    public var isNaN: Bool { (high >> 58) & 0x1F == 0x1F }
    public var isInfinity: Bool { (high >> 58) & 0x1F == 0x1E }

    // MARK: Decoding to text

    public var description: String {
        let sign = isNegative ? "-" : ""
        if isNaN { return "NaN" }
        if isInfinity { return sign + "Infinity" }

        let exponent: Int
        var limbs: [UInt32]
        if (high >> 61) & 0b11 == 0b11 {
            // The "large significand" form: its significand is at least 2^113, beyond 34 digits,
            // so the value is zero (IEEE 754-2008, and the BSON decimal128 spec).
            exponent = Int((high >> 47) & 0x3FFF) - Self.exponentBias
            limbs = [0, 0, 0, 0]
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - Self.exponentBias
            let highBits = high & 0x1_FFFF_FFFF_FFFF  // 49 bits
            limbs = [UInt32(truncatingIfNeeded: low), UInt32(truncatingIfNeeded: low >> 32),
                     UInt32(truncatingIfNeeded: highBits), UInt32(truncatingIfNeeded: highBits >> 32)]
        }
        var digits = Self.decimalDigits(of: &limbs)
        // A significand above 10^34 - 1 is non-canonical and reads as zero.
        if digits.count > Self.maxDigits { digits = "0" }
        return sign + Self.format(digits: digits, exponent: exponent)
    }

    /// The decimal digits of a 128-bit integer given as four little-endian 32-bit limbs.
    private static func decimalDigits(of limbs: inout [UInt32]) -> String {
        var groups: [UInt32] = []  // base 10^9, least significant first
        while limbs.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let current = (remainder << 32) | UInt64(limbs[index])
                limbs[index] = UInt32(current / 1_000_000_000)
                remainder = current % 1_000_000_000
            }
            groups.append(UInt32(remainder))
        }
        guard let top = groups.last else { return "0" }
        var text = String(top)
        for group in groups.dropLast().reversed() {
            let part = String(group)
            text += String(repeating: "0", count: 9 - part.count) + part
        }
        return text
    }

    /// The decimal128 string conversion from the specification: plain notation when the exponent
    /// is not positive and the adjusted exponent is at least -6, otherwise scientific.
    private static func format(digits: String, exponent: Int) -> String {
        let adjusted = exponent + digits.count - 1
        if exponent <= 0, adjusted >= -6 {
            if exponent == 0 { return digits }
            let point = digits.count + exponent
            if point > 0 {
                let split = digits.index(digits.startIndex, offsetBy: point)
                return digits[..<split] + "." + digits[split...]
            }
            return "0." + String(repeating: "0", count: -point) + digits
        }
        var text = String(digits.first!)
        if digits.count > 1 { text += "." + digits.dropFirst() }
        text += "E" + (adjusted >= 0 ? "+" : "-") + String(abs(adjusted))
        return text
    }

    // MARK: Parsing from text

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalid(String)
        case tooManyDigits(String)
        case exponentOutOfRange(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let text): "\"\(text)\" is not a decimal number."
            case .tooManyDigits(let text): "\"\(text)\" has more than 34 significant digits, which Decimal128 cannot hold."
            case .exponentOutOfRange(let text): "\"\(text)\" has an exponent outside Decimal128's range."
            }
        }
    }

    public init(_ text: String) throws {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if rest.hasPrefix("-") { negative = true; rest = rest.dropFirst() } else if rest.hasPrefix("+") { rest = rest.dropFirst() }
        let signBit: UInt64 = negative ? 1 << 63 : 0
        switch rest.lowercased() {
        case "nan":
            self.init(low: 0, high: 0x7C00_0000_0000_0000)
            return
        case "inf", "infinity":
            self.init(low: 0, high: signBit | 0x7800_0000_0000_0000)
            return
        default:
            break
        }
        // digits [. digits] [e [+-] digits]
        var mantissa = rest
        var exponentPart = 0
        if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = rest[..<marker]
            guard let parsed = Int(rest[rest.index(after: marker)...].replacingOccurrences(of: "+", with: "")) else {
                throw ParseError.invalid(text)
            }
            exponentPart = parsed
        }
        var digits = ""
        var fractionDigits = 0
        var seenPoint = false
        for character in mantissa {
            if character == "." {
                guard !seenPoint else { throw ParseError.invalid(text) }
                seenPoint = true
            } else if character.isASCII, character.isNumber {
                digits.append(character)
                if seenPoint { fractionDigits += 1 }
            } else {
                throw ParseError.invalid(text)
            }
        }
        guard !digits.isEmpty else { throw ParseError.invalid(text) }
        // Leading zeros carry no information; trailing fraction zeros are kept (1.50 stays 1.50).
        var significant = Substring(digits)
        while significant.count > 1, significant.hasPrefix("0") { significant = significant.dropFirst() }
        var exponent = exponentPart - fractionDigits
        if significant.count > Self.maxDigits {
            // Excess digits are acceptable only if they are zeros that can move into the exponent.
            var trimmed = significant
            var removed = 0
            while trimmed.count > Self.maxDigits, trimmed.hasSuffix("0") { trimmed = trimmed.dropLast(); removed += 1 }
            guard trimmed.count <= Self.maxDigits else { throw ParseError.tooManyDigits(text) }
            significant = trimmed
            exponent += removed
        }
        guard exponent >= Self.minExponent, exponent <= Self.maxExponent else {
            throw ParseError.exponentOutOfRange(text)
        }
        var limbs: [UInt32] = [0, 0, 0, 0]
        for character in significant.utf8 {
            var carry = UInt64(character - 48)
            for index in 0..<4 {
                let value = UInt64(limbs[index]) * 10 + carry
                limbs[index] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
        }
        let low = UInt64(limbs[0]) | UInt64(limbs[1]) << 32
        let highBits = UInt64(limbs[2]) | UInt64(limbs[3]) << 32  // at most 113 - 64 = 49 bits
        let biased = UInt64(exponent + Self.exponentBias)
        self.init(low: low, high: signBit | (biased << 49) | highBits)
    }
}
