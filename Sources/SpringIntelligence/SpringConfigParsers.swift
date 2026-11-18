import Foundation

/// One `key = value` of an `application*` file, flattened to a dotted key.
public struct SpringConfigEntry: Hashable, Sendable {
    public struct Segment: Hashable, Sendable { public let name: String; public let range: Range<Int> }
    /// The dotted key as written, with `[n]` list indexes (`spring.datasource.url`, `app.servers[0].host`).
    public let key: String
    public let segments: [Segment]
    public let keyRange: Range<Int>
    public let value: String?
    public let valueRange: Range<Int>?
    /// 0-based line of the key.
    public let line: Int
    /// YAML document number (`---`); always 0 for `.properties`.
    public let document: Int
    /// A flow collection or block scalar: the value cannot be checked or flattened here.
    public let isOpaqueValue: Bool
}

public enum SpringConfigFormat: Sendable { case properties, yaml }

public struct SpringConfigFile: Sendable {
    public let url: URL
    public let format: SpringConfigFormat
    /// From the file name (`application-dev.yml`), or nil for the base file.
    public let fileProfile: String?
    public let entries: [SpringConfigEntry]
    /// Profile a YAML document activates on (`spring.config.activate.on-profile` or legacy `spring.profiles`), by document.
    public let documentProfiles: [Int: String]

    public func profile(of entry: SpringConfigEntry) -> String? { documentProfiles[entry.document] ?? fileProfile }
}

public enum SpringConfigFileName {
    /// `application.yml`, `application-dev.properties`, `bootstrap.yaml`; the profile is the group after `-`.
    public static func parse(_ name: String) -> (format: SpringConfigFormat, profile: String?)? {
        let lower = name.lowercased()
        let formats: [(String, SpringConfigFormat)] = [(".properties", .properties), (".yml", .yaml), (".yaml", .yaml)]
        for (suffix, format) in formats where lower.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            for base in ["application", "bootstrap"] {
                if stem == base { return (format, nil) }
                if stem.hasPrefix(base + "-"), stem.count > base.count + 1 { return (format, String(stem.dropFirst(base.count + 1))) }
            }
        }
        return nil
    }
}

enum SpringConfigParser {
    static func parse(url: URL, text: String) -> SpringConfigFile? {
        guard let (format, profile) = SpringConfigFileName.parse(url.lastPathComponent) else { return nil }
        let (entries, docs) = format == .properties ? parseProperties(text) : parseYAML(text)
        return SpringConfigFile(url: url, format: format, fileProfile: profile, entries: entries, documentProfiles: docs)
    }

    // MARK: Lines with byte offsets

    private struct Line { let text: Substring; let start: Int }   // start: UTF-8 byte offset

