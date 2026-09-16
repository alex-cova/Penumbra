import Foundation

/// A segment of markdown source split around fenced code blocks.
enum MarkdownSourceSegment: Sendable, Equatable {
    case prose(String)
    case fencedCode(language: String?, body: String)
}

enum MermaidFenceExtractor {
    private static let fencePattern = try! NSRegularExpression(
        pattern: #"^```[ \t]*([^\n`]*)\n([\s\S]*?)\n```[ \t]*(?:\n|$)"#,
        options: [.anchorsMatchLines]
    )

    /// Splits `source` into prose and fenced-code segments in document order.
    static func segments(in source: String) -> [MarkdownSourceSegment] {
        guard !source.isEmpty else { return [] }
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result: [MarkdownSourceSegment] = []
        var cursor = 0

        for match in fencePattern.matches(in: source, range: fullRange) {
            let matchRange = match.range
            if matchRange.location > cursor {
                let prose = ns.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
                if !prose.isEmpty {
                    result.append(.prose(prose))
                }
            }
            let language = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                : nil
            let body = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2))
                : ""
            result.append(.fencedCode(language: language?.isEmpty == true ? nil : language, body: body))
            cursor = matchRange.location + matchRange.length
        }

        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                result.append(.prose(tail))
            }
        }

        if result.isEmpty {
            result.append(.prose(source))
        }
        return result
    }

    static func isMermaidFence(_ language: String?) -> Bool {
        guard let language else { return false }
        let normalized = language.lowercased()
        return normalized == "mermaid" || normalized == "mmd"
    }
}
