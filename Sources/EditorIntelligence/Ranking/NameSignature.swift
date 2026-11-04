import Foundation

/// A 64-bit summary of the characters a name contains: a lossless prefilter for
/// ``CompletionMatcher`` (F27).
///
/// Every match tier needs each query character to occur in the candidate, compared the way the
/// matcher compares (ASCII letters case-insensitively, everything else exactly). So when a query's
/// characters are not all present in a name's, the name cannot match, and finding that out is one
/// `AND` instead of the arrays and word-start scan `match` builds per candidate. A name that
/// passes still goes through the matcher, so results are exactly what they were: this only skips
/// names that could never have matched.
///
/// Letters and digits get a bit each; every other UTF-16 unit shares one of 28 bits by value, which
/// can only let a name through that should not pass, never hold one back.
public struct NameSignature: Sendable, Hashable {
    public let bits: UInt64

    public init(_ name: String) {
        var bits: UInt64 = 0
        for unit in name.utf16 { bits |= Self.bit(for: unit) }
        self.bits = bits
    }

    /// Whether a name with this signature could match `query`'s.
    @inline(__always)
    public func couldMatch(_ query: NameSignature) -> Bool {
        query.bits & ~bits == 0
    }

    @inline(__always)
    private static func bit(for unit: UInt16) -> UInt64 {
        let lowered = (65...90).contains(unit) ? unit + 32 : unit
        switch lowered {
        case 97...122: return 1 << UInt64(lowered - 97)
        case 48...57: return 1 << UInt64(26 + lowered - 48)
        default: return 1 << UInt64(36 + lowered % 28)
        }
    }
}
