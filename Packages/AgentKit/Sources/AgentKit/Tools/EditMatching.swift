import Foundation

/// When an exact `old_string` or hunk misses, a second match that is still unique: line endings,
/// trailing whitespace and a few Unicode punctuation characters folded together, and (for local
/// models) one indentation delta shared by every line. The replacement covers only the matched
/// lines, so every other line keeps its bytes. There is no similarity threshold.
enum EditMatching {
    enum Kind: Equatable { case canonical, indentation }

    struct Hit: Equatable {
        var range: NSRange
        var replacement: String
        var kind: Kind
    }

    enum Outcome: Equatable {
        case none
        case ambiguous(count: Int, firstLines: [Int])
        case noop
        case hits([Hit])
    }

    static func alternative(old: String, new: String, in text: String, tolerance: EditTolerance, replaceAll: Bool) -> Outcome {
        if tolerance.matchCanonically {
            let found = lineMatches(needle: logicalLines(old), in: text, equal: { canonical($0) == canonical($1) })
            if let outcome = outcome(found, new: new, in: text, kind: .canonical, replaceAll: replaceAll, reindent: nil) {
                return outcome
            }
        }
        if tolerance.shiftIndentation {
            let found = indentMatches(needle: logicalLines(old), in: text)
            if let outcome = outcome(found.spans, new: new, in: text, kind: .indentation, replaceAll: replaceAll, reindent: found.shift) {
                return outcome
            }
        }
        return .none
    }

    /// Hunk lines (no terminators) against file lines (no terminators). `nil` when nothing unique matches.
    static func hunkPosition(old: [String], in lines: [String], floor: Int, tolerance: EditTolerance) -> (index: Int, shift: IndentShift?)? {
        if tolerance.matchCanonically {
            let places = positions(count: old.count, in: lines, floor: floor) { offset, position in
                canonical(lines[position + offset]) == canonical(old[offset])
            }
            if places.count == 1 { return (places[0], nil) }
        }
        if tolerance.shiftIndentation {
            let places = indentPositions(old: old, in: lines, floor: floor)
            if places.count == 1 { return places[0] }
        }
        return nil
    }

    // MARK: - Lines

    struct Span {
        var range: NSRange
        var startLine: Int
    }

    struct IndentShift: Equatable {
        /// Whitespace the file has in front of every needle line.
        var add: String = ""
        /// Whitespace characters the needle has that the file does not.
        var strip: Int = 0

        var isIdentity: Bool { add.isEmpty && strip == 0 }

        func apply(to line: String) -> String {
            guard !line.isEmpty else { return line }
            var result = line
            var stripped = 0
            while stripped < strip, let first = result.first, first == " " || first == "\t" {
                result.removeFirst()
                stripped += 1
            }
            return add + result
        }
    }

    private struct FileLine {
        var content: String
        var range: NSRange
    }

