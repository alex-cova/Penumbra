import Foundation

/// Parses JVMS §4.7.9.1 generic signatures: the richer type encoding a class file carries in its
/// `Signature` attribute when generics, type variables, or bounded wildcards are involved.
/// Falls back to ``DescriptorParser`` (via the caller) when a member has no `Signature` attribute.
enum GenericSignatureParser {
    struct ClassSignature {
        let typeParameters: [JavaTypeParameter]
        let superclass: JavaTypeRef
        let interfaces: [JavaTypeRef]
    }

    struct MethodSignature {
        let typeParameters: [JavaTypeParameter]
        let parameters: [JavaTypeRef]
        let returnType: JavaTypeRef
        let thrownTypes: [JavaTypeRef]
    }

    private final class Cursor {
        let bytes: [UInt8]
        var index = 0
        init(_ text: String) { self.bytes = Array(text.utf8) }
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        func advance() { index += 1 }
        func consume(_ c: Character) -> Bool {
            guard current == c.asciiValue else { return false }
            advance()
            return true
        }
    }

    static func parseClassSignature(_ signature: String) -> ClassSignature? {
        let cursor = Cursor(signature)
        let typeParams = parseTypeParametersIfPresent(cursor) ?? []
        guard let superclass = parseClassTypeSignature(cursor) else { return nil }
        var interfaces: [JavaTypeRef] = []
        while cursor.current == UInt8(ascii: "L") || cursor.current == UInt8(ascii: "T") {
            guard let iface = parseClassTypeSignature(cursor) else { break }
            interfaces.append(iface)
        }
        return ClassSignature(typeParameters: typeParams, superclass: superclass, interfaces: interfaces)
    }

    static func parseMethodSignature(_ signature: String) -> MethodSignature? {
        let cursor = Cursor(signature)
        let typeParams = parseTypeParametersIfPresent(cursor) ?? []
        guard cursor.consume("(") else { return nil }
        var parameters: [JavaTypeRef] = []
        while cursor.current != UInt8(ascii: ")"), cursor.current != nil {
            guard let type = parseTypeSignature(cursor) else { return nil }
            parameters.append(type)
        }
        guard cursor.consume(")") else { return nil }
        guard let returnType = parseReturnType(cursor) else { return nil }
        var thrown: [JavaTypeRef] = []
        while cursor.current == UInt8(ascii: "^") {
            cursor.advance()
            if cursor.current == UInt8(ascii: "T") {
                if let v = parseTypeVariable(cursor) { thrown.append(v) }
            } else if let t = parseClassTypeSignature(cursor) {
                thrown.append(t)
            } else {
                break
            }
        }
        return MethodSignature(typeParameters: typeParams, parameters: parameters, returnType: returnType, thrownTypes: thrown)
    }

    // MARK: - Grammar productions

    private static func parseTypeParametersIfPresent(_ cursor: Cursor) -> [JavaTypeParameter]? {
        guard cursor.current == UInt8(ascii: "<") else { return nil }
        cursor.advance()
        var params: [JavaTypeParameter] = []
        while cursor.current != UInt8(ascii: ">"), cursor.current != nil {
            let start = cursor.index
            while cursor.current != UInt8(ascii: ":"), cursor.current != nil { cursor.advance() }
            let name = String(decoding: cursor.bytes[start..<cursor.index], as: UTF8.self)
            var bounds: [JavaTypeRef] = []
            // ClassBound ':' [ReferenceTypeSignature], then InterfaceBound* (':' ReferenceTypeSignature)
            while cursor.current == UInt8(ascii: ":") {
                cursor.advance()
                // An empty class bound (interface-only bound) leaves nothing before the next ':' or the closing.
                if cursor.current == UInt8(ascii: ":") || cursor.current == UInt8(ascii: ">") {
                    continue
                }
                if let bound = parseTypeSignature(cursor) {
                    bounds.append(bound)
                }
            }
            params.append(JavaTypeParameter(name: name, bounds: bounds))
        }
        guard cursor.consume(">") else { return nil }
        return params
    }

    private static func parseReturnType(_ cursor: Cursor) -> JavaTypeRef? {
        if cursor.current == UInt8(ascii: "V") {
            cursor.advance()
            return .void
        }
        return parseTypeSignature(cursor)
    }

