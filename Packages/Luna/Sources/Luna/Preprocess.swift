// Ported from Pele src/preprocess.ts, src/util/yaml.ts (the subset that preprocessing uses)
// and src/text/entities.ts @ 8603bf3 (MIT, Copyright (c) 2026 kepano). See Packages/Luna/NOTICE.
import Foundation

/// A YAML value from the preprocessing subset.
public enum YamlValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([YamlValue])
    case object([String: YamlValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: [String: YamlValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

private struct YamlError: Error {
    var message: String
}

private let yamlMaxDepth = 64

// A small YAML reader covering what Mermaid feeds to js-yaml with the JSON schema:
// block and flow collections, quoted and plain scalars, and block scalars.
private struct YamlReader {
    var lines: [String]
    var i: Int = 0

    init(_ src: String) {
        self.lines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    mutating func skipBlank() {
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t != "" && !t.hasPrefix("#") && t != "---" { break }
            i += 1
        }
    }

    func indent() throws -> Int {
        let line = lines[i]
        var k = 0
        for ch in line {
            if ch == " " { k += 1 } else { break }
        }
        if k < line.count && line[line.index(line.startIndex, offsetBy: k)] == "\t" {
            throw YamlError(message: "YAML: tabs are not allowed for indentation")
        }
        return k
    }
}

private func yamlIsBlank(_ ch: Character?) -> Bool {
    ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
}

// Splits `key: rest` at the start of a line. Returns the raw key and the offset where the value starts.
private func yamlSplitKey(_ line: [Character]) -> (key: String, length: Int)? {
    guard !line.isEmpty else { return nil }
    let first = line[0]
    var end: Int
    var colon: Int
    if first == "\"" || first == "'" {
        var i = 1
        while true {
            if i >= line.count { return nil }
            let c = line[i]
            if first == "\"" && c == "\\" { i += 2 }
            else if c == first {
                if first == "\"" || i + 1 >= line.count || line[i + 1] != "'" { break }
                i += 2
            } else { i += 1 }
        }
        end = i + 1
        colon = end
        while colon < line.count && yamlIsBlank(line[colon]) { colon += 1 }
        if colon >= line.count || line[colon] != ":" { return nil }
    } else {
        if first == " " || first == "\t" || first == "\n" || first == "#" || first == ","
            || first == ":" || first == "[" || first == "]" || first == "{" || first == "}"
            || first == "&" || first == "*" || first == "!" || first == "|" || first == ">"
            || first == "'" || first == "\"" || first == "%" || first == "@" || first == "`" {
            return nil
        }
        if first == "-" && (line.count < 2 || yamlIsBlank(line[1]) || line[1] == ":" || line[1] == "#") {
            return nil
        }
        colon = 1
        while colon < line.count && line[colon] != ":" && line[colon] != "#" { colon += 1 }
        if colon >= line.count || line[colon] != ":" { return nil }
        end = colon
        while end > 0 && yamlIsBlank(line[end - 1]) { end -= 1 }
    }
    var length = colon + 1
    if length < line.count && !yamlIsBlank(line[length]) { return nil }
    while length < line.count && yamlIsBlank(line[length]) { length += 1 }
    return (String(line[0..<end]), length)
}

private func yamlScalar(_ raw: String) -> YamlValue {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s == "" || s == "~" || s == "null" || s == "Null" || s == "NULL" { return .null }
    if s == "true" || s == "True" || s == "TRUE" { return .bool(true) }
    if s == "false" || s == "False" || s == "FALSE" { return .bool(false) }
    if s.range(of: #"^[-+]?(?:0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
        || s.range(of: #"^[-+]?(?:[0-9][0-9]*(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil {
        return .number(Double(s) ?? 0)
    }
    if s.range(of: #"^[-+]?0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        || s.range(of: #"^[-+]?0o[0-7]+$"#, options: .regularExpression) != nil
        || s.range(of: #"^[-+]?0b[01]+$"#, options: .regularExpression) != nil {
        let neg = s.hasPrefix("-")
        let body = (s.hasPrefix("-") || s.hasPrefix("+")) ? String(s.dropFirst()) : s
        let v = Double(Int(body.dropFirst(2), radix: body.hasPrefix("0x") || body.hasPrefix("0X") ? 16 : body.hasPrefix("0o") || body.hasPrefix("0O") ? 8 : 2) ?? 0)
        return .number(neg ? -v : v)
    }
    if s.range(of: #"^[-+]?\.(?:inf|Inf|INF)$"#, options: .regularExpression) != nil {
        return .number(s.hasPrefix("-") ? -Double.infinity : Double.infinity)
    }
    if s.range(of: #"^\.(?:nan|NaN|NAN)$"#, options: .regularExpression) != nil {
        return .number(Double.nan)
    }
    return .string(s)
}

private let yamlEscapes: [Character: String] = [
    "0": "\0", "a": "\u{07}", "b": "\u{08}", "t": "\t", "n": "\n", "v": "\u{0B}",
    "f": "\u{0C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/",
    "\\": "\\", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
]

// Folds the line breaks of a scalar: blanks around a break go, one break becomes a space, and
// each further break stays.
private func yamlFold(_ text: String) -> String {
    if !text.contains("\n") { return text }
    var lines = text.components(separatedBy: "\n")
    let last = lines.count - 1
    for i in 0...last {
        var line = lines[i]
        if i > 0 {
            while line.hasPrefix(" ") || line.hasPrefix("\t") { line.removeFirst() }
        }
        if i < last {
            while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
        }
        lines[i] = line
    }
    let joined = lines.joined(separator: "\n")
    var out = ""
    var i = joined.startIndex
    while i < joined.endIndex {
        if joined[i] == "\n" {
            var j = i
            while j < joined.endIndex && joined[j] == "\n" { j = joined.index(after: j) }
            let count = joined.distance(from: i, to: j)
            out += count == 1 ? " " : String(repeating: "\n", count: count - 1)
            i = j
        } else {
            out.append(joined[i])
            i = joined.index(after: i)
        }
    }
    return out
}

private func yamlUnquoteDouble(_ body: String) throws -> String {
    var out = ""
    let folded: String = {
        var s = body
        while let r = s.range(of: #"\\\n[ \t]*"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "")
        }
        return yamlFold(s)
    }()
    var i = folded.startIndex
    while i < folded.endIndex {
        let ch = folded[i]
        if ch != "\\" {
            out.append(ch)
            i = folded.index(after: i)
            continue
        }
        i = folded.index(after: i)
        guard i < folded.endIndex else { break }
        let e = folded[i]
        if e == "x" || e == "u" || e == "U" {
            let len = e == "x" ? 2 : e == "u" ? 4 : 8
            var j = folded.index(after: i)
            var hex = ""
            for _ in 0..<len {
                if j < folded.endIndex { hex.append(folded[j]); j = folded.index(after: j) }
            }
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            }
            i = j
        } else if let rep = yamlEscapes[e] {
            out.append(rep)
            i = folded.index(after: i)
        } else {
            throw YamlError(message: "YAML: unknown escape sequence")
        }
    }
    return out
}

private func yamlSkip(_ s: [Character], _ pos: Int, commas: Bool) -> Int {
    var pos = pos
    while pos < s.count {
        let c = s[pos]
        if c == " " || c == "\n" || c == "\t" || c == "\r" || (commas && c == ",") {
            pos += 1
        } else if c == "#" && (pos == 0 || s[pos - 1] == " " || s[pos - 1] == "\t"
                 || s[pos - 1] == "\n" || s[pos - 1] == "\r") {
            var nl = pos
            while nl < s.count && s[nl] != "\n" { nl += 1 }
            pos = nl
        } else {
            break
        }
    }
    return pos
}

// Entries of a flow collection are separated by exactly one comma, as js-yaml requires.
private func yamlEntryStart(_ ch: Character, separated: Bool) throws {
    if !separated { throw YamlError(message: "YAML: missed comma between flow collection entries") }
    if ch == "," { throw YamlError(message: "YAML: expected the node content, but found ','") }
}

private struct YamlIncomplete: Error {
    var message: String
}

// Parses a flow value starting at s[pos]; returns the value and the index after it.
private func yamlFlow(_ s: [Character], _ pos: Int, _ stops: String, _ depth: Int = 0) throws -> (YamlValue, Int) {
    if depth > yamlMaxDepth { throw YamlError(message: "YAML: nesting is too deep") }
    var pos = yamlSkip(s, pos, commas: false)
    guard pos < s.count else { throw YamlIncomplete(message: "YAML: unexpected end of the stream") }
    let ch = s[pos]
    if ch == "{" {
        var out: [String: YamlValue] = [:]
        pos += 1
        var separated = true
        while true {
            pos = yamlSkip(s, pos, commas: false)
            if pos >= s.count {
                throw YamlIncomplete(message: "YAML: unexpected end of the stream within a flow collection")
            }
            if s[pos] == "}" { return (.object(out), pos + 1) }
            try yamlEntryStart(s[pos], separated: separated)
            let key: YamlValue
            (key, pos) = try yamlFlow(s, pos, ":,}", depth + 1)
            pos = yamlSkip(s, pos, commas: false)
            var value: YamlValue = .null
            if pos < s.count && s[pos] == ":" {
                (value, pos) = try yamlFlow(s, pos + 1, ",}", depth + 1)
            }
            out[yamlKeyString(key)] = value
            pos = yamlSkip(s, pos, commas: false)
            separated = pos < s.count && s[pos] == ","
            if separated { pos += 1 }
        }
    }
    if ch == "[" {
        var out: [YamlValue] = []
        pos += 1
        var separated = true
        while true {
            pos = yamlSkip(s, pos, commas: false)
            if pos >= s.count {
                throw YamlIncomplete(message: "YAML: unexpected end of the stream within a flow collection")
            }
            if s[pos] == "]" { return (.array(out), pos + 1) }
            try yamlEntryStart(s[pos], separated: separated)
            let value: YamlValue
            (value, pos) = try yamlFlow(s, pos, ",]", depth + 1)
            out.append(value)
            pos = yamlSkip(s, pos, commas: false)
            separated = pos < s.count && s[pos] == ","
            if separated { pos += 1 }
        }
    }
    if ch == "\"" {
        var end = pos + 1
        while end < s.count && s[end] != "\"" { end += s[end] == "\\" ? 2 : 1 }
        if end >= s.count {
            throw YamlIncomplete(message: "YAML: unexpected end of the stream within a double quoted scalar")
        }
        return (try .string(yamlUnquoteDouble(String(s[(pos + 1)..<end]))), end + 1)
    }
    if ch == "'" {
        var end = pos + 1
        while end < s.count {
            if s[end] == "'" {
                if end + 1 >= s.count || s[end + 1] != "'" { break }
                end += 1
            }
            end += 1
        }
        if end >= s.count {
            throw YamlIncomplete(message: "YAML: unexpected end of the stream within a single quoted scalar")
        }
        return (.string(yamlFold(String(s[(pos + 1)..<end])).replacingOccurrences(of: "''", with: "'")), end + 1)
    }
    var end = pos
    while end < s.count {
        let c = s[end]
        if stops.contains(c) && (c != ":" || end + 1 >= s.count || " \t\n\r,[,]{}"
            .contains(s[end + 1])) {
            break
        }
        if c == "#" && end > pos && (s[end - 1] == " " || s[end - 1] == "\t") {
            var nl = end
            while nl < s.count && s[nl] != "\n" { nl += 1 }
            return (yamlScalar(yamlFold(String(s[pos..<end]).trimmingCharacters(in: .whitespaces))), nl)
        }
        end += 1
    }
    return (yamlScalar(yamlFold(String(s[pos..<end]).trimmingCharacters(in: .whitespaces))), end)
}

private func yamlKeyString(_ key: YamlValue) -> String {
    switch key {
    case .string(let s): return s
    case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array(let a): return a.map(yamlKeyString).joined(separator: ",")
    case .object: return "[object]"
    }
}

private func yamlStripComment(_ s: String) -> String {
    var quote: Character?
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if let q = quote {
            if c == "\\" && q == "\"" { i += 2; continue }
            if c == q { quote = nil }
        } else if c == "\"" || c == "'" {
            quote = c
        } else if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
            return String(chars[0..<i])
        }
        i += 1
    }
    return s
}

private func yamlBlockScalar(_ r: inout YamlReader, header: String, parentIndent: Int) -> String {
    let folded = header.hasPrefix(">")
    let chomp: Character? = header.contains("-") ? "-" : header.contains("+") ? "+" : nil
    var indent = -1
    for ch in header {
        if ch >= "1" && ch <= "9" {
            indent = parentIndent + Int(String(ch))!
            break
        }
    }
    var out: [String] = []
    while r.i < r.lines.count {
        let line = r.lines[r.i]
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("")
            r.i += 1
            continue
        }
        let k = line.prefix(while: { $0 == " " }).count
        if indent == -1 {
            if k <= parentIndent { break }
            indent = k
        }
        if k < indent { break }
        out.append(String(line.dropFirst(indent)))
        r.i += 1
    }
    var trailing = 0
    while out.last == "" {
        out.removeLast()
        trailing += 1
    }
    if folded {
        var text = ""
        for i in 0..<out.count {
            let cur = out[i]
            if i > 0 {
                let prev = out[i - 1]
                if cur == "" { text += "\n" }
                else if prev != "" {
                    text += (prev.hasPrefix(" ") || prev.hasPrefix("\t")
                        || cur.hasPrefix(" ") || cur.hasPrefix("\t")) ? "\n" : " "
                }
            }
            text += cur
        }
        if out.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
        if chomp == "-" { return text }
        if chomp == "+" { return text + String(repeating: "\n", count: trailing + 1) }
        return text + "\n"
    }
    let text = out.joined(separator: "\n")
    if out.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
    if chomp == "-" { return text }
    if chomp == "+" { return text + String(repeating: "\n", count: trailing + 1) }
    return text + "\n"
}

private func yamlInlineValue(_ r: inout YamlReader, rest: String, indent: Int) throws -> YamlValue {
    let first: Character? = rest.first
    if first == "|" || first == ">" {
        if rest.range(of: #"^[|>][-+0-9]*\s*(?:#.*)?$"#, options: .regularExpression) != nil {
            return .string(yamlBlockScalar(&r, header: rest, parentIndent: indent))
        }
    }
    if first == "{" || first == "[" || first == "\"" || first == "'" {
        // The value may continue on later lines. Read them in growing batches until it closes.
        let start = r.i
        var text = rest
        var taken = 0
        var batch = 1
        while true {
            do {
                let chars = Array(text)
                let (value, end) = try yamlFlow(chars, 0, "")
                // Count newlines before end.
                let used = text.prefix(end).filter { $0 == "\n" }.count
                let endIdx = text.index(text.startIndex, offsetBy: min(end, text.count),
                                        limitedBy: text.endIndex) ?? text.endIndex
                let lineEnd: String.Index? = text[endIdx...].firstIndex(of: "\n")
                let tail = String(text[endIdx..<(lineEnd ?? text.endIndex)])
                if yamlStripComment(tail).trimmingCharacters(in: .whitespaces) != "" {
                    throw YamlError(message: "YAML: unexpected content after a value")
                }
                r.i = start + used
                return value
            } catch let err as YamlIncomplete {
                if start + taken >= r.lines.count { throw YamlError(message: err.message) }
                let more = r.lines[start + taken..<min(start + taken + batch, r.lines.count)]
                text += "\n" + more.joined(separator: "\n")
                taken += more.count
                batch *= 2
            }
        }
    }
    var text = yamlStripComment(rest).trimmingCharacters(in: .whitespaces)
    while r.i < r.lines.count {
        let line = r.lines[r.i]
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            var j = r.i
            while j < r.lines.count && r.lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j >= r.lines.count || r.lines[j].prefix(while: { $0 == " " }).count <= indent { break }
            text += String(repeating: "\n", count: j - r.i)
            r.i = j
            continue
        }
        if line.prefix(while: { $0 == " " }).count <= indent { break }
        let more = yamlStripComment(line).trimmingCharacters(in: .whitespaces)
        text += (text.hasSuffix("\n") ? "" : " ") + more
        r.i += 1
    }
    return yamlScalar(text)
}

