import Foundation

/// Which tag-closing conveniences a ``TextView`` performs in markup.
public struct TagAutoClosingOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Typing the `>` that ends a start tag inserts the matching end tag after the caret.
    public static let onStartTagCompletion = TagAutoClosingOptions(rawValue: 1 << 0)
    /// Typing `/` after `<` completes the name of the innermost open element: `</div>`.
    public static let onEndTagSlash = TagAutoClosingOptions(rawValue: 1 << 1)

    /// The HTML elements that take no end tag, for ``TextView/voidTagNames``.
    public static let htmlVoidTagNames: Set<String> = TagAutoCloser.htmlVoidTags
}

/// What to type instead of the character the user typed.
struct TagAutoCloseEdit: Equatable {
    /// Replaces the typed character.
    let text: String
    /// Where the caret goes, in UTF-16 units from the start of `text`.
    let caretOffset: Int
}

/// Decides tag auto-closing from the markup in front of the caret. Pure, so it is tested without
/// a text view.
///
/// It tokenizes `textBefore` forward, tracking open elements, and skipping comments, CDATA,
/// declarations, processing instructions, quoted attribute values and the bodies of `script` and
/// `style`. `textBefore` should start at a line start; a window that begins inside a comment is
/// read as markup.
enum TagAutoCloser {
    /// The most text in front of the caret that a host should hand over.
    static let maximumLookBehind = 65_536
    /// How much text after the caret ``edit(typed:textBefore:textAfter:options:voidTags:)`` reads.
    static let lookAheadLength = 256

