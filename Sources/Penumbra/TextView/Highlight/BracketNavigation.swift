import Foundation

/// Finds where "Move Caret to Matching Brace" (⌃M) should put a caret.
///
/// The scan is text-based over a bounded window around the caret, like ``BracketMatchingController``,
/// so its cost never depends on document size: it does not skip brackets inside strings or
/// comments.
enum BracketNavigation {
    /// Bracket kinds that navigate. Auto-pair characters such as quotes are deliberately absent.
    private static let pairs: [(open: unichar, close: unichar)] = [
        (0x28, 0x29), // ( )
        (0x5B, 0x5D), // [ ]
        (0x7B, 0x7D)  // { }
    ]

    /// UTF-16 units read on each side of the caret.
    static let searchLimit = 4096

    /// The caret location to move to from `caret`, or nil when no bracket is near enough.
    ///
    /// - A bracket touching the caret jumps to its partner, on the same side: caret right after a
    ///   bracket lands right after its partner, caret right before one lands right before its
    ///   partner. Pressing again therefore returns to where it started.
    /// - Otherwise the caret moves just after the innermost enclosing opening bracket.
    /// - The bracket before the caret wins over the one after it.
    static func target(from caret: Int, in text: NSString, windowStart: Int) -> Int? {
        let c = caret - windowStart
        guard c >= 0, c <= text.length else {
            return nil
        }
        if c > 0, let target = jumpFromBracket(atIndex: c - 1, in: text, landing: .after) {
            return windowStart + target
        }
        if c < text.length, let target = jumpFromBracket(atIndex: c, in: text, landing: .before) {
            return windowStart + target
        }
        if let open = enclosingOpenBracket(before: c, in: text) {
            return windowStart + open + 1
        }
        return nil
    }

    /// Reads a window around `caret` from `substring` and returns ``target(from:in:windowStart:)``.
    /// `substring` returns the text of a UTF-16 range, or nil when the range is invalid.
    static func target(from caret: Int, documentLength: Int, substring: (NSRange) -> String?) -> Int? {
        let start = max(0, caret - searchLimit)
        let end = min(documentLength, caret + searchLimit)
        guard end >= start, let window = substring(NSRange(location: start, length: end - start)) else {
            return nil
        }
        return target(from: caret, in: window as NSString, windowStart: start)
    }

    private enum Landing {
        case before, after
    }

    private static func jumpFromBracket(atIndex index: Int, in text: NSString, landing: Landing) -> Int? {
        let unit = text.character(at: index)
        for pair in pairs {
            if unit == pair.open {
                guard let partner = partnerIndex(from: index + 1, open: pair.open, close: pair.close,
                                                 in: text, forward: true) else {
                    return nil
                }
                return landing == .after ? partner + 1 : partner
            }
            if unit == pair.close {
                guard let partner = partnerIndex(from: index - 1, open: pair.open, close: pair.close,
                                                 in: text, forward: false) else {
                    return nil
                }
                return landing == .after ? partner + 1 : partner
            }
        }
        return nil
    }

    /// The index of the bracket that balances the one just before `start` (forward) or just after
    /// it (backward), counting only brackets of the same kind.
    private static func partnerIndex(from start: Int, open: unichar, close: unichar,
                                     in text: NSString, forward: Bool) -> Int? {
        var depth = 0
        var index = start
        while index >= 0, index < text.length {
            let unit = text.character(at: index)
            let opensDepth = forward ? open : close
            let closesDepth = forward ? close : open
            if unit == opensDepth {
                depth += 1
            } else if unit == closesDepth {
                if depth == 0 {
                    return index
                }
                depth -= 1
            }
            index += forward ? 1 : -1
        }
        return nil
    }

    /// The innermost opening bracket that encloses `location`, scanning backward and skipping
    /// balanced pairs of every kind.
    private static func enclosingOpenBracket(before location: Int, in text: NSString) -> Int? {
        var depths = [Int](repeating: 0, count: pairs.count)
        var index = location - 1
        while index >= 0 {
            let unit = text.character(at: index)
            for (kind, pair) in pairs.enumerated() {
                if unit == pair.close {
                    depths[kind] += 1
                } else if unit == pair.open {
                    if depths[kind] == 0 {
                        return index
                    }
                    depths[kind] -= 1
                }
            }
            index -= 1
        }
        return nil
    }
}
