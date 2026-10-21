import EditorIntelligence
import Foundation

enum JavaNavigationText {
    static func fullText(of document: Document) -> String {
        if let text = document.contentSnapshot.text {
            return text
        }
        let length = document.contentSnapshot.utf16Length
        guard length > 0 else { return "" }
        return document.substring(utf16Offset: 0, length: length)
    }

    static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    static func utf8ByteOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        let utf16 = text.utf16
        let clamped = max(0, min(utf16Offset, utf16.count))
        let index = utf16.index(utf16.startIndex, offsetBy: clamped)
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    /// Both ends in one pass over the bytes, instead of one scan from the start per end.
    static func textRange(for byteRange: Range<Int>, in source: String) -> EditorIntelligence.TextRange {
        var source = source
        return source.withUTF8 { bytes in
            let lower = max(0, min(byteRange.lowerBound, bytes.count))
            let upper = max(lower, min(byteRange.upperBound, bytes.count))
            var scan = LineScan()
            scan.advance(bytes, toByte: lower)
            let start = scan.position
            scan.advance(bytes, toByte: upper)
            return EditorIntelligence.TextRange(start: start, end: scan.position)
        }
    }

    static func utf16Offset(forByte byteOffset: Int, in source: String) -> Int {
        let utf8 = source.utf8
        let clamped = max(0, min(byteOffset, utf8.count))
        guard let byteIndex = utf8.index(utf8.startIndex, offsetBy: clamped, limitedBy: utf8.endIndex),
              let stringIndex = byteIndex.samePosition(in: source),
              let utf16Index = stringIndex.samePosition(in: source.utf16) else {
            return (source as NSString).length
        }
        return source.utf16.distance(from: source.utf16.startIndex, to: utf16Index)
    }

    /// Line and column are what ``TextView/location(at:)`` turns back into a caret, so they have
    /// to count the same UTF-16 units the line manager does, including `\r\n` as one break.
    static func position(utf16Offset: Int, in source: String) -> EditorIntelligence.TextPosition {
        var source = source
        return source.withUTF8 { bytes in
            var scan = LineScan()
            scan.advance(bytes, toUTF16: max(0, utf16Offset))
            return scan.position
        }
    }
}

/// A walk over UTF-8 bytes that tracks the line, the column in UTF-16 units and the UTF-16 offset.
/// The text is read as bytes because `NSString.character(at:)` per unit costs far more than the
/// comparison it feeds, and a click near the end of a large file used to scan all of it that way.
private struct LineScan {
    private var byteIndex = 0
    private var line = 0
    private var column = 0
    private var utf16 = 0
    private var afterCarriageReturn = false

    var position: EditorIntelligence.TextPosition {
        EditorIntelligence.TextPosition(line: line, column: column, utf16Offset: utf16)
    }

    mutating func advance(_ bytes: UnsafeBufferPointer<UInt8>, toByte target: Int) {
        while byteIndex < target, byteIndex < bytes.count {
            step(bytes[byteIndex])
            byteIndex += 1
        }
    }

    /// Stops after the unit that reaches `target`, or at the end of the text.
    mutating func advance(_ bytes: UnsafeBufferPointer<UInt8>, toUTF16 target: Int) {
        while utf16 < target, byteIndex < bytes.count {
            let byte = bytes[byteIndex]
            if byte >= 0xF0, utf16 + 2 > target {
                // The offset is between the halves of a surrogate pair: count the first.
                column += 1
                utf16 += 1
                return
            }
            step(byte)
            byteIndex += 1
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch byte {
        case 10:
            if !afterCarriageReturn { line += 1 }
            column = 0
            utf16 += 1
            afterCarriageReturn = false
        case 13:
            line += 1
            column = 0
            utf16 += 1
            afterCarriageReturn = true
        case 0x80 ..< 0xC0:
            break
        case 0xF0...:
            column += 2
            utf16 += 2
            afterCarriageReturn = false
        default:
            column += 1
            utf16 += 1
            afterCarriageReturn = false
        }
    }
}

/// Simple-name key used to tell `foo(String)` from `foo(int)` without full overload resolution.
enum JavaTypeKeys {
    static func parameterKey(_ type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let primitive):
            return primitive.rawValue
        case .void:
            return "void"
        case .array(let element):
            return parameterKey(element) + "[]"
        case .typeVariable, .wildcard:
            return "Object"
        case .classType(let qualifiedName, _, _):
            return simple(qualifiedName)
        case .unresolved(let simpleName, _):
            return simple(simpleName)
        }
    }

    static func keys(of method: JavaMethodStub) -> [String] {
        method.parameters.map { parameterKey($0.type) }
    }

    static func keys(of method: SyntaxNode) -> [String] {
        guard let parameters = method.child(byFieldName: "parameters") else { return [] }
        return parameters.namedChildren.compactMap { parameter in
            guard parameter.type == "formal_parameter" || parameter.type == "spread_parameter" else { return nil }
            guard let typeNode = parameter.child(byFieldName: "type")
                    ?? parameter.namedChildren.first(where: { $0.type != "modifiers" && $0.type != "variable_declarator" }) else { return nil }
            var key = simpleTypeKey(from: typeNode.text)
            key += String(repeating: "[]", count: typeNode.text.components(separatedBy: "[]").count - 1)
            if parameter.type == "spread_parameter" { key += "[]" }
            return key
        }
    }

    private static func simpleTypeKey(from text: String) -> String {
        var depth = 0
        var plain = ""
        for character in text {
            if character == "<" { depth += 1 } else if character == ">" { depth -= 1 } else if depth == 0 { plain.append(character) }
        }
        let parts = plain.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let last = parts.last { return simple(String(last)) }
        return simple(plain)
    }

    private static func simple(_ dotted: String) -> String {
        String(dotted.split(separator: ".").last ?? Substring(dotted))
    }
}