private func yamlBlock(_ r: inout YamlReader, minIndent: Int, depth: Int = 0) throws -> YamlValue {
    if depth > yamlMaxDepth { throw YamlError(message: "YAML: nesting is too deep") }
    r.skipBlank()
    if r.i >= r.lines.count { return .null }
    let indent = try r.indent()
    if indent < minIndent { return .null }
    let line = String(r.lines[r.i].dropFirst(indent))

    if line == "-" || line.hasPrefix("- ") {
        var out: [YamlValue] = []
        while r.i < r.lines.count {
            r.skipBlank()
            if r.i >= r.lines.count { break }
            if (try r.indent()) != indent { break }
            let cur = String(r.lines[r.i].dropFirst(indent))
            if cur != "-" && !cur.hasPrefix("- ") { break }
            let rest = String(cur.dropFirst())
            let pad = rest.prefix(while: { $0 == " " }).count + 1
            let body = yamlStripComment(rest).trimmingCharacters(in: .whitespaces)
            if body == "" {
                r.i += 1
                out.append(try yamlBlock(&r, minIndent: indent + 1, depth: depth + 1))
            } else if yamlSplitKey(Array(body)) != nil {
                r.lines[r.i] = String(repeating: " ", count: indent + pad) + rest.trimmingCharacters(in: .init(charactersIn: " "))
                out.append(try yamlBlock(&r, minIndent: indent + pad, depth: depth + 1))
            } else {
                r.i += 1
                out.append(try yamlInlineValue(&r, rest: rest.trimmingCharacters(in: .whitespaces), indent: indent))
            }
        }
        return .array(out)
    }

    if yamlSplitKey(Array(line)) == nil {
        r.i += 1
        return try yamlInlineValue(&r, rest: line.trimmingCharacters(in: .whitespaces), indent: indent - 1)
    }

    var out: [String: YamlValue] = [:]
    while r.i < r.lines.count {
        r.skipBlank()
        if r.i >= r.lines.count { break }
        let k = try r.indent()
        if k < indent { break }
        if k > indent { throw YamlError(message: "YAML: bad indentation of a mapping entry") }
        let cur = String(r.lines[r.i].dropFirst(indent))
        guard let km = yamlSplitKey(Array(cur)) else {
            throw YamlError(message: "YAML: can not read a block mapping entry")
        }
        let chars = Array(km.key)
        let (keyVal, _) = try yamlFlow(chars, 0, "")
        let key = yamlKeyString(keyVal)
        let rest = String(cur.dropFirst(km.length))
        r.i += 1
        if yamlStripComment(rest).trimmingCharacters(in: .whitespaces) == "" {
            r.skipBlank()
            if r.i < r.lines.count {
                let next = try r.indent()
                let nextLine = String(r.lines[r.i].dropFirst(next))
                let seq = nextLine == "-" || nextLine.hasPrefix("- ")
                if next > indent || (seq && next == indent) {
                    out[key] = try yamlBlock(&r, minIndent: seq ? indent : indent + 1, depth: depth + 1)
                } else {
                    out[key] = .null
                }
            } else {
                out[key] = .null
            }
        } else {
            out[key] = try yamlInlineValue(&r, rest: rest.trimmingCharacters(in: .whitespaces), indent: indent)
        }
    }
    return .object(out)
}

