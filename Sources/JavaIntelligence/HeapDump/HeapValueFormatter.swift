import Foundation

/// One-line previews of what an object holds, for the instance list, the inspector and the
/// referrers: `"hello"` for a `String`, `42` for an `Integer`, `RUNNABLE` for an enum constant,
/// `size 12` for a collection, `length 1024` for an array.
enum HeapValueFormatter {
    static let maximumCharacters = 120

    static let boxed: Set<String> = [
        "java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte", "java.lang.Character",
        "java.lang.Boolean", "java.lang.Float", "java.lang.Double",
        "java.util.concurrent.atomic.AtomicInteger", "java.util.concurrent.atomic.AtomicLong",
        "java.util.concurrent.atomic.AtomicBoolean"
    ]

    static func preview(of n: Int32, in index: HeapIndex, depth: Int = 0) -> String? {
        guard n > 0, depth < 3 else { return nil }
        switch index.kind(of: n) {
        case .superRoot:
            return nil
        case .classObject:
            return index.classes[Int(index.classIndex(of: n))].name
        case .objectArray, .primitiveArray:
            if let text = characters(ofArray: n, in: index) { return quoted(text) }
            return "length \(index.length(of: n))"
        case .instance:
            break
        }
        let className = index.className(of: n)
        if className == "java.lang.String" {
            return string(n, in: index).map(quoted)
        }
        if boxed.contains(className), let value = index.field("value", of: n) {
            return value.description
        }
        if index.isInstance(n, of: "java.lang.Enum"), case .object(let name)? = index.field("name", of: n),
           let text = string(name, in: index) {
            return text
        }
        if index.isInstance(n, of: "java.lang.Thread"), case .object(let name)? = index.field("name", of: n),
           let text = string(name, in: index) {
            return quoted(text)
        }
        if index.isInstance(n, of: "java.io.File"), case .object(let path)? = index.field("path", of: n),
           let text = string(path, in: index) {
            return quoted(text)
        }
        guard let fields = try? index.fields(of: n) else { return nil }
        for name in ["size", "count", "elementCount", "baseCount"] {
            if let field = fields.first(where: { $0.name == name }), case .int(let size) = field.value {
                return "size \(size)"
            }
            if let field = fields.first(where: { $0.name == name }), case .long(let size) = field.value {
                return "size \(size)"
            }
        }
        return nil
    }

    /// A `java.lang.String`'s text: JDK 9+ (`value` is a `byte[]`, `coder` 0 Latin-1 or 1
    /// UTF-16 in the JVM's byte order) or JDK 8 (`value` is a `char[]`).
    static func string(_ n: Int32, in index: HeapIndex) -> String? {
        guard index.kind(of: n) == .instance, index.className(of: n) == "java.lang.String" else { return nil }
        guard let fields = try? index.fields(of: n),
              let value = fields.first(where: { $0.name == "value" })?.value.objectNumber else {
            return nil
        }
        var coder: Int8 = 0
        if case .byte(let raw)? = fields.first(where: { $0.name == "coder" })?.value { coder = raw }
        guard let (type, bytes) = try? index.primitiveArrayBytes(of: value, limit: maximumCharacters * 2 + 2) else { return nil }
        let text: String
        switch type {
        case .byte where coder == 1:
            // UTF-16 in the JVM's (little-endian) order.
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var position = 0
            while position + 1 < bytes.count {
                units.append(UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8)
                position += 2
            }
            text = String(decoding: units, as: UTF16.self)
        case .byte:
            text = String(bytes.map { Character(Unicode.Scalar($0)) })
        case .char:
            // HPROF writes `char` elements big-endian.
            var units: [UInt16] = []
            var position = 0
            while position + 1 < bytes.count {
                units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
                position += 2
            }
            text = String(decoding: units, as: UTF16.self)
        default:
            return nil
        }
        // Read past `maximumCharacters`, so `quoted` marks a longer string with an ellipsis.
        return text
    }

    /// A `char[]` read as text (other arrays have no text).
    private static func characters(ofArray n: Int32, in index: HeapIndex) -> String? {
        guard let (type, bytes) = try? index.primitiveArrayBytes(of: n, limit: maximumCharacters + 1), type == .char else {
            return nil
        }
        var units: [UInt16] = []
        var position = 0
        while position + 1 < bytes.count {
            units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
            position += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func quoted(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if cleaned.count > maximumCharacters {
            cleaned = String(cleaned.prefix(maximumCharacters)) + "…"
        }
        return "\"\(cleaned)\""
    }
}
