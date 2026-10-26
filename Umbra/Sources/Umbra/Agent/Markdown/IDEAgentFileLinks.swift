import Foundation

/// Turns project-relative file citations in Markdown prose into links the chat can open.
///
/// A citation is a path with a directory slash and a file extension, optionally followed by
/// `:line`, `:line:column` (javac's form), or `:start-end`. Parentheses the model wrapped around
/// it stay outside the link. Inline code and links the model already wrote are left alone.
/// `exists` is what makes a path a link, so a file the model invented stays ordinary text.
enum IDEAgentFileLinks {
    static let scheme = "umbra-file"

    struct Reference: Equatable, Sendable {
        /// Project-relative, without a leading `./` and without the line suffix.
        var path: String
        /// 1-based. For a `:start-end` range this is the first line.
        var line: Int?
        /// 1-based. Set for `:line:column` only.
        var column: Int?
    }

    /// Rewrites citations `exists` accepts into Markdown links. The visible text does not change.
    static func linkify(_ text: String, exists: (String) -> Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        var didLink = false
        while index < text.endIndex {
            if text[index] == "`" {
                if let end = endOfCodeSpan(in: text, from: index) {
                    result.append(contentsOf: text[index..<end])
                    index = end
                    continue
                }
                result.append(contentsOf: text[index...])
                break
            }
            if text[index] == "!", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex, text[next] == "[",
               let end = endOfMarkdownLink(in: text, from: next) {
                result.append(contentsOf: text[index..<end])
                index = end
                continue
            }
            if text[index] == "[", let end = endOfMarkdownLink(in: text, from: index) {
                result.append(contentsOf: text[index..<end])
                index = end
                continue
            }
            if let match = citation(in: text, at: index), exists(match.reference.path), let destination = url(for: match.reference) {
                result.append("[")
                result.append(escapedLabel(match.label))
                result.append("](")
                result.append(destination.absoluteString)
                result.append(")")
                index = match.end
                didLink = true
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return didLink ? result : text
    }

    static func url(for reference: Reference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: reference.path)]
        if let line = reference.line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column = reference.column { items.append(URLQueryItem(name: "column", value: String(column))) }
        components.queryItems = items
        return components.url
    }

