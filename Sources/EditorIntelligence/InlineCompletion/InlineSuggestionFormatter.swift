import Foundation

/// Cleans a raw model completion into something insertable: "formats and adds required
/// brackets and quotes".
public enum InlineSuggestionFormatter {
    /// - Parameters:
    ///   - raw: the model's text.
    ///   - suffixLine: what follows the caret on its line, used to drop a duplicated tail.
    ///   - maxLines: 1 cuts at the first newline.
    ///   - indentation: the caret line's indentation, re-applied to continuation lines that
    ///     lost theirs.
    public static func format(_ raw: String, suffixLine: String, maxLines: Int, indentation: String = "") -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if maxLines <= 1 {
            if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        } else {
            // Multi-line: at most 8 lines, stopping at a blank line or at a dedent below
            // the starting block. The block's level is the shallower of the caret line's
            // indentation and the first continuation line's: models indent relative to
            // the block they open, not to the file.
            var kept: [String] = []
            var blockIndent: Int?
            for line in text.components(separatedBy: "\n") {
                if kept.count >= min(maxLines, 8) { break }
                if !kept.isEmpty {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    let lineIndent = String(line.prefix { $0 == " " || $0 == "\t" }).count
                    if let blockIndent {
                        if lineIndent < min(indentation.count, blockIndent) { break }
                    } else {
                        blockIndent = lineIndent
                    }
                }
                kept.append(line)
            }
            text = kept.joined(separator: "\n")
        }
        // Trim trailing whitespace on every line.
        text = text.components(separatedBy: "\n")
            .map { line in line.reversed().drop { $0 == " " || $0 == "\t" }.reversed() }
            .map(String.init)
            .joined(separator: "\n")
        // Drop a tail that only repeats what already follows the caret (`)`, `";`, …).
        let closers = suffixLine.prefix { ")]}>\"';, ".contains($0) }
        if !closers.isEmpty, text.hasSuffix(closers) {
            text = String(text.dropLast(closers.count))
        }
        text = appendClosers(to: text)
        if maxLines > 1, !indentation.isEmpty {
            var lines = text.components(separatedBy: "\n")
            for index in lines.indices.dropFirst() where !lines[index].isEmpty && !lines[index].first!.isWhitespace {
                lines[index] = indentation + lines[index]
            }
            text = lines.joined(separator: "\n")
        }
        return text.allSatisfy({ $0.isWhitespace }) ? nil : text
    }

    /// Appends the closers for brackets and quotes the suggestion opened and left open.
    /// Strings and character literals are skipped naively: a quote toggles, `\` escapes.
    static func appendClosers(to text: String) -> String {
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(": stack.append(")")
            case "[": stack.append("]")
            case "{": stack.append("}")
            case ")", "]", "}":
                if stack.last == character { stack.removeLast() }
            default: break
            }
        }
        var result = text
        if let quote { result.append(quote) }
        result.append(contentsOf: stack.reversed())
        return result
    }
}

/// The smart filter: suggestions that are too short, only punctuation, a repeat of the
/// previous line, or ones the user already rejected at the same line prefix are dropped.
public final class InlineCompletionFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed: [(key: String, suggestion: String)] = []
    private let capacity = 32

    public init() {}

    /// A suggestion the user dismissed (Esc, caret move) or deleted right after accepting.
    public func recordSuppressed(linePrefix: String, suggestion: String) {
        lock.lock()
        defer { lock.unlock() }
        suppressed.removeAll { $0.key == linePrefix && $0.suggestion == suggestion }
        suppressed.append((linePrefix, suggestion))
        if suppressed.count > capacity { suppressed.removeFirst(suppressed.count - capacity) }
    }

    public func isSuppressed(linePrefix: String, suggestion: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressed.contains { $0.key == linePrefix && $0.suggestion == suggestion }
    }

    /// Whether `text` is worth showing for `request`, before validation.
    public func accepts(_ text: String, for request: InlineCompletionRequest) -> Bool {
        let nonSpace = text.filter { !$0.isWhitespace }
        guard nonSpace.count >= 2 else { return false }
        guard nonSpace.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let firstLine = text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty, firstLine == request.previousLine, !request.previousLine.isEmpty { return false }
        if isSuppressed(linePrefix: request.currentLinePrefix, suggestion: text) { return false }
        return true
    }
}
