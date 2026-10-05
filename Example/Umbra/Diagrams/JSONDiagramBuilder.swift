import Foundation

/// A JSON buffer turned into boxes and parent-to-child edges. Object keys stay in source order.
nonisolated struct JSONDiagramBuild: Sendable, Equatable {
    var document: IDEDiagramDocument
    var notice: String?
    var failure: String?
}

/// Reads one JSON value and builds a diagram of it. Parsing keeps going after the box cap so a
/// huge file is still checked, but only the first ``maximumNodes`` values become boxes.
nonisolated enum JSONDiagramBuilder {
    static let maximumNodes = 400
    /// Decoded characters kept on a string box before an ellipsis.
    static let maximumValueLength = 80
    fileprivate static let maximumDepth = 512

    static func build(text: String, title: String) -> JSONDiagramBuild {
        var parser = Parser(text: text, title: title)
        return parser.build()
    }

    /// `$`, `$.user`, `$.tags[0]`. A key that is not a plain identifier is quoted so it cannot
    /// collide with a real path (`a` / `b` versus the key `a.b`).
    static func path(parent: String, key: String) -> String {
        let plain = key.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57) || value == 95
        }
        if plain, !key.isEmpty {
            return parent + "." + key
        }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return parent + "[\"" + escaped + "\"]"
    }

    static func path(parent: String, index: Int) -> String {
        parent + "[\(index)]"
    }
}

private struct JSONDiagramParser {
    var scalars: String.UnicodeScalarView
    var index: String.UnicodeScalarView.Index
    var line = 1
    var column = 1
    var nodes: [IDEDiagramNode] = []
    var edges: [IDEDiagramEdge] = []
    var omitted = 0
    let title: String

    init(text: String, title: String) {
        scalars = text.unicodeScalars
        index = scalars.startIndex
        self.title = title
    }

    mutating func build() -> JSONDiagramBuild {
        if scalars.first == "\u{feff}" { advance() }
        skipWhitespace()
        guard index != scalars.endIndex else {
            return failed("This file is empty.")
        }
        do {
            try parseValue(path: "$", title: title, parentID: nil, depth: 0)
            skipWhitespace()
            if index != scalars.endIndex {
                throw parseError("Unexpected extra content")
            }
        } catch let error as JSONDiagramParseError {
            return failed(error.message)
        } catch {
            return failed("Invalid JSON")
        }
        let notice = omitted > 0
            ? "Showing \(nodes.count) values; \(omitted) more omitted."
            : nil
        return JSONDiagramBuild(
            document: IDEDiagramDocument(
                meta: .init(title: title),
                canvas: IDEDiagramDocument.defaultCanvas,
                nodes: nodes,
                edges: edges
            ),
            notice: notice,
            failure: nil
        )
    }