/// Parses the preprocessing YAML subset (block/flow collections, quoted and plain scalars, block scalars).
public func parseYaml(_ src: String) throws -> YamlValue {
    let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
        do {
            let chars = Array(trimmed)
            let (value, end) = try yamlFlow(chars, 0, "")
            if yamlSkip(chars, end, commas: false) == chars.count { return value }
        } catch let err as YamlIncomplete {
            throw YamlError(message: err.message)
        }
    }
    var r = YamlReader(src)
    let value = try yamlBlock(&r, minIndent: 0)
    r.skipBlank()
    if r.i < r.lines.count && r.lines[r.i].trimmingCharacters(in: .whitespaces) != "..." {
        throw YamlError(message: "YAML: end of the stream or a document separator is expected")
    }
    return value
}

// MARK: - Preprocess

/// Preprocessed diagram source: text with the front matter and directives consumed.
public struct PreprocessedMermaid: Sendable {
    public var text: String
    public var title: String?
    public var config: [String: YamlValue]
    /// The text before its comment lines are removed, and the number of front matter lines before it.
    public var withComments: String
    public var lineOffset: Int
}

private let unsafeKeys: Set<String> = ["__proto__", "constructor", "prototype"]

private func lunaMerge(_ target: inout [String: YamlValue], _ source: [String: YamlValue]) {
    for (key, value) in source {
        if unsafeKeys.contains(key) { continue }
        if case .object(let sub) = value {
            if case .object(var cur) = target[key] {
                lunaMerge(&cur, sub)
                target[key] = .object(cur)
            } else {
                var fresh: [String: YamlValue] = [:]
                lunaMerge(&fresh, sub)
                target[key] = .object(fresh)
            }
        } else {
            target[key] = value
        }
    }
}

