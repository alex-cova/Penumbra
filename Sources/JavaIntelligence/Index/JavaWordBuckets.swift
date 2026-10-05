import Foundation

/// Word-start buckets shared by the class-name table and the member table.
///
/// ``CompletionMatcher`` only anchors a query at index 0 or at a word start, so a name is filed
/// under the lowercased first byte of each of those positions. A bucket holds indexes into the
/// owning table. The query's key is its first UTF-8 byte with an ASCII letter lowered — the same
/// rule ``CompletionMatcher`` uses — so a non-ASCII first letter is not folded by `String.lowercased()`.
enum JavaWordBuckets {
    static let count = 256

    /// `nil` when `query` is empty.
    static func bucketKey(of query: String) -> UInt8? {
        guard let byte = query.utf8.first else { return nil }
        if byte >= 65 && byte <= 90 { return byte &+ 32 }
        return byte
    }

    /// Calls `body` with the lowercased first byte of each word of `name`, once per distinct byte.
    /// A word starts at the first byte, at an uppercase letter, after a non-letter, and at a digit
    /// that follows a non-digit (`6` in `Base64`, `3` in `S3Client`).
    static func wordInitials(of name: String, _ body: (UInt8) -> Void) {
        var seen: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        var previous: UInt8 = 0
        var offset = 0
        for byte in name.utf8 {
            let isUpper = byte >= 65 && byte <= 90
            let isDigit = byte >= 48 && byte <= 57
            let previousIsDigit = previous >= 48 && previous <= 57
            let previousIsLetter = (previous >= 65 && previous <= 90) || (previous >= 97 && previous <= 122)
            let digitAfterNonDigit = isDigit && offset > 0 && !previousIsDigit
            if offset == 0 || isUpper || !previousIsLetter || digitAfterNonDigit {
                let lower = isUpper ? byte &+ 32 : byte
                if insert(lower, into: &seen) { body(lower) }
            }
            previous = byte
            offset += 1
        }
    }

    /// Every byte of `query` occurs in `name` in order. All match tiers imply it.
    static func isSubsequence(_ query: [UInt8], of name: String) -> Bool {
        var index = 0
        for byte in name.utf8 where index < query.count && byte == query[index] { index += 1 }
        return index == query.count
    }

    private static func insert(_ byte: UInt8, into set: inout (UInt64, UInt64, UInt64, UInt64)) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: if set.0 & bit != 0 { return false }; set.0 |= bit
        case 1: if set.1 & bit != 0 { return false }; set.1 |= bit
        case 2: if set.2 & bit != 0 { return false }; set.2 |= bit
        default: if set.3 & bit != 0 { return false }; set.3 |= bit
        }
        return true
    }
}
