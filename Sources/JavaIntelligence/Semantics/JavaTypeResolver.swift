import Foundation

/// Resolves the `.unresolved(simpleName:arguments:)` references ``JavaSourceStubBuilder`` leaves
/// behind (a bare simple name can't be told apart from a type-parameter reference without scope
/// information -- see ``JavaTypeNodeConverter``) against a ``JavaResolutionContext``, in the
/// standard Java lookup order:
///
/// 1. a type parameter in scope -> `.typeVariable`
/// 2. a nested type of an enclosing type (checked directly, not through inherited nested types --
///    see the type-level doc comment on ``resolveSimpleName(_:context:index:)``)
/// 3. a single-type import (`import java.util.List;`)
/// 4. the same package
/// 5. an on-demand import (`import java.util.*;`), first match wins
/// 6. `java.lang`
/// 7. otherwise left as `.unresolved` -- e.g. a real class the index just doesn't have (an
///    unindexed dependency), not necessarily an invalid reference
///
/// Resolution recurses through the whole type (array element types, generic arguments, wildcard
/// bounds), since any of those can independently contain unresolved references.
public enum JavaTypeResolver {
    public static func resolve(_ type: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex) async -> JavaTypeRef {
        switch type {
        case .primitive, .void, .typeVariable:
            return type
        case .array(let element):
            return .array(element: await resolve(element, context: context, index: index))
        case .classType(let qualifiedName, let arguments, let outer):
            let resolvedArgs = await resolve(arguments, context: context, index: index)
            var resolvedOuter: JavaTypeRef?
            if let outer {
                resolvedOuter = await resolve(outer, context: context, index: index)
            }
            return .classType(qualifiedName: qualifiedName, arguments: resolvedArgs, outer: resolvedOuter)
        case .wildcard(let bound):
            return .wildcard(bound: await resolve(bound, context: context, index: index))
        case .unresolved(let simpleName, let arguments):
            let resolvedArgs = await resolve(arguments, context: context, index: index)
            return await resolveSimpleName(simpleName, context: context, index: index, arguments: resolvedArgs)
        }
    }

    private static func resolve(_ arguments: [JavaTypeArgument], context: JavaResolutionContext, index: JavaIndex) async -> [JavaTypeArgument] {
        var result: [JavaTypeArgument] = []
        result.reserveCapacity(arguments.count)
        for argument in arguments {
            switch argument {
            case .type(let t):
                result.append(.type(await resolve(t, context: context, index: index)))
            case .wildcard(let bound):
                result.append(.wildcard(await resolve(bound, context: context, index: index)))
            }
        }
        return result
    }

    private static func resolve(_ bound: JavaWildcardBound?, context: JavaResolutionContext, index: JavaIndex) async -> JavaWildcardBound? {
        guard let bound else { return nil }
        switch bound {
        case .extends(let t):
            return .extends(await resolve(t, context: context, index: index))
        case .superBound(let t):
            return .superBound(await resolve(t, context: context, index: index))
        }
    }

    /// Resolves a bare simple name (already known not to be a primitive/void/array/wildcard) to a
    /// concrete type. Step 2 (nested types) only checks each enclosing type's own
    /// `innerTypeNames`, not nested types inherited from its supertypes -- a deliberate
    /// simplification, since that requires the same supertype walk ``JavaMemberLookup`` does and
    /// nested-type inheritance is a rare completion need compared to member inheritance.
    private static func resolveSimpleName(
        _ simpleName: String, context: JavaResolutionContext, index: JavaIndex, arguments: [JavaTypeArgument]
    ) async -> JavaTypeRef {
        if context.typeParameterNames.contains(simpleName) {
            return .typeVariable(name: simpleName)
        }

        for enclosingQualifiedName in context.enclosingTypeQualifiedNames {
            if let enclosing = await index.classStub(qualifiedName: enclosingQualifiedName) {
                if let match = enclosing.innerTypeNames.first(where: { $0.hasSuffix(".\(simpleName)") || $0 == simpleName }) {
                    return .classType(qualifiedName: match, arguments: arguments, outer: nil)
                }
                if enclosing.simpleName == simpleName {
                    return .classType(qualifiedName: enclosing.qualifiedName, arguments: arguments, outer: nil)
                }
            }
        }

        if let singleTypeImport = context.imports.first(where: { !$0.isStatic && !$0.isOnDemand && lastComponent(of: $0.qualifiedName) == simpleName }) {
            return .classType(qualifiedName: singleTypeImport.qualifiedName, arguments: arguments, outer: nil)
        }

        let samePackageCandidate = context.packageName.isEmpty ? simpleName : "\(context.packageName).\(simpleName)"
        if await index.classStub(qualifiedName: samePackageCandidate) != nil {
            return .classType(qualifiedName: samePackageCandidate, arguments: arguments, outer: nil)
        }

        for onDemandImport in context.imports where !onDemandImport.isStatic && onDemandImport.isOnDemand {
            let candidate = "\(onDemandImport.qualifiedName).\(simpleName)"
            if await index.classStub(qualifiedName: candidate) != nil {
                return .classType(qualifiedName: candidate, arguments: arguments, outer: nil)
            }
        }

        let javaLangCandidate = "java.lang.\(simpleName)"
        if await index.classStub(qualifiedName: javaLangCandidate) != nil {
            return .classType(qualifiedName: javaLangCandidate, arguments: arguments, outer: nil)
        }

        return .unresolved(simpleName: simpleName, arguments: arguments)
    }

    private static func lastComponent(of dottedName: String) -> String {
        String(dottedName.split(separator: ".").last ?? Substring(dottedName))
    }
}
