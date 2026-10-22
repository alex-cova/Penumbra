import Foundation

/// How much of a server's tool descriptions and schemas to send. A server writes its descriptions for any
/// client and many are paragraphs long; what the model needs to choose and call a tool is the first
/// sentence or two and the parameter names, types and short notes. The full text stays available to
/// the user in Settings (`MCPToolSummary.description`).
public struct ToolTrimming: Sendable, Equatable {
    /// A description is kept to whole sentences up to about this many characters (never less than the
    /// first sentence, never more than three times this).
    public var maxDescription: Int
    /// A parameter's description is cut to this many characters.
    public var maxPropertyDescription: Int
    /// Drops what the model does not need from a schema: `title`, `examples`, `$comment`, `$schema`.
    public var dropsAnnotations: Bool

    public init(maxDescription: Int = 240, maxPropertyDescription: Int = 160, dropsAnnotations: Bool = true) {
        self.maxDescription = maxDescription
        self.maxPropertyDescription = maxPropertyDescription
        self.dropsAnnotations = dropsAnnotations
    }

    /// What Umbra sends.
    public static let standard = ToolTrimming()
    /// Everything the server wrote.
    public static let none = ToolTrimming(maxDescription: .max, maxPropertyDescription: .max, dropsAnnotations: false)

    var isNone: Bool { self == .none }
}

public enum ToolDefinitionTrimmer {
    /// Whitespace collapsed to single spaces, then whole sentences up to `limit` characters.
    public static func trimDescription(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit < Int.max, collapsed.count > limit else { return collapsed }
        var kept = ""
        for sentence in sentences(of: collapsed) {
            let next = kept.isEmpty ? sentence : kept + " " + sentence
            if !kept.isEmpty, next.count > limit { break }
            kept = next
        }
        let hardLimit = limit &* 3
        if kept.count > hardLimit { return String(kept.prefix(hardLimit)).trimmingCharacters(in: .whitespaces) + "…" }
        return kept
    }

    /// A parameter note cut at `limit`, at a word boundary.
    public static func trimNote(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit < Int.max, collapsed.count > limit else { return collapsed }
        // Already cut (the mark is one character past the limit): cutting again would change nothing useful.
        if collapsed.hasSuffix("…"), collapsed.count <= limit + 1 { return collapsed }
        let head = collapsed.prefix(limit)
        // A cut that lands just after a word keeps the word; otherwise the half word goes.
        let atWordEnd = collapsed[collapsed.index(collapsed.startIndex, offsetBy: limit)] == " "
        let cut = atWordEnd ? head : (head.lastIndex(of: " ").map { head[..<$0] } ?? head)
        return String(cut).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    public static func trimSchema(_ schema: JSONValue, _ trimming: ToolTrimming) -> JSONValue {
        guard !trimming.isNone else { return schema }
        return trimNode(schema, trimming, isPropertyMap: false)
    }

    public static func trim(_ info: MCPToolInfo, _ trimming: ToolTrimming) -> MCPToolInfo {
        guard !trimming.isNone else { return info }
        var result = info
        result.description = trimDescription(info.description, limit: trimming.maxDescription)
        result.inputSchema = trimSchema(info.inputSchema, trimming)
        return result
    }

    // MARK: - Internals

    private static let annotationKeys: Set<String> = ["title", "examples", "$comment", "$schema"]

    /// `isPropertyMap`: the node is the `properties` object, whose keys are parameter names (a parameter
    /// called `title` must survive), not schema keywords.
    private static func trimNode(_ node: JSONValue, _ trimming: ToolTrimming, isPropertyMap: Bool) -> JSONValue {
        switch node {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, value) in object {
                if isPropertyMap {
                    result[key] = trimNode(value, trimming, isPropertyMap: false)
                    continue
                }
                if trimming.dropsAnnotations, annotationKeys.contains(key) { continue }
                if key == "description", let text = value.stringValue {
                    result[key] = .string(trimNote(text, limit: trimming.maxPropertyDescription))
                } else if key == "properties" || key == "$defs" || key == "definitions" || key == "patternProperties" {
                    result[key] = trimNode(value, trimming, isPropertyMap: true)
                } else if key == "enum" || key == "const" || key == "required" || key == "default" {
                    result[key] = value
                } else {
                    result[key] = trimNode(value, trimming, isPropertyMap: false)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { trimNode($0, trimming, isPropertyMap: false) })
        default:
            return node
        }
    }

    /// Splits at `.`, `!` or `?` followed by a space, keeping the mark with its sentence. A dot inside
    /// a word (`file.txt`, `e.g.` followed by a lower-case letter) does not end one.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character), index + 1 < characters.count, characters[index + 1] == " " else { continue }
            let following = index + 2 < characters.count ? characters[index + 2] : " "
            let previousWord = current.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
            if ["e.g.", "i.e.", "etc.", "vs."].contains(previousWord) || following.isLowercase { continue }
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }
}