    /// TypeSignature = BaseType | ReferenceTypeSignature
    private static func parseTypeSignature(_ cursor: Cursor) -> JavaTypeRef? {
        guard let c = cursor.current else { return nil }
        switch c {
        case UInt8(ascii: "B"): cursor.advance(); return .primitive(.byte)
        case UInt8(ascii: "C"): cursor.advance(); return .primitive(.char)
        case UInt8(ascii: "D"): cursor.advance(); return .primitive(.double)
        case UInt8(ascii: "F"): cursor.advance(); return .primitive(.float)
        case UInt8(ascii: "I"): cursor.advance(); return .primitive(.int)
        case UInt8(ascii: "J"): cursor.advance(); return .primitive(.long)
        case UInt8(ascii: "S"): cursor.advance(); return .primitive(.short)
        case UInt8(ascii: "Z"): cursor.advance(); return .primitive(.boolean)
        case UInt8(ascii: "["):
            cursor.advance()
            guard let element = parseTypeSignature(cursor) else { return nil }
            return .array(element: element)
        case UInt8(ascii: "T"):
            return parseTypeVariable(cursor)
        case UInt8(ascii: "L"):
            return parseClassTypeSignature(cursor)
        default:
            return nil
        }
    }

    private static func parseTypeVariable(_ cursor: Cursor) -> JavaTypeRef? {
        guard cursor.consume("T") else { return nil }
        let start = cursor.index
        while cursor.current != UInt8(ascii: ";"), cursor.current != nil { cursor.advance() }
        let name = String(decoding: cursor.bytes[start..<cursor.index], as: UTF8.self)
        _ = cursor.consume(";")
        return .typeVariable(name: name)
    }

    /// ClassTypeSignature = 'L' [PackageSpecifier] SimpleClassTypeSignature (ClassTypeSignatureSuffix)* ';'
    /// Handles nested-type qualification (`Outer<T>.Inner<U>`), encoded as repeated
    /// `.SimpleClassTypeSignature` suffixes separated by '.' inside the same 'L...;' run.
    private static func parseClassTypeSignature(_ cursor: Cursor) -> JavaTypeRef? {
        guard cursor.consume("L") else { return nil }
        var packageAndName = ""
        while let c = cursor.current, c != UInt8(ascii: "<"), c != UInt8(ascii: ";"), c != UInt8(ascii: ".") {
            packageAndName.append(Character(UnicodeScalar(c)))
            cursor.advance()
        }
        let qualifiedName = packageAndName.replacingOccurrences(of: "/", with: ".")
        var args = parseTypeArgumentsIfPresent(cursor) ?? []
        var result: JavaTypeRef = .classType(qualifiedName: qualifiedName, arguments: args, outer: nil)

        // Nested-type suffixes: '.' Identifier [TypeArguments]
        while cursor.current == UInt8(ascii: ".") {
            cursor.advance()
            var simpleName = ""
            while let c = cursor.current, c != UInt8(ascii: "<"), c != UInt8(ascii: ";"), c != UInt8(ascii: ".") {
                simpleName.append(Character(UnicodeScalar(c)))
                cursor.advance()
            }
            args = parseTypeArgumentsIfPresent(cursor) ?? []
            let outerName: String
            if case .classType(let qn, _, _) = result { outerName = qn } else { outerName = qualifiedName }
            result = .classType(qualifiedName: "\(outerName).\(simpleName)", arguments: args, outer: result)
        }

        _ = cursor.consume(";")
        return result
    }

    private static func parseTypeArgumentsIfPresent(_ cursor: Cursor) -> [JavaTypeArgument]? {
        guard cursor.current == UInt8(ascii: "<") else { return nil }
        cursor.advance()
        var args: [JavaTypeArgument] = []
        while cursor.current != UInt8(ascii: ">"), cursor.current != nil {
            if cursor.current == UInt8(ascii: "*") {
                cursor.advance()
                args.append(.wildcard(nil))
            } else if cursor.current == UInt8(ascii: "+") {
                cursor.advance()
                if let bound = parseTypeSignature(cursor) {
                    args.append(.wildcard(.extends(bound)))
                }
            } else if cursor.current == UInt8(ascii: "-") {
                cursor.advance()
                if let bound = parseTypeSignature(cursor) {
                    args.append(.wildcard(.superBound(bound)))
                }
            } else if let type = parseTypeSignature(cursor) {
                args.append(.type(type))
            } else {
                break
            }
        }
        _ = cursor.consume(">")
        return args
    }
}