private func lunaIsSpace(_ ch: Character?) -> Bool {
    guard let ch else { return false }
    return ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
        || ch == "\u{0B}" || ch == "\u{0C}" || ch == "\u{2028}" || ch == "\u{2029}"
        || ch.isWhitespace
}

private func lunaIsLineBreak(_ ch: Character?) -> Bool {
    ch == "\n" || ch == "\r"
}

// Finds a `---` fenced YAML block at the start of the text the way Mermaid's front matter regex does.
private func lunaMatchFrontMatter(_ text: [Character]) -> (indent: Int, body: String, length: Int)? {
    var cursor = 0
    while cursor < text.count && lunaIsSpace(text[cursor]) && !lunaIsLineBreak(text[cursor]) {
        cursor += 1
    }
    let indent = cursor
    if cursor + 3 > text.count || String(text[cursor..<(cursor + 3)]) != "---" { return nil }

    var openingEnds: [Int] = []
    var i = cursor + 3
    while i < text.count && lunaIsSpace(text[i]) {
        if lunaIsLineBreak(text[i]) { openingEnds.append(i) }
        i += 1
    }
    if openingEnds.isEmpty { return nil }

    let fence = Array((String(text[0..<indent]) + "---"))
    func closingEnd(_ i: Int) -> Int {
        if !lunaIsLineBreak(text[i]) { return -1 }
        if i + 1 + fence.count > text.count { return -1 }
        for k in 0..<fence.count {
            if text[i + 1 + k] != fence[k] { return -1 }
        }
        var last = -1
        var j = i + 1 + fence.count
        while j < text.count && lunaIsSpace(text[j]) {
            if lunaIsLineBreak(text[j]) { last = j }
            j += 1
        }
        return last
    }

    var lastFence = -1
    // Search for the last fence line at or after the opening.
    var k = text.count - fence.count
    while k > openingEnds[0] {
        var match = true
        if k > 0 && !lunaIsLineBreak(text[k - 1]) { match = false }
        if match {
            for f in 0..<fence.count where text[k + f] != fence[f] { match = false; break }
        }
        if match && closingEnd(k - 1) != -1 {
            lastFence = k - 1
            break
        }
        k -= 1
    }
    if lastFence == -1 { return nil }

    var openingEnd = openingEnds[0]
    for candidate in openingEnds where candidate < lastFence { openingEnd = candidate }

    let bodyStart = openingEnd + 1
    let firstAt = bodyStart > 0 ? bodyStart - 1 : 0
    var j = firstAt
    while j <= lastFence {
        // Find next "\nfence" at or after j.
        var found = -1
        var s = j
        while s + 1 + fence.count <= text.count {
            if text[s] == "\n" {
                var ok = true
                for f in 0..<fence.count where text[s + 1 + f] != fence[f] { ok = false; break }
                if ok { found = s; break }
            }
            s += 1
        }
        if found == -1 { break }
        let ii = found
        if ii >= bodyStart {
            let end = closingEnd(ii)
            if end != -1 {
                return (indent, String(text[bodyStart..<ii]), end + 1)
            }
        }
        j = ii + 1
    }
    return nil
}

