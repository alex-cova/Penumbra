import Foundation

/// Parses JVM type descriptors (JVMS §4.3), the non-generic type encoding used for every field,
/// parameter and return type in a class file that has no `Signature` attribute.
///
/// Descriptor grammar: `B`yte `C`har `D`ouble `F`loat `I`nt `J`long `S`hort `Z`boolean
/// `L<binary/name>;` object `[` array-of.
enum DescriptorParser {
    /// Parses a single field/type descriptor starting at `text[index]`, advancing `index` past it.
    static func parseType(_ text: [UInt8], _ index: inout Int) -> JavaTypeRef? {
        guard index < text.count else { return nil }
        let c = text[index]
        switch c {
        case UInt8(ascii: "B"): index += 1; return .primitive(.byte)
        case UInt8(ascii: "C"): index += 1; return .primitive(.char)
        case UInt8(ascii: "D"): index += 1; return .primitive(.double)
        case UInt8(ascii: "F"): index += 1; return .primitive(.float)
        case UInt8(ascii: "I"): index += 1; return .primitive(.int)
        case UInt8(ascii: "J"): index += 1; return .primitive(.long)
        case UInt8(ascii: "S"): index += 1; return .primitive(.short)
        case UInt8(ascii: "Z"): index += 1; return .primitive(.boolean)
        case UInt8(ascii: "V"): index += 1; return .void
        case UInt8(ascii: "["):
            index += 1
            guard let element = parseType(text, &index) else { return nil }
            return .array(element: element)
        case UInt8(ascii: "L"):
            index += 1
            let start = index
            while index < text.count, text[index] != UInt8(ascii: ";") {
                index += 1
            }
            guard index < text.count else { return nil }
            let binaryName = String(decoding: text[start..<index], as: UTF8.self)
            index += 1 // consume ';'
            return .classType(qualifiedName: binaryName.replacingOccurrences(of: "/", with: "."), arguments: [], outer: nil)
        default:
            return nil
        }
    }

    /// Parses a `(paramDescriptors)returnDescriptor` method descriptor.
    static func parseMethodDescriptor(_ descriptor: String) -> (parameters: [JavaTypeRef], returnType: JavaTypeRef)? {
        let bytes = Array(descriptor.utf8)
        var index = 0
        guard index < bytes.count, bytes[index] == UInt8(ascii: "(") else { return nil }
        index += 1
        var parameters: [JavaTypeRef] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
            guard let type = parseType(bytes, &index) else { return nil }
            parameters.append(type)
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: ")") else { return nil }
        index += 1
        guard let returnType = parseType(bytes, &index) else { return nil }
        return (parameters, returnType)
    }

    /// Parses a bare field descriptor, e.g. `"Ljava/lang/String;"` or `"[I"`.
    static func parseFieldDescriptor(_ descriptor: String) -> JavaTypeRef? {
        let bytes = Array(descriptor.utf8)
        var index = 0
        return parseType(bytes, &index)
    }
}
