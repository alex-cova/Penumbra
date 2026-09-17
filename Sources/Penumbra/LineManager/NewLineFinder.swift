import Foundation

enum NewLineFinder {
    static func rangeOfNextNewLine(in text: NSString, startingAt location: Int) -> NSRange? {
        let range = NSRange(location: location, length: 0)
        var end: Int = NSNotFound
        var contentsEnd: Int = NSNotFound
        text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: range)
        if end != NSNotFound && contentsEnd != NSNotFound && end != contentsEnd {
            return NSRange(location: contentsEnd, length: end - contentsEnd)
        } else {
            return nil
        }
    }

    static func startOfParagraph(before location: Int, in text: NSString) -> Int {
        if location <= 0 {
            return 0
        }
        let probe = min(location - 1, text.length - 1)
        guard probe >= 0 else {
            return 0
        }
        let unit = text.character(at: probe)
        if unit == 0x000A || unit == 0x000D || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
            return location
        }
        var start = 0
        text.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: probe, length: 0))
        return start
    }
}
