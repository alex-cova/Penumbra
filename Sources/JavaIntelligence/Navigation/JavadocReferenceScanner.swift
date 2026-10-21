import Foundation

/// What the click inside a Javadoc comment refers to, before any index lookup.
struct JavadocReference: Equatable {
    enum Kind: Equatable {
        /// A type, or the leading part of a dotted name up to the clicked segment: `{@link Dog}`,
        /// `@see java.util.List`, `@throws DogException`, the `Dog` of `{@link Dog#speak()}`, or a
        /// parameter type inside `{@link Dog#fetch(Ball, int)}`.
        case type(components: [String])
        /// `{@link Dog#speak()}`, `{@link #speak}`. `owner` is nil for `#member` (the enclosing type).
        case member(owner: [String]?, name: String, parameterTypes: [String]?)
        /// `@param name`
        case parameter(name: String)
        /// `@param <T>`
        case typeParameter(name: String)
    }

    var kind: Kind
}

/// Finds the reference under a click in a `/** ... */` comment. Pure text: the comment is not
/// parsed as Java, so it works on half-written Javadoc too.
enum JavadocReferenceScanner {
    private static let referenceTags: Set<String> = ["@linkplain", "@link", "@see", "@throws", "@exception", "@value"]

    /// - Parameters:
    ///   - comment: the whole comment, including `/**` and `*/`.
    ///   - offset: UTF-8 offset of the click inside `comment`.
    static func reference(in comment: String, atByteOffset offset: Int) -> JavadocReference? {
        let bytes = Array(comment.utf8)
        guard offset >= 0, offset < bytes.count, isWordByte(bytes[offset]) else { return nil }

        var start = offset
        while start > 0, isWordByte(bytes[start - 1]) { start -= 1 }
        var end = offset + 1
        while end < bytes.count, isWordByte(bytes[end]) { end += 1 }
        // A sentence-ending dot belongs to the prose, not the name.
        while end > start + 1, bytes[end - 1] == UInt8(ascii: ".") { end -= 1 }
        guard offset < end else { return nil }
        let word = String(decoding: bytes[start..<end], as: UTF8.self)
        let clicked = offset - start

        if let typeParameter = typeParameter(word, start: start, end: end, in: bytes) {
            return typeParameter
        }
        if insideParameterList(bytes: bytes, tokenStart: start) {
            return typeReference(word, clickedIndex: clicked)
        }
        guard let tag = tag(before: start, in: bytes) else { return nil }
        if tag == "@param" {
            return word.contains(".") || word.contains("#") ? nil : JavadocReference(kind: .parameter(name: word))
        }
        return memberOrType(word, clickedIndex: clicked, bytes: bytes, wordEnd: end)
    }

    // MARK: - Parsing

    /// `@param <T> name`: the `T` sits between `<` and `>`, after the tag.
    private static func typeParameter(_ word: String, start: Int, end: Int, in bytes: [UInt8]) -> JavadocReference? {
        guard start > 0, bytes[start - 1] == UInt8(ascii: "<"), end < bytes.count, bytes[end] == UInt8(ascii: ">"),
              tag(before: start - 1, in: bytes) == "@param" else { return nil }
        return JavadocReference(kind: .typeParameter(name: word))
    }

    private static func memberOrType(_ word: String, clickedIndex: Int, bytes: [UInt8], wordEnd: Int) -> JavadocReference? {
        guard let hash = word.firstIndex(of: "#") else {
            return typeReference(word, clickedIndex: clickedIndex)
        }
        let hashOffset = word.utf8.distance(from: word.utf8.startIndex, to: hash.samePosition(in: word.utf8)!)
        let ownerText = String(word[..<hash])
        let name = String(word[word.index(after: hash)...])
        if clickedIndex < hashOffset {
            return typeReference(ownerText, clickedIndex: clickedIndex)
        }
        guard !name.isEmpty else { return nil }
        let owner = ownerText.isEmpty ? nil : ownerText.split(separator: ".").map(String.init)
        return JavadocReference(kind: .member(
            owner: owner, name: name, parameterTypes: parameterTypes(after: wordEnd, in: bytes)
        ))
    }

    /// The dotted name up to and including the segment the click is in: clicking `util` in
    /// `java.util.List` asks for `java.util`.
    private static func typeReference(_ word: String, clickedIndex: Int) -> JavadocReference? {
        var components: [String] = []
        var position = 0
        for part in word.split(separator: ".", omittingEmptySubsequences: false) {
            let length = part.utf8.count
            if !part.isEmpty { components.append(String(part)) }
            if clickedIndex <= position + length { break }
            position += length + 1
        }
        guard !components.isEmpty, components.last?.first?.isLetter == true || components.last?.first == "_" else { return nil }
        return JavadocReference(kind: .type(components: components))
    }

    /// `(int, List<String>, Ball...)` right after the member name, as simple type names.
    private static func parameterTypes(after end: Int, in bytes: [UInt8]) -> [String]? {
        guard end < bytes.count, bytes[end] == UInt8(ascii: "("),
              let close = bytes[end...].firstIndex(of: UInt8(ascii: ")")) else { return nil }
        let inner = String(decoding: bytes[(end + 1)..<close], as: UTF8.self)
        return splitTopLevel(inner).map(simpleTypeName)
    }

    /// Whether the token sits inside `Owner#member( ... )`.
    private static func insideParameterList(bytes: [UInt8], tokenStart: Int) -> Bool {
        var index = tokenStart - 1
        var angleDepth = 0
        while index >= 0 {
            let byte = bytes[index]
            if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\n") { return false }
            if byte == UInt8(ascii: ">") { angleDepth += 1 }
            if byte == UInt8(ascii: "<") { angleDepth -= 1 }
            if byte == UInt8(ascii: "("), angleDepth <= 0 { break }
            index -= 1
        }
        guard index > 0 else { return false }
        var nameStart = index
        while nameStart > 0, isWordByte(bytes[nameStart - 1]) { nameStart -= 1 }
        return nameStart < index && bytes[nameStart..<index].contains(UInt8(ascii: "#"))
    }

    /// The tag word before the reference, e.g. `{@link `, `@see `, `@throws `.
    private static func tag(before position: Int, in bytes: [UInt8]) -> String? {
        var index = position
        while index > 0, bytes[index - 1] == UInt8(ascii: " ") || bytes[index - 1] == UInt8(ascii: "\t") { index -= 1 }
        guard index < position else { return nil }
        let wordEnd = index
        while index > 0, isTagByte(bytes[index - 1]) { index -= 1 }
        guard index < wordEnd, bytes[index] == UInt8(ascii: "@") else { return nil }
        let tag = String(decoding: bytes[index..<wordEnd], as: UTF8.self)
        return tag == "@param" || referenceTags.contains(tag) ? tag : nil
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "<":
                depth += 1
                current.append(character)
            case ">":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `java.util.List<String>` becomes `List`; `Ball...` becomes `Ball[]`.
    static func simpleTypeName(_ type: String) -> String {
        var name = type
        if let angle = name.firstIndex(of: "<") { name = String(name[..<angle]) }
        var suffix = ""
        if name.hasSuffix("...") {
            name = String(name.dropLast(3))
            suffix = "[]"
        }
        while name.hasSuffix("[]") {
            name = String(name.dropLast(2))
            suffix += "[]"
        }
        let simple = name.split(separator: ".").last.map(String.init) ?? name
        return simple.trimmingCharacters(in: .whitespaces) + suffix
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "#") || byte >= 128
    }

    private static func isTagByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == UInt8(ascii: "@")
    }
}
