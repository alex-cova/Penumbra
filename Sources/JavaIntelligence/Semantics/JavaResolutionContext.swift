import Foundation

/// Everything ``JavaTypeResolver``/``JavaMemberLookup`` need to know about *where* a reference
/// occurs, to resolve a simple name or check access: which file (package, imports), which type(s)
/// it's nested in (for type-parameter scope and sibling nested-type lookup), and which top-level
/// type it belongs to (for private-member visibility, which Java scopes to the whole top-level
/// type, not just one class body).
public struct JavaResolutionContext: Sendable {
    public let packageName: String
    public let imports: [JavaImportDeclaration]
    /// The enclosing type chain, innermost first, e.g. `["Outer.Inner", "Outer"]` when resolving
    /// something written inside `Inner`.
    public let enclosingTypeQualifiedNames: [String]
    /// Every type parameter name in scope: the enclosing type(s)' own parameters plus, when
    /// resolving inside a specific method, that method's parameters too.
    public let typeParameterNames: Set<String>

    public init(
        packageName: String,
        imports: [JavaImportDeclaration],
        enclosingTypeQualifiedNames: [String] = [],
        typeParameterNames: Set<String> = []
    ) {
        self.packageName = packageName
        self.imports = imports
        self.enclosingTypeQualifiedNames = enclosingTypeQualifiedNames
        self.typeParameterNames = typeParameterNames
    }

    /// The outermost enclosing type, e.g. `"Outer"` from `["Outer.Inner", "Outer"]`, used for
    /// private-member visibility (private is scoped to the whole top-level type in Java, not just
    /// one nested class body).
    public var topLevelTypeQualifiedName: String? {
        enclosingTypeQualifiedNames.last
    }

    public static func file(_ fileStubs: JavaSourceFileStubs) -> JavaResolutionContext {
        JavaResolutionContext(packageName: fileStubs.packageName, imports: fileStubs.imports)
    }

    /// A copy scoped to resolving something written inside `typeQualifiedName` (pushed onto the
    /// front of the enclosing chain) with that type's own type parameters added to scope.
    public func entering(type stub: JavaClassStub) -> JavaResolutionContext {
        JavaResolutionContext(
            packageName: packageName,
            imports: imports,
            enclosingTypeQualifiedNames: [stub.qualifiedName] + enclosingTypeQualifiedNames,
            typeParameterNames: typeParameterNames.union(stub.typeParameters.map(\.name))
        )
    }

    /// A copy with a method's own type parameters added to scope (methods can introduce their own
    /// `<T>` independent of the enclosing type's).
    public func entering(methodTypeParameters: [JavaTypeParameter]) -> JavaResolutionContext {
        JavaResolutionContext(
            packageName: packageName,
            imports: imports,
            enclosingTypeQualifiedNames: enclosingTypeQualifiedNames,
            typeParameterNames: typeParameterNames.union(methodTypeParameters.map(\.name))
        )
    }
}