private func lunaDirectives(_ text: String, config: inout [String: YamlValue]) -> String {
    if !text.contains("%%{") { return text }
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "\"")
    // /%{2}{\s*(?:(\w+)\s*:|(\w+))\s*(?:(\w+)|((?:(?!}%{2}).|\r?\n)*))?\s*(?:}%{2})?/gi
    guard let re = try? NSRegularExpression(
        pattern: "%{2}\\{\\s*(?:(\\w+)\\s*:|(\\w+))\\s*(?:(\\w+)|((?:(?!\\}%{2}).|\\r?\\n)*))?\\s*(?:\\}%{2})?",
        options: [.caseInsensitive]) else {
        return text
    }
    let ns = result as NSString
    let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
    for m in matches {
        let type: String? = {
            if m.range(at: 1).location != NSNotFound { return ns.substring(with: m.range(at: 1)) }
            if m.range(at: 2).location != NSNotFound { return ns.substring(with: m.range(at: 2)) }
            return nil
        }()
        guard let type else { continue }
        if type.lowercased() == "wrap" {
            config["wrap"] = .bool(true)
        } else if (type == "init" || type == "initialize") && m.range(at: 4).location != NSNotFound {
            let body = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let dict = json as? [String: Any] {
                lunaMerge(&config, lunaConfigFromJSON(dict))
            }
            // Mermaid ignores an init directive whose body is not valid JSON.
        }
    }
    result = re.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: ns.length),
                                         withTemplate: "")
    return result
}

