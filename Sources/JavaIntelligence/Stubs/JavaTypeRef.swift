import Foundation

/// A reference to a Java type, as it appears in a field type, a method signature, a supertype list,
/// or a generic bound. Produced by both the class-file `Signature`/descriptor readers and the
/// tree-sitter source stub builder.
///
/// Source stubs may not know a type's fully-qualified name at parse time (imports are resolved
/// lazily), so `.unresolved` carries the simple name as written and defers qualification to
/// ``JavaTypeResolver``.
public indirect enum JavaTypeRef: Hashable, Sendable {
    case primitive(JavaPrimitive)
    case void
    /// A class or interface type: its erased qualified name, generic type arguments (empty if raw
    /// or non-generic), and an optional qualifier for a non-static nested type (`Outer.Inner`).
    case classType(qualifiedName: String, arguments: [JavaTypeArgument], outer: JavaTypeRef?)
    case array(element: JavaTypeRef)
    /// A reference to a type variable by name, resolved against the declaring class/method's
    /// type parameters at query time.
    case typeVariable(name: String)
    case wildcard(bound: JavaWildcardBound?)
    /// A simple name seen in source that has not been resolved against imports yet.
    case unresolved(simpleName: String, arguments: [JavaTypeArgument])

    /// A best-effort display name, ignoring generics resolution.
    public var simpleDisplayName: String {
        switch self {
        case .primitive(let p): return p.rawValue
        case .void: return "void"
        case .classType(let qualifiedName, _, _): return String(qualifiedName.split(separator: ".").last.map(String.init) ?? qualifiedName)
        case .array(let element): return "\(element.simpleDisplayName)[]"
        case .typeVariable(let name): return name
        case .wildcard: return "?"
        case .unresolved(let simpleName, _): return simpleName
        }
    }

    /// `java/util/Map$Entry` → `java.util.Map.Entry`: the source-level name the index keys stubs
    /// by (see `ClassFileReader.splitName`), so a type read from a descriptor or signature finds
    /// its nested class.
    public static func qualifiedName(fromInternalName internalName: String) -> String {
        var name = internalName.replacingOccurrences(of: "/", with: ".")
        if name.contains("$") {
            name = name.replacingOccurrences(of: "$", with: ".")
        }
        return name
    }

    /// The erased qualified name this type refers to, if it is a class/interface type
    /// (not a primitive, array, type variable, or unresolved reference).
    public var erasedQualifiedName: String? {
        if case .classType(let qualifiedName, _, _) = self { return qualifiedName }
        return nil
    }
}

public enum JavaWildcardBound: Hashable, Sendable {
    case extends(JavaTypeRef)
    case superBound(JavaTypeRef)
}

public enum JavaTypeArgument: Hashable, Sendable {
    case type(JavaTypeRef)
    case wildcard(JavaWildcardBound?)
}

public enum JavaPrimitive: String, Hashable, Sendable, CaseIterable {
    case boolean, byte, char, short, int, long, float, double
}

/// A formal type parameter, e.g. `<T extends Comparable<T>>`.
public struct JavaTypeParameter: Hashable, Sendable {
    public let name: String
    public let bounds: [JavaTypeRef]

    public init(name: String, bounds: [JavaTypeRef]) {
        self.name = name
        self.bounds = bounds
    }
}
