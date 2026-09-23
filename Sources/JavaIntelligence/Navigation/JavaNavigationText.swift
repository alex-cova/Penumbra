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
        let ns = text as NSString
        let clamped = max(0, min(utf16Offset, ns.length))
        let prefix = ns.substring(with: NSRange(location: 0, length: clamped))
        return prefix.utf8.count
    }

    static func textRange(for byteRange: Range<Int>, in source: String) -> EditorIntelligence.TextRange {
        let start = utf16Offset(forByte: byteRange.lowerBound, in: source)
        let end = utf16Offset(forByte: byteRange.upperBound, in: source)
        return EditorIntelligence.TextRange(start: position(utf16Offset: start, in: source), end: position(utf16Offset: end, in: source))
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
        let ns = source as NSString
        let clamped = max(0, min(utf16Offset, ns.length))
        var line = 0
        var column = 0
        var index = 0
        while index < clamped {
            let unit = ns.character(at: index)
            if unit == 10 {
                line += 1
                column = 0
            } else if unit == 13 {
                line += 1
                column = 0
                if index + 1 < clamped && ns.character(at: index + 1) == 10 {
                    index += 1
                }
            } else {
                column += 1
            }
            index += 1
        }
        return EditorIntelligence.TextPosition(line: line, column: column, utf16Offset: clamped)
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

    private static func simple(_ dotted: String) -> String {
        String(dotted.split(separator: ".").last ?? Substring(dotted))
    }
}