private func lunaConfigFromJSON(_ json: [String: Any]) -> [String: YamlValue] {
    var out: [String: YamlValue] = [:]
    for (k, v) in json { out[k] = lunaYamlFromJSON(v) }
    return out
}

private func lunaYamlFromJSON(_ v: Any) -> YamlValue {
    switch v {
    case is NSNull: return .null
    case let b as Bool: return .bool(b)
    case let n as NSNumber: return .number(n.doubleValue)
    case let s as String: return .string(s)
    case let a as [Any]: return .array(a.map(lunaYamlFromJSON))
    case let o as [String: Any]: return .object(lunaConfigFromJSON(o))
    default: return .string("\(v)")
    }
}

private func lunaCleanupComments(_ text: String) -> String {
    if !text.contains("%%") { return text.trimmingCharacters(in: .init(charactersIn: " \t\n\r")) }
    guard let re = try? NSRegularExpression(pattern: #"^\s*%%(?!{)[^\n]+\n?"#,
                                            options: [.anchorsMatchLines]) else {
        return text
    }
    let ns = text as NSString
    var out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                          withTemplate: "")
    while out.hasPrefix(" ") || out.hasPrefix("\t") || out.hasPrefix("\n") || out.hasPrefix("\r") {
        out.removeFirst()
    }
    return out
}

/// Runs Pele's preprocessing: CRLF normalization, front matter, init/wrap directives, comments.
public func preprocessMermaid(_ source: String) throws -> PreprocessedMermaid {
    var text = source.contains("\r")
        ? source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        : source
    // A tag needs a closing bracket, so nothing after the last one can match.
    if text.contains("<"), let lastClose = text.lastIndex(of: ">"), lastClose != text.startIndex {
        let head = String(text[...lastClose])
        let tail = String(text[text.index(after: lastClose)...])
        if let reTag = try? NSRegularExpression(pattern: "<(\\w+)([^>]*)>", options: []),
           let reAttr = try? NSRegularExpression(pattern: "=\"([^\"]*)\"", options: []) {
            let nsHead = head as NSString
            let full = NSRange(location: 0, length: nsHead.length)
            var converted = head
            for m in reTag.matches(in: head, range: full).reversed() {
                let tag = nsHead.substring(with: m.range(at: 1))
                var attrs = nsHead.substring(with: m.range(at: 2))
                let nsAttrs = attrs as NSString
                attrs = reAttr.stringByReplacingMatches(
                    in: attrs, range: NSRange(location: 0, length: nsAttrs.length), withTemplate: "='$1'")
                converted = (converted as NSString).replacingCharacters(
                    in: m.range, with: "<" + tag + attrs + ">")
            }
            text = converted + tail
        }
    }

    var config: [String: YamlValue] = [:]
    var title: String?
    var lineOffset = 0

    let chars = Array(text)
    if text.contains("---"), let front = lunaMatchFrontMatter(chars) {
        let body: String = {
            if front.indent == 0 { return front.body }
            let pad = String(repeating: " ", count: front.indent)
            return front.body.components(separatedBy: "\n").map { line in
                line.hasPrefix(pad) ? String(line.dropFirst(front.indent)) : line
            }.joined(separator: "\n")
        }()
        let parsed: YamlValue
        do {
            parsed = try parseYaml(body)
        } catch let err as YamlError {
            throw MermaidParserError.syntax(message: "Front matter is not valid YAML. \(err.message)",
                                            line: 1, column: 1, snippet: "")
        }
        if case .object(let obj) = parsed {
            if case .string(let t) = obj["title"] { title = t }
            if case .object(let cfg) = obj["config"] { lunaMerge(&config, cfg) }
            if let display = obj["displayMode"]?.stringValue {
                var gantt = config["gantt"]?.objectValue ?? [:]
                gantt["displayMode"] = .string(display)
                config["gantt"] = .object(gantt)
            }
        }
        var count = 0
        var idx = text.firstIndex(of: "\n")
        let end = text.index(text.startIndex, offsetBy: min(front.length, text.count),
                             limitedBy: text.endIndex) ?? text.endIndex
        while let at = idx, at < end {
            count += 1
            let next = text.index(after: at)
            idx = next < text.endIndex ? text[next...].firstIndex(of: "\n") : nil
        }
        lineOffset = count
        text = String(text[end...])
    }

    text = lunaDirectives(text, config: &config)
    let withComments = text
    return PreprocessedMermaid(text: lunaCleanupComments(text), title: title, config: config,
                               withComments: withComments, lineOffset: lineOffset)
}