    static func reference(from url: URL) -> Reference? {
        guard url.scheme == scheme else { return nil }
        if let host = url.host, host != "open" { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        return Reference(path: path, line: queryInt(components, name: "line"), column: queryInt(components, name: "column"))
    }

    /// The file `citation` names under `root`. A leading `./` is ignored. When the direct path is
    /// missing and the citation starts with the open folder's name (`perkeo/src/Foo.java` while the
    /// folder open is `perkeo`), that prefix is dropped. Directories, `..`, and anything that would
    /// leave the project are refused.
    static func resolve(_ citation: String, under root: URL) -> URL? {
        let root = root.standardizedFileURL
        let relative = strippingDotSlash(citation)
        if let file = file(relative, under: root) { return file }
        let folder = root.lastPathComponent
        let prefix = folder + "/"
        guard !folder.isEmpty, relative.count > prefix.count,
              relative.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
        else { return nil }
        return file(String(relative.dropFirst(prefix.count)), under: root)
    }

    // MARK: - Scanning

    private struct Match {
        var end: String.Index
        var reference: Reference
        var label: String
    }

    private static func citation(in text: String, at start: String.Index) -> Match? {
        if start > text.startIndex, isPathCharacter(text[text.index(before: start)]) { return nil }
        guard canStartPath(text[start]) else { return nil }
        var end = start
        while end < text.endIndex, isPathCharacter(text[end]) {
            end = text.index(after: end)
        }
        var candidate = end
        while candidate > start {
            let token = String(text[start..<candidate])
            if let parsed = parse(token) {
                return Match(end: candidate, reference: Reference(path: parsed.path, line: parsed.line, column: parsed.column), label: token)
            }
            let previous = text.index(before: candidate)
            guard text[previous] == "." || text[previous] == ":" else { return nil }
            candidate = previous
        }
        return nil
    }

    /// `nil` when `token` is not a citation. A trailing `.` or `:` is the caller's to peel off
    /// (a sentence period, or javac's colon before the message) and try again.
    private static func parse(_ token: String) -> (path: String, line: Int?, column: Int?)? {
        guard let slash = token.lastIndex(of: "/") else { return nil }
        let fileStart = token.index(after: slash)
        let file = token[fileStart...]
        let path: String
        let line: Int?
        let column: Int?
        if let colon = file.firstIndex(of: ":") {
            guard let suffix = parseSuffix(file[file.index(after: colon)...]) else { return nil }
            let colonInToken = token.index(fileStart, offsetBy: file.distance(from: file.startIndex, to: colon))
            path = String(token[..<colonInToken])
            line = suffix.line
            column = suffix.column
        } else {
            path = token
            line = nil
            column = nil
        }
        let relative = strippingDotSlash(path)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        for part in parts where part.isEmpty || part == "." || part == ".." { return nil }
        let name = parts[parts.count - 1]
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return (relative, line, column)
    }

    private static func parseSuffix(_ suffix: Substring) -> (line: Int, column: Int?)? {
        let digits = suffix.prefix(while: \.isNumber)
        guard !digits.isEmpty, let line = Int(digits), line >= 1 else { return nil }
        let rest = suffix[digits.endIndex...]
        if rest.isEmpty { return (line, nil) }
        let separator = rest[rest.startIndex]
        guard separator == "-" || separator == ":" else { return nil }
        let more = rest[rest.index(after: rest.startIndex)...]
        let secondDigits = more.prefix(while: \.isNumber)
        guard !secondDigits.isEmpty, secondDigits.endIndex == more.endIndex, let second = Int(secondDigits), second >= 1 else { return nil }
        return separator == ":" ? (line, second) : (line, nil)
    }

    private static func strippingDotSlash(_ path: String) -> String {
        var relative = path
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        return relative
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        switch character {
        case "/", ".", ":", "_", "-", "+", "@": return true
        default: return false
        }
    }

    private static func canStartPath(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_"
    }

    private static func escapedLabel(_ label: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(label.count)
        for character in label {
            if "\\`*_{}[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func endOfCodeSpan(in text: String, from start: String.Index) -> String.Index? {
        var ticks = 0
        var index = start
        while index < text.endIndex, text[index] == "`" {
            ticks += 1
            index = text.index(after: index)
        }
        var scan = index
        while scan < text.endIndex {
            guard text[scan] == "`" else {
                scan = text.index(after: scan)
                continue
            }
            var run = 0
            var runEnd = scan
            while runEnd < text.endIndex, text[runEnd] == "`" {
                run += 1
                runEnd = text.index(after: runEnd)
            }
            if run >= ticks { return text.index(scan, offsetBy: ticks) }
            scan = runEnd
        }
        return nil
    }

    private static func endOfMarkdownLink(in text: String, from start: String.Index) -> String.Index? {
        guard text[start] == "[" else { return nil }
        var index = text.index(after: start)
        while index < text.endIndex {
            if text[index] == "\\" {
                guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) else { return nil }
                index = next
                continue
            }
            if text[index] == "]" {
                let parenthesis = text.index(after: index)
                guard parenthesis < text.endIndex, text[parenthesis] == "(" else { return nil }
                var depth = 1
                var cursor = text.index(after: parenthesis)
                while cursor < text.endIndex {
                    if text[cursor] == "\\" {
                        guard let next = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex) else { return nil }
                        cursor = next
                        continue
                    }
                    if text[cursor] == "(" { depth += 1 }
                    if text[cursor] == ")" {
                        depth -= 1
                        if depth == 0 { return text.index(after: cursor) }
                    }
                    cursor = text.index(after: cursor)
                }
                return nil
            }
            if text[index] == "\n" { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func queryInt(_ components: URLComponents, name: String) -> Int? {
        guard let raw = components.queryItems?.first(where: { $0.name == name })?.value, let value = Int(raw), value >= 1 else { return nil }
        return value
    }

    private static func file(_ relative: String, under root: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts where part.isEmpty || part == "." || part == ".." { return nil }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }
}
