import EditorIntelligence
import Foundation

/// The members of the standard-library types a Swift file meets most, written out by hand.
///
/// The index only knows project sources, so without this `name.` on a `String` or `items.` on an
/// array would offer nothing and a chain through one could never be typed. This is not the
/// library: it is the few dozen members that decide whether completion feels broken. `E`, `K`
/// and `V` in a return type are replaced by the receiver's element, key and value types.
public enum SwiftStandardLibrary {
    public struct Member: Sendable {
        public enum Kind: Sendable { case property, method }

        public var name: String
        public var kind: Kind
        /// What the member is declared as, for the completion detail and hover.
        public var signature: String
        /// The type a property has or a method returns; `nil` for `Void` or unknown.
        public var returns: String?
        /// Text inserted, with a snippet placeholder per argument. Equal to `name` for a property.
        public var insertText: String
        public var isSnippet: Bool { insertText != name }
    }

    private static func property(_ name: String, _ type: String) -> Member {
        Member(name: name, kind: .property, signature: "var \(name): \(type)", returns: type, insertText: name)
    }

    /// `labels` are the argument labels in order (`"_"` for none): `hasPrefix(_:)`.
    private static func method(_ name: String, _ labels: [String], returns: String?, signature: String? = nil) -> Member {
        let arguments = labels.map { $0 == "_" ? "_:" : "\($0):" }.joined()
        let text: String
        if labels.isEmpty {
            text = "\(name)()"
        } else {
            let placeholders = labels.enumerated().map { index, label in
                label == "_" ? "${\(index + 1):value}" : "\(label): ${\(index + 1):value}"
            }
            text = "\(name)(\(placeholders.joined(separator: ", ")))"
        }
        return Member(
            name: name, kind: .method,
            signature: signature ?? "func \(name)(\(arguments))" + (returns.map { " -> \($0)" } ?? ""),
            returns: returns, insertText: text
        )
    }

    private static let string: [Member] = [
        property("count", "Int"), property("isEmpty", "Bool"), property("first", "Character?"),
        property("last", "Character?"), property("description", "String"), property("utf8", "String.UTF8View"),
        method("uppercased", [], returns: "String"), method("lowercased", [], returns: "String"),
        method("hasPrefix", ["_"], returns: "Bool"), method("hasSuffix", ["_"], returns: "Bool"),
        method("contains", ["_"], returns: "Bool"), method("split", ["separator"], returns: "[Substring]"),
        method("trimmingCharacters", ["in"], returns: "String"),
        method("replacingOccurrences", ["of", "with"], returns: "String"),
        method("components", ["separatedBy"], returns: "[String]"),
        method("prefix", ["_"], returns: "Substring"), method("suffix", ["_"], returns: "Substring"),
        method("dropFirst", [], returns: "Substring"), method("dropLast", [], returns: "Substring"),
        method("append", ["_"], returns: nil), method("reversed", [], returns: nil)
    ]

    private static let array: [Member] = [
        property("count", "Int"), property("isEmpty", "Bool"), property("first", "E"), property("last", "E"),
        method("append", ["_"], returns: nil), method("insert", ["_", "at"], returns: nil),
        method("remove", ["at"], returns: "E"), method("removeAll", [], returns: nil),
        method("removeLast", [], returns: "E"), method("popLast", [], returns: "E"),
        method("map", ["_"], returns: nil), method("filter", ["_"], returns: "[E]"),
        method("compactMap", ["_"], returns: nil), method("flatMap", ["_"], returns: nil),
        method("reduce", ["_", "_"], returns: nil), method("forEach", ["_"], returns: nil),
        method("sorted", [], returns: "[E]"), method("sorted", ["by"], returns: "[E]"),
        method("contains", ["_"], returns: "Bool"), method("contains", ["where"], returns: "Bool"),
        method("firstIndex", ["of"], returns: "Int?"), method("first", ["where"], returns: "E"),
        method("reversed", [], returns: nil), method("joined", ["separator"], returns: "String"),
        method("enumerated", [], returns: nil), method("min", [], returns: "E"), method("max", [], returns: "E"),
        method("prefix", ["_"], returns: nil), method("suffix", ["_"], returns: nil),
        method("dropFirst", [], returns: nil), method("dropLast", [], returns: nil),
        method("shuffled", [], returns: "[E]")
    ]

    private static let dictionary: [Member] = [
        property("count", "Int"), property("isEmpty", "Bool"), property("keys", "[K]"), property("values", "[V]"),
        method("removeValue", ["forKey"], returns: "V"), method("updateValue", ["_", "forKey"], returns: "V"),
        method("mapValues", ["_"], returns: nil), method("filter", ["_"], returns: "[K: V]"),
        method("removeAll", [], returns: nil), method("forEach", ["_"], returns: nil),
        method("sorted", ["by"], returns: nil), method("contains", ["where"], returns: "Bool")
    ]

    private static let number: [Member] = [
        property("description", "String"), property("hashValue", "Int"),
        method("isMultiple", ["of"], returns: "Bool"), method("squareRoot", [], returns: "Double"),
        method("rounded", [], returns: "Double"), method("magnitude", [], returns: nil)
    ]

    private static let numericTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat"
    ]

    /// The members for a receiver of `type`, with `E`/`K`/`V` replaced; empty when the type is not
    /// one the table covers.
    public static func members(ofType type: String) -> [Member] {
        let type = SwiftTypeNames.unwrappedOptional(type)
        let table: [Member]
        var element: String?
        var key: String?
        var value: String?
        if type == "String" || type == "Substring" {
            table = string
        } else if type.hasPrefix("["), type.hasSuffix("]") {
            let inner = String(type.dropFirst().dropLast())
            if inner.contains(": ") {
                table = dictionary
                let parts = inner.components(separatedBy: ": ")
                key = parts.first
                value = parts.dropFirst().joined(separator: ": ")
            } else {
                table = array
                element = inner
            }
        } else if type == "Array" || type == "Set" {
            table = array
        } else if type == "Dictionary" {
            table = dictionary
        } else if numericTypes.contains(type) {
            table = number
        } else {
            return []
        }
        return table.map { member in
            var member = member
            member.returns = member.returns.flatMap { substitute($0, element: element, key: key, value: value) }
            member.signature = substituteText(member.signature, element: element, key: key, value: value)
            return member
        }
    }

    public static func memberValue(named name: String, onType type: String) -> SwiftResolver.Value? {
        guard let member = members(ofType: type).first(where: { $0.name == name }) else { return nil }
        switch member.kind {
        case .property:
            return member.returns.map { .instance($0) }
        case .method:
            return .callable(returns: member.returns, receiver: type)
        }
    }

    private static func substitute(_ text: String, element: String?, key: String?, value: String?) -> String? {
        let result = substituteText(text, element: element, key: key, value: value)
        // A placeholder with nothing to put in it makes the type unknown, not `E`.
        if result == "E" || result == "K" || result == "V" || result.contains("[E]") || result.contains("[K") {
            return nil
        }
        return result
    }

    private static func substituteText(_ text: String, element: String?, key: String?, value: String?) -> String {
        var result = text
        if let element { result = replacingToken("E", with: element, in: result) }
        if let key { result = replacingToken("K", with: key, in: result) }
        if let value { result = replacingToken("V", with: value, in: result) }
        return result
    }

    private static func replacingToken(_ token: Character, with replacement: String, in text: String) -> String {
        var output = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : " "
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if character == token, !previous.isLetter, !next.isLetter {
                output += replacement
            } else {
                output.append(character)
            }
        }
        return output
    }
}