// MARK: - Entities

private let entityOpen = "\u{FB}\u{B0}"
private let entityClose = "\u{B6}\u{DF}"

// Does what Mermaid's `text.replace(/keyword.*:\S*#.*;/g, drop the last character)` does:
// on a line where the keyword is followed by a colon, a color-like `#`, and later a semicolon,
// the last semicolon goes. Mermaid's regex backtracks without bound; this is one pass.
private func lunaDropColorSemicolons(_ text: String, keyword: String) -> String {
    guard text.contains(keyword) else { return text }
    var out = ""
    var last = text.startIndex
    let lineBreaks = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")
    var f = text.range(of: keyword)?.lowerBound
    while let found = f {
        let lineEnd: String.Index = {
            if let idx = text[found...].firstIndex(where: { $0.unicodeScalars.first.map(lineBreaks.contains) ?? false }) {
                return idx
            }
            return text.endIndex
        }()
        var afterColon = false
        var hash: String.Index?
        var j = text.index(found, offsetBy: keyword.count, limitedBy: text.endIndex) ?? text.endIndex
        while j < lineEnd {
            let c = text[j]
            if c == ":" { afterColon = true }
            else if c == "#" {
                if afterColon { hash = j; break }
            } else if c.isWhitespace { afterColon = false }
            j = text.index(after: j)
        }
        if let h = hash, let semi = text[..<lineEnd].lastIndex(of: ";"), semi > h {
            out += text[last..<semi]
            last = text.index(after: semi)
        }
        f = lineEnd >= text.endIndex ? nil : text[lineEnd...].range(of: keyword)?.lowerBound
    }
    if last == text.startIndex { return text }
    out += text[last...]
    return out
}

