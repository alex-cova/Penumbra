import Foundation

/// A stable, comparable identity for a Java symbol: what a usage must resolve to for it to count
/// as a usage of a target. Built from declared (not substituted) signatures, so the same method
/// always yields the same ID no matter how it was reached.
public enum JavaSymbolID: Hashable, Sendable {
    /// A class, interface, enum, record or annotation; same convention as ``JavaClassStub/qualifiedName``.
    case type(qualifiedName: String)
    /// `parameterKeys` are the erased simple type names of the declared parameters (`JavaTypeKeys.keys(of:)`).
    case method(declaringClass: String, name: String, parameterKeys: [String])
    case constructor(declaringClass: String, parameterKeys: [String])
    /// Includes enum constants and record components.
    case field(declaringClass: String, name: String)
    /// A local variable or parameter; `declarationRange` is the UTF-8 byte range of the declaring name.
    case local(file: URL, declarationRange: Range<Int>)

    /// The identifier text usages of this symbol are written with (empty for a local).
    public var simpleName: String {
        switch self {
        case .type(let qualifiedName): return Self.lastComponent(qualifiedName)
        case .method(_, let name, _): return name
        case .constructor(let declaringClass, _): return Self.lastComponent(declaringClass)
        case .field(_, let name): return name
        case .local: return ""
        }
    }

    /// The class that declares this symbol (`nil` for a local; a type's own name for a type).
    public var declaringClass: String? {
        switch self {
        case .type(let qualifiedName): return qualifiedName
        case .method(let declaringClass, _, _), .constructor(let declaringClass, _), .field(let declaringClass, _):
            return declaringClass
        case .local: return nil
        }
    }

    private static func lastComponent(_ dotted: String) -> String {
        String(dotted.split(separator: ".").last ?? Substring(dotted))
    }
}
