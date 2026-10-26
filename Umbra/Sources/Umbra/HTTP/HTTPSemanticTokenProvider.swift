import EditorIntelligence
import Foundation

/// Colors in `.http` files the grammar has no node for: `{{name}}` templates, which the grammar
/// keeps inside a body's one token, and the two halves of a `###@scheme:<url>` line, which it reads
/// as one value. One linear pass over the text, no parse.
struct HTTPSemanticTokenProvider: SemanticTokenProviding {
    func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
        HTTPSemanticTokens.highlights(in: source)
    }
}

enum HTTPSemanticTokens {
    static func highlights(in source: String) -> [SemanticHighlight] {
        let units = Array(source.utf16)
        var result: [SemanticHighlight] = []
        var lineStart = 0
        while lineStart <= units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != 0x0A, units[lineEnd] != 0x0D {
                lineEnd += 1
            }
            scan(units, lineStart..<lineEnd, into: &result)
            if Task.isCancelled {
                return result
            }
            if lineEnd >= units.count {
                break
            }
            // `\r\n` is one break.
            lineStart = lineEnd + (units[lineEnd] == 0x0D && lineEnd + 1 < units.count && units[lineEnd + 1] == 0x0A ? 2 : 1)
        }
        return result
    }

    private static func scan(_ units: [UInt16], _ line: Range<Int>, into result: inout [SemanticHighlight]) {
        var index = line.lowerBound
        while index < line.upperBound, units[index] == 0x20 || units[index] == 0x09 {
            index += 1
        }
        guard index < line.upperBound else {
            return
        }
        if let scheme = HTTPGraphQLDirective.parse(units: units, line: line) {
            result.append(SemanticHighlight(range: scheme.keyword, highlightName: "keyword"))
            result.append(SemanticHighlight(range: scheme.url, highlightName: "string.special.url"))
            // A template in the URL is still a template.
            scanTemplates(units, scheme.url, into: &result)
            return
        }
        // A comment line is a comment: its words are not variables.
        if units[index] == 0x23 || (units[index] == 0x2F && index + 1 < line.upperBound && units[index + 1] == 0x2F) {
            return
        }
        scanTemplates(units, line, into: &result)
    }

    /// `{{ name }}` with no brace or line break inside. An unclosed `{{` is left alone.
    private static func scanTemplates(_ units: [UInt16], _ range: Range<Int>, into result: inout [SemanticHighlight]) {
        var index = range.lowerBound
        while index + 1 < range.upperBound {
            guard units[index] == 0x7B, units[index + 1] == 0x7B else {
                index += 1
                continue
            }
            var close = index + 2
            while close + 1 < range.upperBound, !(units[close] == 0x7D && units[close + 1] == 0x7D) {
                if units[close] == 0x7B || units[close] == 0x7D {
                    break
                }
                close += 1
            }
            guard close + 1 < range.upperBound, units[close] == 0x7D, units[close + 1] == 0x7D else {
                index += 2
                continue
            }
            result.append(SemanticHighlight(range: index..<(index + 2), highlightName: "punctuation.bracket"))
            var nameStart = index + 2
            var nameEnd = close
            while nameStart < nameEnd, units[nameStart] == 0x20 || units[nameStart] == 0x09 {
                nameStart += 1
            }
            while nameEnd > nameStart, units[nameEnd - 1] == 0x20 || units[nameEnd - 1] == 0x09 {
                nameEnd -= 1
            }
            if nameStart < nameEnd {
                let isDynamic = units[nameStart] == 0x24
                result.append(SemanticHighlight(
                    range: nameStart..<nameEnd,
                    highlightName: isDynamic ? "function.builtin" : "variable"
                ))
            }
            result.append(SemanticHighlight(range: close..<(close + 2), highlightName: "punctuation.bracket"))
            index = close + 2
        }
    }
}