    private func failed(_ message: String) -> JSONDiagramBuild {
        JSONDiagramBuild(
            document: IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas),
            notice: nil,
            failure: message
        )
    }

    // MARK: - Values

    private mutating func parseValue(path: String, title: String, parentID: UUID?, depth: Int) throws {
        if depth > JSONDiagramBuilder.maximumDepth {
            throw parseError("JSON is nested too deeply")
        }
        skipWhitespace()
        if nodes.count >= JSONDiagramBuilder.maximumNodes {
            omitted += try skipValue()
            return
        }
        guard index != scalars.endIndex else { throw parseError("Unexpected end of JSON") }
        switch scalars[index] {
        case "{":
            try parseObject(path: path, title: title, parentID: parentID, depth: depth)
        case "[":
            try parseArray(path: path, title: title, parentID: parentID, depth: depth)
        case "\"":
            let value = try parseString()
            addValue(path: path, title: title, subtitle: Self.display(value), parentID: parentID)
        case "t":
            try consumeLiteral("true")
            addValue(path: path, title: title, subtitle: "true", parentID: parentID)
        case "f":
            try consumeLiteral("false")
            addValue(path: path, title: title, subtitle: "false", parentID: parentID)
        case "n":
            try consumeLiteral("null")
            addValue(path: path, title: title, subtitle: "null", parentID: parentID)
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            let lexeme = try parseNumber()
            addValue(path: path, title: title, subtitle: lexeme, parentID: parentID)
        default:
            throw parseError("Expected a value")
        }
    }

    private mutating func parseObject(path: String, title: String, parentID: UUID?, depth: Int) throws {
        try consume("{")
        let id = addNode(path: path, title: title, subtitle: "object · 0", kind: .jsonObject, parentID: parentID)
        skipWhitespace()
        var count = 0
        var seen: Set<String> = []
        if !consumeIf("}") {
            while true {
                skipWhitespace()
                guard index != scalars.endIndex, scalars[index] == "\"" else {
                    throw parseError("Expected an object key")
                }
                let key = try parseString()
                skipWhitespace()
                try consume(":")
                let childPath = JSONDiagramBuilder.path(parent: path, key: key)
                if seen.insert(childPath).inserted == false {
                    removeSubtree(path: childPath)
                } else {
                    count += 1
                }
                try parseValue(path: childPath, title: key, parentID: id, depth: depth + 1)
                skipWhitespace()
                if consumeIf("}") { break }
                try consume(",")
            }
        }
        setSubtitle(path: path, subtitle: "object · \(count)", kind: .jsonObject, title: title)
    }

    private mutating func parseArray(path: String, title: String, parentID: UUID?, depth: Int) throws {
        try consume("[")
        let id = addNode(path: path, title: title, subtitle: "array · 0", kind: .jsonArray, parentID: parentID)
        skipWhitespace()
        var count = 0
        if !consumeIf("]") {
            while true {
                let childPath = JSONDiagramBuilder.path(parent: path, index: count)
                count += 1
                try parseValue(path: childPath, title: "[\(count - 1)]", parentID: id, depth: depth + 1)
                skipWhitespace()
                if consumeIf("]") { break }
                try consume(",")
            }
        }
        setSubtitle(path: path, subtitle: "array · \(count)", kind: .jsonArray, title: title)
    }

    private mutating func addValue(path: String, title: String, subtitle: String, parentID: UUID?) {
        _ = addNode(path: path, title: title, subtitle: subtitle, kind: .jsonValue, parentID: parentID)
    }

    /// `nil` when this call is past the cap. The caller has already counted the omission.
    @discardableResult
    private mutating func addNode(
        path: String,
        title: String,
        subtitle: String,
        kind: IDEDiagramNodeKind,
        parentID: UUID?
    ) -> UUID? {
        guard nodes.count < JSONDiagramBuilder.maximumNodes else { return nil }
        let node = IDEDiagramNode(key: path, kind: kind, title: title, subtitle: subtitle)
        nodes.append(node)
        if let parentID {
            edges.append(IDEDiagramEdge(sourceID: parentID, destinationID: node.id, kind: .containment))
        }
        return node.id
    }

    private mutating func setSubtitle(path: String, subtitle: String, kind: IDEDiagramNodeKind, title: String) {
        guard let index = nodes.firstIndex(where: { $0.key == path }) else { return }
        nodes[index].subtitle = subtitle
        nodes[index].frame.size = IDEDiagramNodeMetrics.size(
            title: title, subtitle: subtitle, attributes: [], methods: [], kind: kind
        )
    }

    /// Drops a value that a later duplicate key replaces, including everything under it.
    private mutating func removeSubtree(path: String) {
        let doomed = Set(nodes.compactMap { node -> UUID? in
            if node.key == path || node.key.hasPrefix(path + ".") || node.key.hasPrefix(path + "[") {
                return node.id
            }
            return nil
        })
        guard !doomed.isEmpty else { return }
        nodes.removeAll { doomed.contains($0.id) }
        edges.removeAll { doomed.contains($0.sourceID) || doomed.contains($0.destinationID) }
    }

    // MARK: - Skipping

    private mutating func skipValue() throws -> Int {
        skipWhitespace()
        guard index != scalars.endIndex else { throw parseError("Unexpected end of JSON") }
        switch scalars[index] {
        case "{":
            try consume("{")
            var count = 1
            skipWhitespace()
            if !consumeIf("}") {
                while true {
                    skipWhitespace()
                    guard index != scalars.endIndex, scalars[index] == "\"" else {
                        throw parseError("Expected an object key")
                    }
                    _ = try parseString()
                    skipWhitespace()
                    try consume(":")
                    count += try skipValue()
                    skipWhitespace()
                    if consumeIf("}") { break }
                    try consume(",")
                }
            }
            return count
        case "[":
            try consume("[")
            var count = 1
            skipWhitespace()
            if !consumeIf("]") {
                while true {
                    count += try skipValue()
                    skipWhitespace()
                    if consumeIf("]") { break }
                    try consume(",")
                }
            }
            return count
        case "\"":
            _ = try parseString()
            return 1
        case "t":
            try consumeLiteral("true")
            return 1
        case "f":
            try consumeLiteral("false")
            return 1
        case "n":
            try consumeLiteral("null")
            return 1
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            _ = try parseNumber()
            return 1
        default:
            throw parseError("Expected a value")
        }
    }

    // MARK: - Lexemes

    private mutating func parseString() throws -> String {
        try consume("\"")
        var result = String.UnicodeScalarView()
        while index != scalars.endIndex {
            let scalar = scalars[index]
            advance()
            if scalar == "\"" { return String(result) }
            if scalar == "\\" {
                result.append(contentsOf: try parseEscape().unicodeScalars)
                continue
            }
            if scalar.value < 0x20 { throw parseError("Unescaped control character in string") }
            result.append(scalar)
        }
        throw parseError("Unterminated string")
    }

    private mutating func parseEscape() throws -> String {
        guard index != scalars.endIndex else { throw parseError("Unterminated string") }
        let scalar = scalars[index]
        advance()
        switch scalar {
        case "\"", "\\", "/": return String(scalar)
        case "b": return "\u{08}"
        case "f": return "\u{0c}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u":
            let unit = try parseHex4()
            if UTF16.isLeadSurrogate(unit) {
                guard consumeIf("\\"), consumeIf("u") else { throw parseError("Invalid surrogate pair") }
                let low = try parseHex4()
                guard UTF16.isTrailSurrogate(low) else { throw parseError("Invalid surrogate pair") }
                return String(decoding: [unit, low], as: UTF16.self)
            }
            guard let decoded = Unicode.Scalar(unit) else { throw parseError("Invalid unicode escape") }
            return String(decoded)
        default:
            throw parseError("Invalid escape")
        }
    }

    private mutating func parseHex4() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard index != scalars.endIndex else { throw parseError("Invalid unicode escape") }
            let scalar = scalars[index]
            guard let digit = hex(scalar) else { throw parseError("Invalid unicode escape") }
            advance()
            value = value << 4 | digit
        }
        return value
    }

    private func hex(_ scalar: Unicode.Scalar) -> UInt16? {
        switch scalar {
        case "0"..."9": return UInt16(scalar.value - 48)
        case "a"..."f": return UInt16(scalar.value - 87)
        case "A"..."F": return UInt16(scalar.value - 55)
        default: return nil
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        let startLine = line
        let startColumn = column
        if consumeIf("-"), index == scalars.endIndex { throw parseError("Invalid number") }
        guard index != scalars.endIndex else { throw parseError("Invalid number") }
        if scalars[index] == "0" {
            advance()
        } else if scalars[index] >= "1", scalars[index] <= "9" {
            while index != scalars.endIndex, scalars[index] >= "0", scalars[index] <= "9" { advance() }
        } else {
            throw positioned("Invalid number", line: startLine, column: startColumn)
        }
        if consumeIf(".") {
            guard index != scalars.endIndex, scalars[index] >= "0", scalars[index] <= "9" else {
                throw parseError("Invalid number")
            }
            while index != scalars.endIndex, scalars[index] >= "0", scalars[index] <= "9" { advance() }
        }
        if index != scalars.endIndex, scalars[index] == "e" || scalars[index] == "E" {
            advance()
            if index != scalars.endIndex, scalars[index] == "+" || scalars[index] == "-" { advance() }
            guard index != scalars.endIndex, scalars[index] >= "0", scalars[index] <= "9" else {
                throw parseError("Invalid number")
            }
            while index != scalars.endIndex, scalars[index] >= "0", scalars[index] <= "9" { advance() }
        }
        return String(scalars[start..<index])
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard index != scalars.endIndex, scalars[index] == scalar else {
                throw parseError("Expected a value")
            }
            advance()
        }
    }

    private static func display(_ value: String) -> String {
        var shown = ""
        var count = 0
        var truncated = false
        for character in value {
            if count >= JSONDiagramBuilder.maximumValueLength {
                truncated = true
                break
            }
            switch character {
            case "\n": shown += "\\n"
            case "\r": shown += "\\r"
            case "\t": shown += "\\t"
            case "\"": shown += "\\\""
            case "\\": shown += "\\\\"
            default: shown.append(character)
            }
            count += 1
        }
        if truncated { shown += "…" }
        return "\"\(shown)\""
    }

    // MARK: - Cursor

    private mutating func consume(_ expected: Unicode.Scalar) throws {
        skipWhitespace()
        guard index != scalars.endIndex, scalars[index] == expected else {
            throw parseError("Expected '\(Character(expected))'")
        }
        advance()
    }

    private mutating func consumeIf(_ expected: Unicode.Scalar) -> Bool {
        guard index != scalars.endIndex, scalars[index] == expected else { return false }
        advance()
        return true
    }

    private mutating func skipWhitespace() {
        while index != scalars.endIndex {
            switch scalars[index] {
            case " ", "\t", "\n", "\r": advance()
            default: return
            }
        }
    }

    private mutating func advance() {
        let scalar = scalars[index]
        index = scalars.index(after: index)
        if scalar == "\n" || scalar == "\r" {
            if scalar == "\r", index != scalars.endIndex, scalars[index] == "\n" {
                index = scalars.index(after: index)
            }
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private func parseError(_ reason: String) -> JSONDiagramParseError {
        positioned(reason, line: line, column: column)
    }

    private func positioned(_ reason: String, line: Int, column: Int) -> JSONDiagramParseError {
        JSONDiagramParseError(message: "Invalid JSON at line \(line), column \(column): \(reason)")
    }
}

private typealias Parser = JSONDiagramParser

private struct JSONDiagramParseError: Error {
    var message: String
}
