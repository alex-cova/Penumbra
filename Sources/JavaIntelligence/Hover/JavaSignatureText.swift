import Foundation

/// Source-like text for a stub's declaration, e.g. `public static <T> List<T> of(T a, T b)`, for
/// hover popups.
enum JavaSignatureText {
    static func type(_ stub: JavaClassStub) -> String {
        var parts = modifiers(stub.modifiers, allowed: [.publicFlag, .protectedFlag, .privateFlag, .staticFlag, .abstractFlag, .finalFlag], drop: stub.kind == .interfaceKind || stub.kind == .annotationKind ? [.abstractFlag] : [])
        parts.append(keyword(stub.kind))
        var name = stub.simpleName + typeParameters(stub.typeParameters)
        if let superclass = stub.superclass, stub.kind == .classKind, superclass.erasedQualifiedName != "java.lang.Object" {
            name += " extends \(text(of: superclass))"
        }
        if !stub.interfaces.isEmpty {
            let list = stub.interfaces.map(text(of:)).joined(separator: ", ")
            name += stub.kind == .interfaceKind ? " extends \(list)" : " implements \(list)"
        }
        parts.append(name)
        return parts.joined(separator: " ")
    }

    static func method(_ method: JavaMethodStub, in owner: JavaClassStub?) -> String {
        var parts = modifiers(method.modifiers, allowed: [.publicFlag, .protectedFlag, .privateFlag, .staticFlag, .abstractFlag, .finalFlag, .defaultMethod], drop: [])
        if !method.typeParameters.isEmpty { parts.append(typeParameters(method.typeParameters)) }
        if !method.isConstructor { parts.append(text(of: method.returnType)) }
        let name = method.isConstructor ? (owner?.simpleName ?? method.name) : method.name
        let parameters = method.parameters.enumerated().map { index, parameter -> String in
            var type = text(of: parameter.type)
            if method.modifiers.contains(.varargs), index == method.parameters.count - 1, type.hasSuffix("[]") {
                type = String(type.dropLast(2)) + "..."
            }
            return parameter.name.map { "\(type) \($0)" } ?? type
        }
        var signature = parts.joined(separator: " ")
        signature += (signature.isEmpty ? "" : " ") + "\(name)(\(parameters.joined(separator: ", ")))"
        if !method.thrownTypes.isEmpty {
            signature += " throws " + method.thrownTypes.map(text(of:)).joined(separator: ", ")
        }
        return signature
    }

    static func field(_ field: JavaFieldStub) -> String {
        let parts = modifiers(field.modifiers, allowed: [.publicFlag, .protectedFlag, .privateFlag, .staticFlag, .finalFlag], drop: [])
        return (parts + [text(of: field.type), field.name]).joined(separator: " ")
    }

    /// `List<String>`, `Map.Entry<K, V>`, `int[]`: simple names, generics kept.
    static func text(of type: JavaTypeRef) -> String {
        switch type {
        case .classType(_, let arguments, _), .unresolved(_, let arguments):
            let base = type.simpleDisplayName
            return arguments.isEmpty ? base : "\(base)<\(arguments.map(text(of:)).joined(separator: ", "))>"
        case .array(let element):
            return "\(text(of: element))[]"
        case .wildcard(let bound):
            return wildcard(bound)
        default:
            return type.simpleDisplayName
        }
    }

    private static func text(of argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type): return text(of: type)
        case .wildcard(let bound): return wildcard(bound)
        }
    }

    private static func wildcard(_ bound: JavaWildcardBound?) -> String {
        switch bound {
        case nil: return "?"
        case .extends(let type)?: return "? extends \(text(of: type))"
        case .superBound(let type)?: return "? super \(text(of: type))"
        }
    }

    private static func typeParameters(_ parameters: [JavaTypeParameter]) -> String {
        guard !parameters.isEmpty else { return "" }
        let list = parameters.map { parameter -> String in
            let bounds = parameter.bounds.filter { $0.erasedQualifiedName != "java.lang.Object" }
            return bounds.isEmpty ? parameter.name : "\(parameter.name) extends \(bounds.map(text(of:)).joined(separator: " & "))"
        }
        return "<\(list.joined(separator: ", "))>"
    }

    private static func keyword(_ kind: JavaTypeKind) -> String {
        switch kind {
        case .classKind: return "class"
        case .interfaceKind: return "interface"
        case .enumKind: return "enum"
        case .recordKind: return "record"
        case .annotationKind: return "@interface"
        }
    }

    private static func modifiers(_ flags: JavaModifiers, allowed: [JavaModifiers], drop: [JavaModifiers]) -> [String] {
        let names: [(JavaModifiers, String)] = [
            (.publicFlag, "public"), (.protectedFlag, "protected"), (.privateFlag, "private"),
            (.abstractFlag, "abstract"), (.staticFlag, "static"), (.finalFlag, "final"), (.defaultMethod, "default")
        ]
        return names.compactMap { flag, name in
            allowed.contains(flag) && !drop.contains(flag) && flags.contains(flag) ? name : nil
        }
    }
}
