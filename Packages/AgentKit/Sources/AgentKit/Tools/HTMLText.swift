import Foundation

/// Turns a web page into text a model can read: Markdown (headings, lists, links, code, tables as
/// rows) or plain text. A small tokenizer, not a browser: it drops scripts, styles, navigation and
/// other chrome, and does not run or fetch anything. Foundation only, so it works wherever AgentKit
/// does.
enum HTMLText {
    struct Result: Equatable {
        var title: String?
        var text: String
    }

    static func convert(_ html: String, base: URL?, markdown: Bool) -> Result {
        var converter = Converter(base: base, markdown: markdown)
        return converter.run(Array(html.utf8))
    }

    /// `&amp;`, `&#39;`, `&#x1F600;` and the handful of named entities pages actually use.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodeEntity(name) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®",
        "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…", "rarr": "→", "larr": "←", "laquo": "«",
        "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "bull": "•", "middot": "·",
        "times": "×", "deg": "°", "plusmn": "±", "para": "¶", "sect": "§",
    ]

    private static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[name]
    }
}

private struct Converter {
    let base: URL?
    let markdown: Bool

    private var out = ""
    private var lineHasContent = false
    private var pendingSpace = false
    private var skip: (name: String, depth: Int)?
    private var preBuffer: String?
    private var preLanguage: String?
    private var links: [String?] = []
    private var lists: [(ordered: Bool, count: Int)] = []
    private var title: String?
    private var titleBuffer: String?
    private var cellIndex = 0