    /// HTML elements that have no end tag.
    static let htmlVoidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"
    ]

    private static let rawTextTags: Set<String> = ["script", "style"]

    /// - Parameters:
    ///   - typed: The character being typed, `">"` or `"/"`.
    ///   - voidTags: Lowercase names that take no end tag. `nil` is XML: names are case-sensitive
    ///     and only `/>` ends an element.
    static func edit(typed: String,
                     textBefore: String,
                     textAfter: String,
                     options: TagAutoClosingOptions,
                     voidTags: Set<String>?) -> TagAutoCloseEdit? {
        switch typed {
        case ">" where options.contains(.onStartTagCompletion):
            return closeStartTag(textBefore: textBefore, textAfter: textAfter, voidTags: voidTags)
        case "/" where options.contains(.onEndTagSlash):
            guard textBefore.hasSuffix("<") else {
                return nil
            }
            return completeEndTag(textBefore: String(textBefore.dropLast()), voidTags: voidTags)
        default:
            return nil
        }
    }

    // MARK: - Edits

    private static func closeStartTag(textBefore: String, textAfter: String, voidTags: Set<String>?) -> TagAutoCloseEdit? {
        guard case .insideStartTag(let name, let isInQuote, let endsWithSlash) = scan(textBefore, voidTags: voidTags).state,
              !isInQuote, !endsWithSlash,
              !(voidTags?.contains(name.lowercased()) ?? false),
              !isInsideCompleteTag(textAfter),
              !textAfter.hasPrefix("</" + name) else {
            return nil
        }
        return TagAutoCloseEdit(text: "></\(name)>", caretOffset: 1)
    }

    private static func completeEndTag(textBefore: String, voidTags: Set<String>?) -> TagAutoCloseEdit? {
        let scanned = scan(textBefore, voidTags: voidTags)
        let name: String
        switch scanned.state {
        case .text:
            guard let innermost = scanned.open.last else {
                return nil
            }
            name = innermost
        case .insideRawText(let raw):
            name = raw
        default:
            return nil
        }
        let text = "/\(name)>"
        return TagAutoCloseEdit(text: text, caretOffset: text.utf16.count)
    }

    /// `<di|v>`: the text after the caret finishes a tag that is already there.
    private static func isInsideCompleteTag(_ textAfter: String) -> Bool {
        for character in textAfter {
            if character == ">" {
                return true
            }
            if character == "<" {
                return false
            }
        }
        return false
    }

    // MARK: - Scanning

    private enum State: Equatable {
        case text
        /// In `<name …` that has no `>` yet.
        case insideStartTag(name: String, isInQuote: Bool, endsWithSlash: Bool)
        /// In the body of `script` or `style`.
        case insideRawText(String)
        /// In a comment, CDATA section, declaration, processing instruction or end tag.
        case insideOther
    }

    private struct Scanned {
        var open: [String]
        var state: State
    }

    private static func scan(_ text: String, voidTags: Set<String>?) -> Scanned {
        let isHTML = voidTags != nil
        let units = Array(text.utf16)
        let count = units.count
        var open: [String] = []
        var index = 0

        func has(_ literal: String, at position: Int, caseInsensitive: Bool = false) -> Bool {
            let target = Array(literal.utf16)
            guard position + target.count <= count else {
                return false
            }
            for offset in 0 ..< target.count {
                var unit = units[position + offset]
                if caseInsensitive, unit >= 0x41, unit <= 0x5A {
                    unit += 0x20
                }
                if unit != target[offset] {
                    return false
                }
            }
            return true
        }
        func find(_ literal: String, from position: Int, caseInsensitive: Bool = false) -> Int? {
            var scan = position
            while scan < count {
                if has(literal, at: scan, caseInsensitive: caseInsensitive) {
                    return scan
                }
                scan += 1
            }
            return nil
        }
        func isNameUnit(_ unit: UInt16) -> Bool {
            (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
                || unit == 0x5F || unit == 0x3A || unit == 0x2E || unit == 0x2D || unit >= 0x80
        }
        func isNameStart(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x3A || unit >= 0x80
        }
        func key(_ name: String) -> String {
            isHTML ? name.lowercased() : name
        }

        while index < count {
            guard units[index] == UInt16(ascii: "<") else {
                index += 1
                continue
            }
            if has("<!--", at: index) {
                guard let end = find("-->", from: index + 4) else {
                    return Scanned(open: open, state: .insideOther)
                }
                index = end + 3
            } else if has("<![CDATA[", at: index) {
                guard let end = find("]]>", from: index + 9) else {
                    return Scanned(open: open, state: .insideOther)
                }
                index = end + 3
            } else if has("<!", at: index) || has("<?", at: index) {
                guard let end = find(">", from: index + 2) else {
                    return Scanned(open: open, state: .insideOther)
                }
                index = end + 1
            } else if has("</", at: index) {
                var nameEnd = index + 2
                while nameEnd < count, isNameUnit(units[nameEnd]) {
                    nameEnd += 1
                }
                let name = String(decoding: units[index + 2 ..< nameEnd], as: UTF16.self)
                guard let end = find(">", from: nameEnd) else {
                    return Scanned(open: open, state: .insideOther)
                }
                if let position = open.lastIndex(where: { key($0) == key(name) }) {
                    open.removeSubrange(position...)
                }
                index = end + 1
            } else if index + 1 < count, isNameStart(units[index + 1]) {
                var nameEnd = index + 1
                while nameEnd < count, isNameUnit(units[nameEnd]) {
                    nameEnd += 1
                }
                let name = String(decoding: units[index + 1 ..< nameEnd], as: UTF16.self)
                var cursor = nameEnd
                var quote: UInt16?
                var closed = false
                while cursor < count {
                    let unit = units[cursor]
                    if let quoteUnit = quote {
                        if unit == quoteUnit {
                            quote = nil
                        }
                    } else if unit == UInt16(ascii: "\"") || unit == UInt16(ascii: "'") {
                        quote = unit
                    } else if unit == UInt16(ascii: ">") {
                        closed = true
                        break
                    }
                    cursor += 1
                }
                guard closed else {
                    var last = count - 1
                    while last > nameEnd, units[last] == 0x20 || units[last] == 0x09 || units[last] == 0x0A || units[last] == 0x0D {
                        last -= 1
                    }
                    let endsWithSlash = quote == nil && last >= nameEnd && units[last] == UInt16(ascii: "/")
                    return Scanned(open: open,
                                   state: .insideStartTag(name: name, isInQuote: quote != nil, endsWithSlash: endsWithSlash))
                }
                let selfClosing = cursor > nameEnd && units[cursor - 1] == UInt16(ascii: "/")
                index = cursor + 1
                if selfClosing || (voidTags?.contains(name.lowercased()) ?? false) {
                    continue
                }
                if isHTML, rawTextTags.contains(name.lowercased()) {
                    guard let end = find("</" + name.lowercased(), from: index, caseInsensitive: true) else {
                        open.append(name)
                        return Scanned(open: open, state: .insideRawText(name))
                    }
                    index = end
                }
                open.append(name)
            } else {
                // A `<` that starts no markup.
                index += 1
            }
        }
        return Scanned(open: open, state: .text)
    }
}
