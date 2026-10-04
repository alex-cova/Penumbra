import Foundation

/// What the composer's text and caret ask for: a command list, a mention list, or nothing. Pure, so
/// the rules are tested without a view. All offsets are UTF-16, as `NSTextView` counts them.
enum IDEAgentComposerTrigger: Equatable {
    case none
    /// `/` at the start of the message with the caret still inside that first word. `range` covers
    /// the slash and the query, which is what accepting a suggestion replaces.
    case slash(query: String, range: NSRange)
    /// The caret is after a command's name, on its first line: `/resume par|`. `range` covers what was
    /// typed after the name and its space.
    case slashArgument(command: String, query: String, range: NSRange)
    /// `@` at the start or after whitespace, with the caret still inside that word.
    case mention(query: String, range: NSRange)

    /// The range accepting a suggestion replaces.
    var range: NSRange? {
        switch self {
        case .none: nil
        case .slash(_, let range), .slashArgument(_, _, let range), .mention(_, let range): range
        }
    }

    static func detect(in text: String, caret: Int) -> IDEAgentComposerTrigger {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return .none }

        // A command's arguments: the message starts with `/name`, and the caret is past it on that line.
        if let argument = detectArgument(in: string, caret: caret) { return argument }

        // The word the caret is in: back to the previous whitespace.
        var start = caret
        while start > 0, !isWhitespace(string.character(at: start - 1)) { start -= 1 }
        guard start < caret, string.character(at: start) == slashUnit || string.character(at: start) == atUnit else {
            return .none
        }
        let range = NSRange(location: start, length: caret - start)
        let query = string.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        if string.character(at: start) == slashUnit {
            // A command is only the message's first word.
            return start == 0 ? .slash(query: query, range: range) : .none
        }
        return .mention(query: query, range: range)
    }

    private static func detectArgument(in string: NSString, caret: Int) -> IDEAgentComposerTrigger? {
        guard string.length > 1, string.character(at: 0) == slashUnit else { return nil }
        var nameEnd = 1
        while nameEnd < string.length, IDEAgentSlashInvocation.isNameCharacter(Character(Unicode.Scalar(string.character(at: nameEnd)) ?? " ")) {
            nameEnd += 1
        }
        // The name must end at a space or tab, and the caret must be past that space.
        guard nameEnd > 1, nameEnd < string.length, caret > nameEnd,
              [UInt16(32), 9].contains(string.character(at: nameEnd))
        else { return nil }
        let queryStart = nameEnd + 1
        let query = string.substring(with: NSRange(location: queryStart, length: caret - queryStart))
        guard !query.contains("\n") else { return nil }
        return .slashArgument(
            command: string.substring(with: NSRange(location: 1, length: nameEnd - 1)), query: query,
            range: NSRange(location: queryStart, length: caret - queryStart))
    }

    /// The text after accepting `replacement` for the trigger's range, with the caret after it.
    static func apply(_ replacement: String, replacing range: NSRange, in text: String) -> (text: String, caret: Int) {
        let result = (text as NSString).replacingCharacters(in: range, with: replacement)
        return (result, range.location + (replacement as NSString).length)
    }

    private static let slashUnit = UInt16(UInt8(ascii: "/"))
    private static let atUnit = UInt16(UInt8(ascii: "@"))

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// An `@word` in a message: what the composer colors and what a send turns into attachments.
struct IDEAgentMentionToken: Equatable {
    /// Without the `@`, the quotes and trailing punctuation.
    let text: String
    /// Covers the `@` and everything written for it, quotes included.
    let range: NSRange

    /// The mention for a path: `@path`, or `@"path with spaces"` when it has whitespace.
    static func format(path: String) -> String {
        path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? "@" + path : "@\"" + path + "\""
    }

    /// Mentions start at the beginning of the message or after whitespace, so `a@b.com` is not one.
    /// Trailing `. , ; : ! ? ) ]` belong to the sentence, not the path. `@"a b.txt"` names a path with
    /// spaces; an unclosed quote is read as a plain word.
    static func scan(_ text: String) -> [IDEAgentMentionToken] {
        let string = text as NSString
        let quote = UInt16(UInt8(ascii: "\""))
        var tokens: [IDEAgentMentionToken] = []
        var index = 0
        while index < string.length {
            let unit = string.character(at: index)
            let startsWord = index == 0 || isSpace(string.character(at: index - 1))
            guard unit == UInt16(UInt8(ascii: "@")), startsWord else { index += 1; continue }

            if index + 1 < string.length, string.character(at: index + 1) == quote,
               let close = closingQuote(in: string, from: index + 2, quote: quote), close > index + 2 {
                let inner = NSRange(location: index + 2, length: close - index - 2)
                tokens.append(IDEAgentMentionToken(
                    text: string.substring(with: inner), range: NSRange(location: index, length: close + 1 - index)))
                index = close + 1
                continue
            }

            var end = index + 1
            while end < string.length, !isSpace(string.character(at: end)) { end += 1 }
            while end > index + 1, isTrailingPunctuation(string.character(at: end - 1)) { end -= 1 }
            if end > index + 1 {
                let range = NSRange(location: index, length: end - index)
                tokens.append(IDEAgentMentionToken(text: string.substring(with: NSRange(location: index + 1, length: end - index - 1)), range: range))
            }
            index = max(end, index + 1)
        }
        return tokens
    }

    /// The closing quote on the same line, if there is one.
    private static func closingQuote(in string: NSString, from start: Int, quote: UInt16) -> Int? {
        var index = start
        while index < string.length {
            let unit = string.character(at: index)
            if unit == quote { return index }
            if unit == 10 || unit == 13 { return nil }
            index += 1
        }
        return nil
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isTrailingPunctuation(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return ".,;:!?)]".unicodeScalars.contains(scalar)
    }
}

/// Project-relative paths as a mention names them.
enum IDEAgentMentionPath {
    /// `url` relative to `root` when it is inside it, else the absolute path.
    static func relative(_ url: URL, root: URL?) -> String {
        let path = url.standardizedFileURL.path
        guard let root = root?.standardizedFileURL.path else { return path }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}
