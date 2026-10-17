import Foundation

/// A Java symbol as the semantic model sees it: every declaration the scope tree, the resolver
/// and usages/rename can name. Each case carries its declaration site (file plus the UTF-8 byte
/// range of the declaring name) and, where a stub model exists, its stub.
///
/// Identity (`id`) follows ``JavaSymbolID``: declared signatures, never substituted types, so
/// the same method yields the same ID however it was reached. Locals, parameters, type
/// parameters, packages and labels have no qualified name; locals and local types identify by
/// file and declaration range, the rest have no ID yet.
public enum JavaSymbol: Hashable, Sendable {
    /// A block local, loop/resource variable or pattern binding.
    case local(name: String, file: URL, declarationRange: Range<Int>, type: JavaTypeRef)
    /// A method, constructor, catch or lambda parameter.
    case parameter(name: String, file: URL, declarationRange: Range<Int>, type: JavaTypeRef)
    case field(declaringClass: String, stub: JavaFieldStub)
    case method(declaringClass: String, stub: JavaMethodStub)
    case constructor(declaringClass: String, stub: JavaMethodStub)
    /// A top-level or member type, named by qualified name.
    case type(stub: JavaClassStub)
    /// A class declared inside a body (or an anonymous class body), named by declaration site.
    case localType(name: String, file: URL, declarationRange: Range<Int>)
    case typeParameter(name: String, owner: JavaSymbolID?)
    case package(name: String)
    case label(name: String, file: URL, declarationRange: Range<Int>)

    public var name: String {
        switch self {
        case .local(let name, _, _, _): return name
        case .parameter(let name, _, _, _): return name
        case .field(_, let stub): return stub.name
        case .method(_, let stub): return stub.name
        case .constructor(let declaringClass, _): return String(declaringClass.split(separator: ".").last ?? Substring(declaringClass))
        case .type(let stub): return String(stub.qualifiedName.split(separator: ".").last ?? Substring(stub.qualifiedName))
        case .localType(let name, _, _): return name
        case .typeParameter(let name, _): return name
        case .package(let name): return name
        case .label(let name, _, _): return name
        }
    }

    public var id: JavaSymbolID? {
        switch self {
        case .local(_, let file, let declarationRange, _):
            return .local(file: file, declarationRange: declarationRange)
        case .parameter(_, let file, let declarationRange, _):
            // Parameters share the local identity scheme: usages name them by site, not role.
            return .local(file: file, declarationRange: declarationRange)
        case .field(let declaringClass, let stub):
            return .field(declaringClass: declaringClass, name: stub.name)
        case .method(let declaringClass, let stub):
            return .method(
                declaringClass: declaringClass, name: stub.name,
                parameterKeys: JavaTypeKeys.keys(of: stub)
            )
        case .constructor(let declaringClass, let stub):
            return .constructor(declaringClass: declaringClass, parameterKeys: JavaTypeKeys.keys(of: stub))
        case .type(let stub):
            return .type(qualifiedName: stub.qualifiedName)
        case .localType(_, let file, let declarationRange):
            return .localType(file: file, declarationRange: declarationRange)
        case .typeParameter, .package, .label:
            return nil
        }
    }
}
