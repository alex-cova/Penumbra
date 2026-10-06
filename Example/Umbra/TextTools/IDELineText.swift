import Foundation

/// Whole-line operations on a selection. Each keeps the text's line ending (`\n` or `\r\n`) and a
/// final line break when the selection ends with one, so a selection of whole lines stays whole.
enum IDELineText {
    static func sortAscending(_ text: String) -> String {
        sorted(text, descending: false)
    }

    static func sortDescending(_ text: String) -> String {
        sorted(text, descending: true)
    }

    /// Natural, case-insensitive order: `file2` before `file10`, `a` next to `A`.
    private static func sorted(_ text: String, descending: Bool) -> String {
        transform(text) { lines in
            let ordered = lines.enumerated().sorted { lhs, rhs in
                let result = lhs.element.localizedStandardCompare(rhs.element)
                if result == .orderedSame { return lhs.offset < rhs.offset }
                return descending ? result == .orderedDescending : result == .orderedAscending
            }
            return ordered.map(\.element)
        }
    }

    /// Keeps the first of every group of identical lines, in the original order.
    static func removeDuplicates(_ text: String) -> String {
        transform(text) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    static func reverse(_ text: String) -> String {
        transform(text) { Array($0.reversed()) }
    }

    /// Removes lines that are empty or only whitespace.
    static func removeBlankLines(_ text: String) -> String {
        transform(text) { lines in
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    static func trimTrailingWhitespace(_ text: String) -> String {
        transform(text) { lines in
            lines.map { line in
                var end = line.endIndex
                while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
                    end = line.index(before: end)
                }
                return String(line[..<end])
            }
        }
    }

    private static func transform(_ text: String, _ operation: ([String]) -> [String]) -> String {
        let separator = text.contains("\r\n") ? "\r\n" : "\n"
        let endsWithBreak = text.hasSuffix(separator)
        let body = endsWithBreak ? String(text.dropLast(separator.count)) : text
        let result = operation(body.components(separatedBy: separator)).joined(separator: separator)
        return endsWithBreak && !result.isEmpty ? result + separator : result
    }
}
