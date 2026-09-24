import Foundation

/// Resolves the `.unresolved(simpleName:arguments:)` references ``JavaSourceStubBuilder`` leaves
/// behind (a bare simple name can't be told apart from a type-parameter reference without scope
/// information -- see ``JavaTypeNodeConverter``) against a ``JavaResolutionContext``, in the
/// standard Java lookup order:
///
/// 1. a type parameter in scope -> `.typeVariable`
/// 2. a nested type declared by an enclosing type
/// 3. a single-type import (`import java.util.List;`)
/// 4. the same package
/// 5. an on-demand import (`import java.util.*;`), first match wins
/// 6. `java.lang`
/// 7. a nested type an enclosing type inherits from a supertype (JLS puts this with step 2; it
///    runs last so ordinary names never pay for the supertype walk)
/// 8. otherwise left as `.unresolved` -- e.g. a real class the index just doesn't have (an
///    unindexed dependency), not necessarily an invalid reference
///
/// Resolution recurses through the whole type (array element types, generic arguments, wildcard
/// bounds), since any of those can independently contain unresolved references.
public enum JavaTypeResolver {
    /// Set while ``nestedType(named:in:index:)`` walks supertypes, to keep that walk from
    /// recursing into another one.
    @TaskLocal private static var isWalkingSupertypes = false

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
            if outer == nil, qualifiedName.contains("."), await index.classStub(qualifiedName: qualifiedName) == nil,
               let nested = await resolveQualifiedNested(qualifiedName, context: context, index: index) {
                return .classType(qualifiedName: nested, arguments: resolvedArgs, outer: nil)
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
    /// concrete type, in the order listed on ``JavaTypeResolver``.
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

        // Nested types inherited from an enclosing type's supertypes. JLS 6.4.1 puts them before
        // imports; they are checked last here so the common case (an imported or `java.lang` name)
        // never pays for the supertype walk. Only an import that collides with an inherited nested
        // type's simple name resolves differently.
        if let first = simpleName.first, first.isUppercase, !isWalkingSupertypes {
            for enclosingQualifiedName in context.enclosingTypeQualifiedNames {
                if let inherited = await nestedType(named: simpleName, in: enclosingQualifiedName, index: index) {
                    return .classType(qualifiedName: inherited, arguments: arguments, outer: nil)
                }
            }
        }

        return .unresolved(simpleName: simpleName, arguments: arguments)
    }

    /// A dotted type name as written (`Map.Entry`, `User.Builder`) that isn't a qualified class:
    /// its first segment is a simple type name in scope, and the rest are nested types.
    private static func resolveQualifiedNested(_ dotted: String, context: JavaResolutionContext, index: JavaIndex) async -> String? {
        let segments = dotted.split(separator: ".").map(String.init)
        guard segments.count > 1, segments[0].first?.isUppercase == true else { return nil }
        guard case .classType(let head, _, _) = await resolveSimpleName(segments[0], context: context, index: index, arguments: []) else { return nil }
        var current = head
        for segment in segments.dropFirst() {
            guard let nested = await nestedType(named: segment, in: current, index: index) else { return nil }
            current = nested
        }
        return current
    }

    /// A member type `simpleName` of `owner` or of one of its supertypes (nested types are
    /// inherited like other members: `class Dog extends Animal` sees `Animal.Entry` as `Entry`).
    private static func nestedType(named simpleName: String, in owner: String, index: JavaIndex) async -> String? {
        let direct = "\(owner).\(simpleName)"
        if await index.classStub(qualifiedName: direct) != nil { return direct }
        // The supertype walk resolves supertype names through this resolver; without the guard an
        // unresolvable supertype name would start another walk, forever.
        let supertypes = await $isWalkingSupertypes.withValue(true) {
            await JavaMemberLookup.supertypeClosure(of: owner, index: index)
        }
        for supertype in supertypes where supertype != owner {
            let candidate = "\(supertype).\(simpleName)"
            if await index.classStub(qualifiedName: candidate) != nil { return candidate }
        }
        return nil
    }

    private static func lastComponent(of dottedName: String) -> String {
        String(dottedName.split(separator: ".").last ?? Substring(dottedName))
    }
}
