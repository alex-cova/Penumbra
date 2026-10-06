import Foundation

/// Hexadecimal encoding of the UTF-8 bytes of editor text.
enum IDEHexText {
    /// Lowercase, no separators: `hi` becomes `6869`.
    static func encode(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// Ignores whitespace and `:` separators and a leading `0x`. `nil` for an odd number of digits,
    /// a non-hex character or bytes that are not UTF-8.
    static func decode(_ text: String) -> String? {
        var digits = String(text.filter { !$0.isWhitespace && $0 != ":" })
        if digits.lowercased().hasPrefix("0x") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(data: Data(bytes), encoding: .utf8)
    }
}
