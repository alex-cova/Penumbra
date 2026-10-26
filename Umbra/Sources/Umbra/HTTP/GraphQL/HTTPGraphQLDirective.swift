import Foundation

/// `###@scheme:<url>`: the GraphQL schema that completion in the requests below it reads. The line
/// is a request separator, so it also ends the request above it. The URL is an SDL file or a GraphQL
/// endpoint, and may use `{{variables}}`.
///
/// A directive applies from its line to the next `###@scheme:` line, so one at the top of a file
/// covers every request in it.
struct HTTPGraphQLDirective: Equatable, Sendable {
    /// The URL as written, templates unexpanded.
    let url: String
    /// UTF-16 range of `@scheme`.
    let keywordRange: Range<Int>
    /// UTF-16 range of the URL.
    let urlRange: Range<Int>
    /// UTF-16 range of the whole line, without its line break.
    let lineRange: Range<Int>

    private static let keyword = Array("@scheme".utf16)

    /// The keyword and URL ranges when `line` of `units` is a directive.
    static func parse(units: [UInt16], line: Range<Int>) -> (keyword: Range<Int>, url: Range<Int>)? {
        var index = line.lowerBound
        func skipBlanks() {
            while index < line.upperBound, units[index] == 0x20 || units[index] == 0x09 {
                index += 1
            }
        }
        skipBlanks()
        var hashes = 0
        while index < line.upperBound, units[index] == 0x23 {
            hashes += 1
            index += 1
        }
        guard hashes >= 3 else {
            return nil
        }
        skipBlanks()
        let keywordStart = index
        guard index + keyword.count <= line.upperBound,
              Array(units[index..<(index + keyword.count)]) == keyword else {
            return nil
        }
        index += keyword.count
        let keywordEnd = index
        skipBlanks()
        guard index < line.upperBound, units[index] == 0x3A else {
            return nil
        }
        index += 1
        skipBlanks()
        let urlStart = index
        while index < line.upperBound, units[index] != 0x20, units[index] != 0x09 {
            index += 1
        }
        guard index > urlStart else {
            return nil
        }
        return (keywordStart..<keywordEnd, urlStart..<index)
    }

    /// Every directive in `text`, in order.
    static func directives(in text: String) -> [HTTPGraphQLDirective] {
        let ns = text as NSString
        var result: [HTTPGraphQLDirective] = []
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            if let directive = directive(onLine: lineRange, in: ns) {
                result.append(directive)
            }
            location = lineRange.location + max(lineRange.length, 1)
        }
        return result
    }

    /// The directive in effect at `caretUTF16`: the nearest one on the caret's line or above it.
    static func directive(in text: String, caretUTF16: Int) -> HTTPGraphQLDirective? {
        let ns = text as NSString
        var location = min(max(caretUTF16, 0), ns.length)
        while true {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            if let directive = directive(onLine: lineRange, in: ns) {
                return directive
            }
            guard lineRange.location > 0 else {
                return nil
            }
            location = lineRange.location - 1
        }
    }

    private static func directive(onLine lineRange: NSRange, in ns: NSString) -> HTTPGraphQLDirective? {
        // Cheap reject before copying: every directive has a `#`.
        let line = ns.substring(with: lineRange)
        guard line.utf8.contains(0x23) else {
            return nil
        }
        var units = Array(line.utf16)
        while let last = units.last, last == 0x0A || last == 0x0D {
            units.removeLast()
        }
        guard let parts = parse(units: units, line: 0..<units.count) else {
            return nil
        }
        let base = lineRange.location
        return HTTPGraphQLDirective(
            url: String(decoding: units[parts.url], as: UTF16.self),
            keywordRange: (parts.keyword.lowerBound + base)..<(parts.keyword.upperBound + base),
            urlRange: (parts.url.lowerBound + base)..<(parts.url.upperBound + base),
            lineRange: base..<(base + units.count)
        )
    }
}