    private static let void: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]
    /// Content that is page chrome or not for reading.
    private static let dropped: Set<String> = ["script", "style", "noscript", "template", "svg", "iframe", "nav", "footer", "select", "button", "canvas", "object"]
    private static let blocks: Set<String> = [
        "p", "div", "section", "article", "main", "header", "aside", "form", "figure", "figcaption", "fieldset",
        "details", "summary", "blockquote", "dl", "address", "center",
    ]

    init(base: URL?, markdown: Bool) {
        self.base = base
        self.markdown = markdown
    }

    mutating func run(_ bytes: [UInt8]) -> HTMLText.Result {
        var index = 0
        let count = bytes.count
        while index < count {
            if bytes[index] != UInt8(ascii: "<") {
                let end = bytes[index...].firstIndex(of: UInt8(ascii: "<")) ?? count
                text(String(decoding: bytes[index..<end], as: UTF8.self))
                index = end
                continue
            }
            if matches(bytes, index, "<!--") {
                index = find(bytes, "-->", from: index + 4).map { $0 + 3 } ?? count
            } else if index + 1 < count, bytes[index + 1] == UInt8(ascii: "!") || bytes[index + 1] == UInt8(ascii: "?") {
                index = (bytes[index...].firstIndex(of: UInt8(ascii: ">")) ?? count - 1) + 1
            } else if index + 1 < count, bytes[index + 1] == UInt8(ascii: "/") {
                let (name, next) = parseName(bytes, index + 2)
                close(name)
                index = (bytes[next...].firstIndex(of: UInt8(ascii: ">")) ?? count - 1) + 1
            } else if index + 1 < count, isLetter(bytes[index + 1]) {
                let (name, afterName) = parseName(bytes, index + 1)
                let (attributes, next) = parseAttributes(bytes, afterName)
                open(name, attributes)
                index = next
                if name == "script" || name == "style" {
                    // Raw text: nothing inside is markup.
                    index = find(bytes, "</\(name)", from: index).map { (bytes[$0...].firstIndex(of: UInt8(ascii: ">")) ?? count - 1) + 1 } ?? count
                    close(name)
                }
            } else {
                text("<")
                index += 1
            }
        }
        flushPre()
        var result = out
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        let lines = result.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        return HTMLText.Result(title: title, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Output

    private mutating func text(_ raw: String) {
        if skip != nil { return }
        let decoded = HTMLText.decodeEntities(raw)
        if titleBuffer != nil {
            titleBuffer! += decoded
            return
        }
        if preBuffer != nil {
            preBuffer! += decoded
            return
        }
        for character in decoded {
            if character.isWhitespace || character == "\u{00A0}" {
                pendingSpace = true
            } else {
                if pendingSpace, lineHasContent { out += " " }
                pendingSpace = false
                out.append(character)
                lineHasContent = true
            }
        }
    }

    /// Markup the converter writes itself. An opener keeps the space that came before it.
    private mutating func put(_ markup: String, opener: Bool = true) {
        if opener, pendingSpace, lineHasContent { out += " " }
        if opener { pendingSpace = false }
        out += markup
        lineHasContent = true
    }

    private mutating func endLine() {
        if lineHasContent { out += "\n" }
        lineHasContent = false
        pendingSpace = false
    }

    private mutating func blankLine() {
        endLine()
        if !out.isEmpty, !out.hasSuffix("\n\n") { out += "\n" }
    }

    private mutating func flushPre() {
        guard let buffer = preBuffer else { return }
        preBuffer = nil
        let code = buffer.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        blankLine()
        out += markdown ? "```\(preLanguage ?? "")\n\(code)\n```\n" : code + "\n"
        lineHasContent = false
        preLanguage = nil
    }

    // MARK: - Tags

    private mutating func open(_ name: String, _ attributes: [String: String]) {
        if let current = skip {
            if name == current.name, !Self.void.contains(name) { skip = (name, current.depth + 1) }
            return
        }
        if Self.dropped.contains(name), !Self.void.contains(name) {
            skip = (name, 1)
            return
        }
        switch name {
        case "title":
            titleBuffer = ""
        case "h1", "h2", "h3", "h4", "h5", "h6":
            blankLine()
            if markdown, let level = Int(name.dropFirst()) { put(String(repeating: "#", count: level) + " ") }
        case _ where Self.blocks.contains(name):
            blankLine()
        case "ul", "ol":
            if lists.isEmpty { blankLine() } else { endLine() }
            lists.append((name == "ol", 0))
        case "li":
            endLine()
            let depth = max(0, lists.count - 1)
            var marker = "- "
            if let last = lists.last, last.ordered {
                marker = "\(last.count + 1). "
                lists[lists.count - 1].count += 1
            }
            put(String(repeating: "  ", count: depth) + marker)
        case "br":
            if preBuffer != nil { preBuffer! += "\n" } else { endLine() }
        case "hr":
            blankLine()
            if markdown { put("---") }
            blankLine()
        case "pre":
            flushPre()
            blankLine()
            preBuffer = ""
        case "code":
            if preBuffer != nil {
                if let language = attributes["class"]?.split(separator: " ").first(where: { $0.hasPrefix("language-") }) {
                    preLanguage = String(language.dropFirst("language-".count))
                }
            } else if markdown {
                put("`")
            }
        case "a":
            if markdown, let href = resolved(attributes["href"]) {
                links.append(href)
                put("[")
            } else {
                links.append(nil)
            }
        case "img":
            if let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
                text("[image: \(alt)]")
            }
        case "strong", "b":
            if markdown, preBuffer == nil { put("**") }
        case "em", "i":
            if markdown, preBuffer == nil { put("*") }
        case "table":
            blankLine()
        case "tr", "dt", "dd":
            endLine()
            cellIndex = 0
        case "td", "th":
            if cellIndex > 0 { put(" | ", opener: false) }
            cellIndex += 1
        default:
            break
        }
    }

    private mutating func close(_ name: String) {
        if let current = skip {
            if name == current.name {
                skip = current.depth <= 1 ? nil : (name, current.depth - 1)
            }
            return
        }
        switch name {
        case "title":
            if let buffer = titleBuffer {
                titleBuffer = nil
                let collapsed = buffer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !collapsed.isEmpty { title = collapsed }
            }
        case "h1", "h2", "h3", "h4", "h5", "h6", "table":
            blankLine()
        case _ where Self.blocks.contains(name):
            blankLine()
        case "ul", "ol":
            _ = lists.popLast()
            if lists.isEmpty { blankLine() } else { endLine() }
        case "li", "tr", "dt", "dd":
            endLine()
        case "pre":
            flushPre()
        case "code":
            if preBuffer == nil, markdown { put("`", opener: false) }
        case "a":
            if let href = links.popLast() ?? nil { put("](\(href))", opener: false) }
        case "strong", "b":
            if markdown, preBuffer == nil { put("**", opener: false) }
        case "em", "i":
            if markdown, preBuffer == nil { put("*", opener: false) }
        default:
            break
        }
    }

    /// An absolute http(s) or mailto link. A bare fragment or a script is not worth showing.
    private func resolved(_ href: String?) -> String? {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:"),
              let url = URL(string: HTMLText.decodeEntities(href), relativeTo: base)?.absoluteURL
        else { return nil }
        return url.absoluteString
    }

    // MARK: - Scanning

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private func matches(_ bytes: [UInt8], _ index: Int, _ literal: String) -> Bool {
        let needle = Array(literal.utf8)
        guard index + needle.count <= bytes.count else { return false }
        return bytes[index..<index + needle.count].elementsEqual(needle)
    }

    /// The first position at or after `from` where `literal` starts, ignoring ASCII case.
    private func find(_ bytes: [UInt8], _ literal: String, from: Int) -> Int? {
        let needle = Array(literal.lowercased().utf8)
        guard !needle.isEmpty, bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
        var index = from
        while index <= bytes.count - needle.count {
            var hit = true
            for offset in 0..<needle.count {
                var byte = bytes[index + offset]
                if byte >= 65 && byte <= 90 { byte += 32 }
                if byte != needle[offset] { hit = false; break }
            }
            if hit { return index }
            index += 1
        }
        return nil
    }

    private func parseName(_ bytes: [UInt8], _ start: Int) -> (String, Int) {
        var end = start
        while end < bytes.count, isLetter(bytes[end]) || (bytes[end] >= 48 && bytes[end] <= 57) || bytes[end] == UInt8(ascii: "-") || bytes[end] == UInt8(ascii: ":") { end += 1 }
        return (String(decoding: bytes[start..<end], as: UTF8.self).lowercased(), end)
    }

    /// Attributes up to the closing `>`, with quotes respected. Only the names this converter reads are kept.
    private func parseAttributes(_ bytes: [UInt8], _ start: Int) -> ([String: String], Int) {
        var attributes: [String: String] = [:]
        var index = start
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ">") { return (attributes, index + 1) }
            if byte == UInt8(ascii: "/") || byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1; continue }
            var nameEnd = index
            while nameEnd < count, ![32, 9, 10, 13, UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[index..<nameEnd], as: UTF8.self).lowercased()
            index = nameEnd
            while index < count, bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 { index += 1 }
            var value = ""
            if index < count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                while index < count, bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 { index += 1 }
                if index < count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    let end = bytes[(index + 1)...].firstIndex(of: quote) ?? count
                    value = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    index = min(count, end + 1)
                } else {
                    var end = index
                    while end < count, ![32, 9, 10, 13, UInt8(ascii: ">")].contains(bytes[end]) { end += 1 }
                    value = String(decoding: bytes[index..<end], as: UTF8.self)
                    index = end
                }
            }
            if name == "href" || name == "alt" || name == "class" { attributes[name] = value }
            if nameEnd == start, index == nameEnd { index += 1 }
        }
        return (attributes, count)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