    private static func lines(_ text: String) -> [Line] {
        var out: [Line] = []
        var offset = 0
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(Line(text: sub, start: offset))
            offset += sub.utf8.count + 1
        }
        return out
    }

    private static func segments(of key: String, at start: Int) -> [SpringConfigEntry.Segment] {
        var result: [SpringConfigEntry.Segment] = []
        var cursor = start, current = "", currentStart = start, depth = 0
        for ch in key {
            if ch == "[" { depth += 1 } else if ch == "]" { depth = max(0, depth - 1) }
            if ch == ".", depth == 0 {
                result.append(.init(name: current, range: currentStart..<cursor))
                current = ""; currentStart = cursor + 1
            } else { current.append(ch) }
            cursor += String(ch).utf8.count
        }
        result.append(.init(name: current, range: currentStart..<cursor))
        return result
    }

    // MARK: .properties

    static func parseProperties(_ text: String) -> ([SpringConfigEntry], [Int: String]) {
        var entries: [SpringConfigEntry] = []
        let all = lines(text)
        var i = 0
        while i < all.count {
            let line = all[i]
            let trimmed = line.text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{0C}" })
            let lead = line.text.utf8.count - trimmed.utf8.count
            guard let first = trimmed.first, first != "#", first != "!" else { i += 1; continue }
            // Key ends at the first unescaped `=`, `:` or whitespace.
            var key = "", idx = trimmed.startIndex, escaped = false
            while idx < trimmed.endIndex {
                let ch = trimmed[idx]
                if escaped { key.append(ch); escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "=" || ch == ":" || ch == " " || ch == "\t" { break }
                else { key.append(ch) }
                idx = trimmed.index(after: idx)
            }
            let keyStart = line.start + lead
            let keyEnd = keyStart + key.utf8.count
            var rest = trimmed[idx...]
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if let c = rest.first, c == "=" || c == ":" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
            var value = String(rest)
            let valueStart = line.start + (line.text.utf8.count - rest.utf8.count)
            var valueEnd = valueStart + value.utf8.count
            // Backslash continuation: following lines belong to the value.
            while value.hasSuffix("\\"), !value.hasSuffix("\\\\"), i + 1 < all.count {
                value.removeLast()
                i += 1
                let next = all[i].text.drop(while: { $0 == " " || $0 == "\t" })
                value += next
                valueEnd = all[i].start + all[i].text.utf8.count
            }
            let trimmedValue = value.trimmingCharacters(in: .whitespaces)
            entries.append(SpringConfigEntry(
                key: key, segments: segments(of: key, at: keyStart), keyRange: keyStart..<keyEnd,
                value: trimmedValue, valueRange: valueStart..<max(valueStart, valueEnd), line: min(i, all.count - 1),
                document: 0, isOpaqueValue: false))
            i += 1
        }
        return (entries, [:])
    }

    // MARK: YAML (block mappings, scalar sequences, `---` documents, comments, quoted scalars)
    //
    // Deliberately a subset: anchors/aliases, tags, flow mappings and block scalars are recorded as opaque
    // values and never flattened or type-checked. That covers application configuration as written in practice.

    private struct Frame { let indent: Int; let path: String; let pathSegments: [SpringConfigEntry.Segment]; let isItem: Bool }

    static func parseYAML(_ text: String) -> ([SpringConfigEntry], [Int: String]) {
        var entries: [SpringConfigEntry] = []
        var documentProfiles: [Int: String] = [:]
        var stack: [Frame] = []
        var itemCounts: [String: Int] = [:]
        var document = 0
        var skipIndentAbove: Int?
        let all = lines(text)

        func emit(path: String, segs: [SpringConfigEntry.Segment], ownFrom: Int, value: Substring?, valueStart: Int, line: Int, opaque: Bool) {
            guard let last = segs.last else { return }
            let first = segs[min(max(ownFrom, 0), segs.count - 1)]   // segments written on this line, not inherited parents
            var scalar = value.map { String($0) }
            var vr: Range<Int>?
            if let v = value {
                var t = v
                var lo = valueStart
                if let q = t.first, q == "\"" || q == "'", t.count >= 2, t.last == q { t = t.dropFirst().dropLast(); lo += 1 }
                scalar = String(t)
                vr = lo..<(lo + t.utf8.count)
            }
            entries.append(SpringConfigEntry(
                key: path, segments: segs, keyRange: first.range.lowerBound..<last.range.upperBound, value: scalar,
                valueRange: vr, line: line, document: document, isOpaqueValue: opaque))
            if path == "spring.config.activate.on-profile" || path == "spring.profiles", let s = scalar, !s.isEmpty {
                documentProfiles[document] = s
            }
        }

        for (lineNumber, line) in all.enumerated() {
            let raw = line.text
            let body = raw.drop(while: { $0 == " " })
            let indent = raw.utf8.count - body.utf8.count
            if body.isEmpty || body.first == "#" { continue }
            if let limit = skipIndentAbove { if indent > limit { continue } else { skipIndentAbove = nil } }
            if raw.hasPrefix("---") { document += 1; stack = []; itemCounts = [:]; continue }
            if raw.hasPrefix("...") || raw.hasPrefix("%") { continue }

            var content = body
            var contentIndent = indent
            var item = false
            if content.hasPrefix("- ") || content == "-" {
                item = true
                while stack.last.map({ $0.indent > indent }) == true { stack.removeLast() }
                if let top = stack.last, top.isItem, top.indent == indent { stack.removeLast() }
                content = content.dropFirst(1).drop(while: { $0 == " " })
                contentIndent = raw.utf8.count - content.utf8.count
            } else {
                while stack.last.map({ $0.indent >= indent }) == true { stack.removeLast() }
            }
            let parent = stack.last
            let contentStart = line.start + contentIndent

            // Split `key: value` at the first `:` followed by space or end (outside quotes).
            func splitKey(_ s: Substring) -> (key: Substring, rest: Substring?)? {
                var quote: Character?
                var idx = s.startIndex
                while idx < s.endIndex {
                    let ch = s[idx]
                    if let q = quote { if ch == q { quote = nil } }
                    else if ch == "\"" || ch == "'" { if idx == s.startIndex { quote = ch } }
                    else if ch == ":" {
                        let next = s.index(after: idx)
                        if next == s.endIndex { return (s[s.startIndex..<idx], nil) }
                        if s[next] == " " { return (s[s.startIndex..<idx], s[next...].drop(while: { $0 == " " })) }
                    } else if ch == "#", idx != s.startIndex, s[s.index(before: idx)] == " " { return nil }
                    idx = s.index(after: idx)
                }
                return nil
            }

            func stripComment(_ s: Substring) -> Substring {
                var quote: Character?
                var idx = s.startIndex
                while idx < s.endIndex {
                    let ch = s[idx]
                    if let q = quote { if ch == q { quote = nil } }
                    else if ch == "\"" || ch == "'" { quote = ch }
                    else if ch == "#", idx == s.startIndex || s[s.index(before: idx)] == " " {
                        return s[s.startIndex..<idx].reversed().drop(while: { $0 == " " }).reversed().reduce(into: Substring()) { $0.append($1) }
                    }
                    idx = s.index(after: idx)
                }
                return s
            }

            if let (keySub, restSub) = splitKey(content) {
                var keyText = String(keySub)
                if let q = keyText.first, q == "\"" || q == "'", keyText.last == q, keyText.count >= 2 { keyText = String(keyText.dropFirst().dropLast()) }
                var pathSegs = parent?.pathSegments ?? []
                var path = parent?.path ?? ""
                if item {
                    // `- key: value` is a new element of the parent list.
                    let n = itemCounts[path, default: 0]
                    itemCounts[path] = n + 1
                    if var last = pathSegs.popLast() {
                        last = .init(name: last.name + "[\(n)]", range: last.range)
                        pathSegs.append(last)
                        path += "[\(n)]"
                    }
                }
                let itemPath = path, itemSegs = pathSegs   // the `app.servers[0]` part, before this line's own key
                let ownFrom = pathSegs.count - (item ? 1 : 0)
                let keyByteStart = contentStart
                let keyRangeEnd = keyByteStart + keySub.utf8.count
                for part in segments(of: keyText, at: keyByteStart + (keySub.first == "\"" || keySub.first == "'" ? 1 : 0)) {
                    pathSegs.append(part)
                    path += (path.isEmpty ? "" : ".") + part.name
                }
                _ = keyRangeEnd
                let value = restSub.map(stripComment)
                if let v = value, !v.isEmpty {
                    let vStart = line.start + (raw.utf8.count - restSub!.utf8.count)
                    let opaque = v.hasPrefix("|") || v.hasPrefix(">") || v.hasPrefix("{") || v.hasPrefix("[") || v.hasPrefix("&") || v.hasPrefix("*") || v.hasPrefix("!")
                    emit(path: path, segs: pathSegs, ownFrom: ownFrom, value: v, valueStart: vStart, line: lineNumber, opaque: opaque)
                    if v.hasPrefix("|") || v.hasPrefix(">") { skipIndentAbove = item ? contentIndent : indent }
                    if item { stack.append(Frame(indent: indent, path: itemPath, pathSegments: itemSegs, isItem: true)) }
                } else {
                    if item { stack.append(Frame(indent: indent, path: itemPath, pathSegments: itemSegs, isItem: true)) }
                    stack.append(Frame(indent: item ? contentIndent : indent, path: path, pathSegments: pathSegs, isItem: false))
                }
            } else if item, let parent {
                // `- scalar`
                let n = itemCounts[parent.path, default: 0]
                itemCounts[parent.path] = n + 1
                var segs = parent.pathSegments
                if let last = segs.popLast() {
                    segs.append(.init(name: last.name + "[\(n)]", range: last.range))
                    let v = stripComment(content)
                    let vStart = contentStart
                    emit(path: parent.path + "[\(n)]", segs: segs, ownFrom: segs.count - 1, value: v, valueStart: vStart, line: lineNumber, opaque: false)
                }
            }
        }
        return (entries, documentProfiles)
    }
}