    private static func fileLines(_ text: String) -> [FileLine] {
        let ns = text as NSString
        var lines: [FileLine] = []
        var start = 0
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A {
                let range = NSRange(location: start, length: index + 1 - start)
                lines.append(FileLine(content: ns.substring(with: range), range: range))
                start = index + 1
            }
            index += 1
        }
        if start < ns.length {
            let range = NSRange(location: start, length: ns.length - start)
            lines.append(FileLine(content: ns.substring(with: range), range: range))
        }
        return lines
    }

    static func logicalLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    static func canonical(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\r", with: "")
        if text.hasSuffix("\n") { text.removeLast() }
        while text.last == " " || text.last == "\t" { text.removeLast() }
        text = text.precomposedStringWithCompatibilityMapping
        let pairs: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{201B}", "'"),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2212}", "-"),
            ("\u{00A0}", " "), ("\u{2026}", "..."),
        ]
        for (from, to) in pairs where text.contains(from) { text = text.replacingOccurrences(of: from, with: to) }
        return text
    }

    private static func lineMatches(needle: [String], in text: String, equal: (String, String) -> Bool) -> [Span] {
        let lines = fileLines(text)
        guard !needle.isEmpty, lines.count >= needle.count else { return [] }
        var found: [Span] = []
        var index = 0
        while index + needle.count <= lines.count {
            let matches = needle.indices.allSatisfy { offset in equal(lines[index + offset].content, needle[offset]) }
            if matches {
                let first = lines[index]
                let last = lines[index + needle.count - 1]
                let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
                found.append(Span(range: range, startLine: index + 1))
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func indentMatches(needle: [String], in text: String) -> (spans: [Span], shift: IndentShift?) {
        let lines = fileLines(text)
        guard !needle.isEmpty, lines.count >= needle.count else { return ([], nil) }
        var found: [Span] = []
        var shift: IndentShift?
        var index = 0
        while index + needle.count <= lines.count {
            if let delta = sharedShift(needle: needle, file: lines, at: index), !delta.isIdentity {
                let first = lines[index]
                let last = lines[index + needle.count - 1]
                let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
                found.append(Span(range: range, startLine: index + 1))
                shift = delta
                index += needle.count
            } else {
                index += 1
            }
        }
        return (found, shift)
    }

    private static func sharedShift(needle: [String], file: [FileLine], at index: Int) -> IndentShift? {
        var shift: IndentShift?
        var compared = 0
        for offset in needle.indices {
            let old = needle[offset]
            let line = bare(file[index + offset].content)
            let oldLead = leading(old)
            let fileLead = leading(line)
            let oldBody = old.dropFirst(oldLead.count)
            let fileBody = line.dropFirst(fileLead.count)
            if oldBody.isEmpty && fileBody.isEmpty { continue }
            guard oldBody == fileBody else { return nil }
            let delta: IndentShift
            if fileLead.hasSuffix(oldLead) {
                delta = IndentShift(add: String(fileLead.dropLast(oldLead.count)), strip: 0)
            } else if oldLead.hasSuffix(fileLead) {
                delta = IndentShift(add: "", strip: oldLead.count - fileLead.count)
            } else {
                return nil
            }
            if let shift, shift != delta { return nil }
            shift = delta
            compared += 1
        }
        guard compared > 0, let shift else { return nil }
        return shift
    }

    private static func positions(count: Int, in lines: [String], floor: Int, equal: (Int, Int) -> Bool) -> [Int] {
        guard count > 0, lines.count >= count else { return [] }
        var found: [Int] = []
        var index = floor
        while index + count <= lines.count {
            let matches = (0..<count).allSatisfy { equal($0, index) }
            if matches {
                found.append(index)
                index += count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func indentPositions(old: [String], in lines: [String], floor: Int) -> [(index: Int, shift: IndentShift?)] {
        guard !old.isEmpty else { return [] }
        var found: [(Int, IndentShift?)] = []
        var index = floor
        while index + old.count <= lines.count {
            if let shift = sharedShift(needle: old, file: lines.enumerated().map { _, line in
                FileLine(content: line, range: NSRange(location: 0, length: 0))
            }, at: index), !shift.isIdentity {
                // sharedShift indexes `file` directly; rebuild against the slice by a local check.
                found.append((index, shift))
                index += old.count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func outcome(_ spans: [Span], new: String, in text: String, kind: Kind, replaceAll: Bool, reindent: IndentShift?) -> Outcome? {
        guard !spans.isEmpty else { return nil }
        if spans.count > 1, !replaceAll {
            return .ambiguous(count: spans.count, firstLines: spans.prefix(5).map(\.startLine))
        }
        let chosen = replaceAll ? spans : [spans[0]]
        let ending = EditSupport.lineEnding(of: text)
        let ns = text as NSString
        var hits: [Hit] = []
        for span in chosen {
            var replacement = reindent.map { shift in
                logicalLines(new).map { shift.apply(to: $0) }.joined(separator: "\n")
            } ?? new
            replacement = EditSupport.adapt(replacement, toLineEnding: ending)
            let original = ns.substring(with: span.range)
            let lineBreak = original.hasSuffix("\r\n") ? "\r\n" : (original.hasSuffix("\n") ? "\n" : "")
            if !lineBreak.isEmpty {
                while replacement.hasSuffix("\n") || replacement.hasSuffix("\r") { replacement.removeLast() }
                replacement += lineBreak
            }
            if replacement == original { return .noop }
            hits.append(Hit(range: span.range, replacement: replacement, kind: kind))
        }
        return .hits(hits)
    }

    private static func bare(_ line: String) -> String {
        var text = line
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    private static func leading(_ line: String) -> Substring {
        line.prefix { $0 == " " || $0 == "\t" }
    }
}