// Mermaid hides `#name;` entity codes behind placeholder characters so `#` and `;` survive parsing.
public func encodeEntities(_ text: String) -> String {
    if !text.contains("#") { return text }
    let s = lunaDropColorSemicolons(lunaDropColorSemicolons(text, keyword: "style"), keyword: "classDef")
    guard let re = try? NSRegularExpression(pattern: "#\\w+;", options: []) else { return s }
    let ns = s as NSString
    let full = NSRange(location: 0, length: ns.length)
    var out = ""
    var last = 0
    for m in re.matches(in: s, range: full) {
        let tok = ns.substring(with: m.range)
        let inner = String(tok.dropFirst().dropLast())
        let isInt = !inner.isEmpty && inner.allSatisfy { $0.isNumber }
            && (inner.first!.isNumber || inner.first! == "+")
        let rep = (isInt ? "\u{FB}\u{B0}\u{B0}" : "\u{FB}\u{B0}") + inner + "\u{B6}\u{DF}"
        out += (ns.substring(with: NSRange(location: last, length: m.range.location - last))) + rep
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}

private let entityNamed: [String: String] = {
    var map: [String: String] = [:]
    let raw = "amp:38,lt:60,gt:62,quot:34,apos:39,nbsp:160,iexcl:161,cent:162,pound:163,curren:164,yen:165,sect:167,copy:169,laquo:171,not:172,reg:174,deg:176,plusmn:177,sup2:178,sup3:179,micro:181,para:182,middot:183,sup1:185,raquo:187,frac14:188,frac12:189,frac34:190,iquest:191,times:215,divide:247,ndash:8211,mdash:8212,lsquo:8216,rsquo:8217,sbquo:8218,ldquo:8220,rdquo:8221,bdquo:8222,dagger:8224,Dagger:8225,bull:8226,hellip:8230,permil:8240,prime:8242,Prime:8243,lsaquo:8249,rsaquo:8250,euro:8364,trade:8482,larr:8592,uarr:8593,rarr:8594,darr:8595,harr:8596,lArr:8656,uArr:8657,rArr:8658,dArr:8659,hArr:8660,forall:8704,part:8706,exist:8707,empty:8709,nabla:8711,isin:8712,notin:8713,ni:8715,prod:8719,sum:8721,minus:8722,radic:8730,infin:8734,and:8743,or:8744,cap:8745,cup:8746,int:8747,there4:8756,sim:8764,cong:8773,asymp:8776,ne:8800,equiv:8801,le:8804,ge:8805,sub:8834,sup:8835,sube:8838,supe:8839,oplus:8853,otimes:8855,perp:8869,sdot:8901,loz:9674,spades:9824,clubs:9827,hearts:9829,diams:9830,check:10003,cross:10007,equals:61,colon:58,semi:59,num:35,percnt:37,lpar:40,rpar:41,lbrack:91,rbrack:93,lbrace:123,rbrace:125,vert:124,sol:47,bsol:92,quest:63,excl:33,ast:42,plus:43,comma:44,period:46,dollar:36,commat:64,grave:96,hat:94,lowbar:95,tilde:126,Alpha:913,Beta:914,Gamma:915,Delta:916,Epsilon:917,Zeta:918,Eta:919,Theta:920,Iota:921,Kappa:922,Lambda:923,Mu:924,Nu:925,Xi:926,Omicron:927,Pi:928,Rho:929,Sigma:931,Tau:932,Upsilon:933,Phi:934,Chi:935,Psi:936,Omega:937,alpha:945,beta:946,gamma:947,delta:948,epsilon:949,zeta:950,eta:951,theta:952,iota:953,kappa:954,lambda:955,mu:956,nu:957,xi:958,omicron:959,pi:960,rho:961,sigmaf:962,sigma:963,tau:964,upsilon:965,phi:966,chi:967,psi:968,omega:969"
    for pair in raw.components(separatedBy: ",") {
        if let at = pair.firstIndex(of: ":"),
           let code = UInt32(pair[pair.index(after: at)...]),
           let scalar = Unicode.Scalar(code) {
            map[String(pair[..<at])] = String(scalar)
        }
    }
    return map
}()

private func entityCodePoint(_ n: UInt32, fallback: String) -> String {
    if n > 0 && n <= 0x10FFFF && (n < 0xD800 || n > 0xDFFF),
       let scalar = Unicode.Scalar(n) {
        return String(scalar)
    }
    return fallback
}

// Mermaid's placeholders run from `ﬂ°` to `¶ß`, with a second `°` marking a numeric code.
private func decodePlaceholders(_ text: String) -> String {
    var out = ""
    var last = text.startIndex
    var from = text.range(of: entityOpen)?.lowerBound
    var f = from
    while let at = f {
        guard let stop = text[at...].range(of: "\u{B6}")?.lowerBound,
              text.index(after: stop) < text.endIndex,
              text[text.index(after: stop)] == "\u{DF}" else { break }
        let afterOpen = text.index(at, offsetBy: entityOpen.count,
                                   limitedBy: text.endIndex) ?? text.endIndex
        let numeric = afterOpen < text.endIndex && text[afterOpen] == "\u{B0}"
        let bodyStart = numeric ? text.index(after: afterOpen) : afterOpen
        let body = bodyStart <= stop ? String(text[bodyStart..<stop]) : ""
        let rawEnd = text.index(after: text.index(after: stop))
        let raw = String(text[at..<rawEnd])
        let decoded: String = {
            if numeric { return entityCodePoint(UInt32(body) ?? 0, fallback: raw) }
            return entityNamed[body] ?? "&" + body + ";"
        }()
        out += text[last..<at] + decoded
        last = rawEnd
        f = text[last...].range(of: entityOpen)?.lowerBound
    }
    if last == text.startIndex { return text }
    out += text[last...]
    return out
}

// Turns Mermaid's `#35;` / `#quot;` codes (as hidden by encodeEntities) and HTML entities into characters.
public func decodeEntities(_ text: String) -> String {
    var s = text.contains(entityClose) ? decodePlaceholders(text) : text
    if s.contains("&") {
        guard let re = try? NSRegularExpression(pattern: "&(?:#(\\d+)|#[xX]([0-9a-fA-F]+)|(\\w+));",
                                                options: []) else { return s }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: full) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tok = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                out += entityCodePoint(UInt32(ns.substring(with: m.range(at: 1))) ?? 0, fallback: tok)
            } else if m.range(at: 2).location != NSNotFound {
                out += entityCodePoint(UInt32(ns.substring(with: m.range(at: 2)), radix: 16) ?? 0,
                                       fallback: tok)
            } else {
                out += entityNamed[ns.substring(with: m.range(at: 3))] ?? tok
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        s = out
    }
    return s
}

// MARK: - Limits

/// Input limits, Pele's defaults.
public enum LunaLimits {
    public static let maxSourceLength = 50_000
    public static let maxEdges = 5_000
    public static let maxNesting = 100
    public static let maxSVGLength = 4_000_000
    /// Output bitmap budget: at most 4096x4096 pixels and 16384 on a side.
    public static let maxImagePixels = 16_777_216
    public static let maxImageDimension = 16_384
}

// MARK: - Error location

/// Locates an offset in source the way Pele does: line, 1-based column, and the line with a caret.
public func lunaLocate(src: String, offset: Int) -> (line: Int, column: Int, snippet: String) {
    var line = 1
    var lineStart = src.startIndex
    var idx = src.firstIndex(of: "\n")
    let end = src.index(src.startIndex, offsetBy: min(offset, src.count),
                        limitedBy: src.endIndex) ?? src.endIndex
    while let at = idx, at < end {
        line += 1
        lineStart = src.index(after: at)
        idx = src[lineStart...].firstIndex(of: "\n")
    }
    let lineEnd = src[lineStart...].firstIndex(of: "\n") ?? src.endIndex
    let column = src.distance(from: lineStart, to: min(end, lineEnd)) + 1
    let text = String(src[lineStart..<lineEnd])
    return (line, column, text + "\n" + String(repeating: "-", count: max(0, column - 1)) + "^")
}

