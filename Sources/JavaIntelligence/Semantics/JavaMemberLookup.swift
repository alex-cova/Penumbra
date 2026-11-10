import Foundation

/// Parsed declaring files for one member walk. Source stubs leave `extends Animal` unresolved;
/// resolving it re-reads that file's imports. One walk parses each file at most once.
private final class DeclaringFileCache: @unchecked Sendable {
    var files: [String: JavaSourceFileStubs] = [:]
}

/// One member found while walking a type's inheritance chain: the field/method itself (with its
/// type/return type already substituted for the receiver's actual generic arguments), plus the
/// class that declares it (for display, e.g. "declared in AbstractList", and for access checks).
public enum JavaResolvedMember: Sendable {
    case field(JavaFieldStub, declaringClass: String)
    case method(JavaMethodStub, declaringClass: String)

    public var name: String {
        switch self {
        case .field(let f, _): return f.name
        case .method(let m, _): return m.name
        }
    }

    public var modifiers: JavaModifiers {
        switch self {
        case .field(let f, _): return f.modifiers
        case .method(let m, _): return m.modifiers
        }
    }

    public var declaringClass: String {
        switch self {
        case .field(_, let c), .method(_, let c): return c
        }
    }
}

/// Whether a member lookup is for a type qualifier (`Foo.`, only static members + nested types
/// make sense) or an instance/expression receiver (`foo.`, everything Java itself would offer,
/// including inherited statics -- javac and every mainstream IDE allow `instance.staticMethod()`).
public enum JavaMemberLookupMode: Sendable {
    case instance
    case staticOnly
}

/// How the member is reached, for JLS 6.6.2.1. A protected instance member of `C` is accessible
/// from a subclass `S` in another package only when the qualifying type is `S` or a subclass of `S`.
/// Same-package access, static members, `super`, and a simple name have no such restriction.
public enum JavaMemberQualifier: Sendable {
    /// `expr.m`, `Type.m`, or the members of the enclosing class itself (`this`).
    case expression
    /// `super.m` and `super::m`. The qualifying type is the superclass; the restriction does not apply.
    case viaSuper
    /// A simple name searched on a supertype of the class that contains the use. There is no
    /// qualifying expression, so the receiver restriction does not apply.
    case simpleName
}

/// Walks a type's superclass/interface chain (substituting generic type arguments through each
/// level) to answer "what members does `.` offer here" -- the equivalent of resolving overload
/// sets and inherited members that a real `javac`/IDE symbol table would give you, built from
/// ``JavaIndex`` stubs instead.
public enum JavaMemberLookup {
    /// Optional reader for `.source` stubs whose superclass was stored as a simple name.
    /// Navigation installs one that prefers the live editor buffer. Nil falls back to disk.
    @TaskLocal public static var sourceTextProvider: (@Sendable (URL) async -> String?)?

    /// All members visible on `type` from the perspective of `context`, most-derived first,
    /// deduplicated so an override hides its superclass/interface original (matched by name +
    /// erased parameter list) and filtered by ``JavaMemberLookupMode`` and access.
    public static func members(
        of type: JavaTypeRef, mode: JavaMemberLookupMode, context: JavaResolutionContext, index: JavaIndex,
        checkAccess: Bool = true, qualifier: JavaMemberQualifier = .expression
    ) async -> [JavaResolvedMember] {
        if case .array(let element) = type {
            // JLS 10.7: `length`, a public `clone()` returning the array type, and every member of
            // `Object` except `clone`. Without `Object`'s, `array.getClass()`, `equals`,
            // `hashCode` and `toString` neither complete nor type. Only the public ones: an array
            // type is never a subclass of the accessing class, so `Object`'s protected members are
            // not accessible through it (JLS 6.6.2.1). The `Object` lookup is an expression
            // receiver even when the caller asked about `super` — an array has no superclass access.
            let object = JavaTypeRef.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            let inherited = mode == .staticOnly ? [] : await members(
                of: object, mode: .instance, context: context, index: index,
                checkAccess: checkAccess, qualifier: .expression
            ).filter { member in
                guard case .method(let method, _) = member else { return false }
                return method.modifiers.contains(.publicFlag) && !method.modifiers.contains(.staticFlag) && method.name != "clone"
            }
            return arrayMembers(elementType: element) + inherited
        }
        if case .typeVariable(let name) = type {
            return await members(
                ofVariable: name, mode: mode, context: context, index: index,
                checkAccess: checkAccess, qualifier: qualifier, seen: [name]
            )
        }
        guard case .classType(let qualifiedName, let arguments, let outer) = type else {
            return []
        }
        // Everything the walk reads: the type, the mode, what access is checked against, the
        // qualifier (a protected instance member depends on it), the resolution fallbacks, and
        // which shards are visible. The index clears the cache whenever its sources or overlay change.
        // `viaSuper` and `simpleName` allow the same members, so they share a cache entry.
        let scope = JavaIndex.queryScope.map { $0.sorted().joined(separator: ",") } ?? "*"
        let accessKey = checkAccess ? (qualifier == .expression ? "expression" : "subclass") : "unchecked"
        let cacheKey = "\(type)|\(mode)|\(accessKey)|\(context.packageName)|\(context.enclosingTypeQualifiedNames)|\(context.imports)|\(scope)"
        // A request that sees the buffer's own classes (`JavaIndex.liveStubs`) must not read or fill
        // a cache that other requests share.
        let isCacheable = sourceTextProvider == nil && JavaIndex.liveStubs == nil
            && !JavaAnonymousClass.isSynthetic(qualifiedName)
            && !context.enclosingTypeQualifiedNames.contains(where: JavaAnonymousClass.isSynthetic)
        if isCacheable, let cached = await index.cachedMemberSet(cacheKey) {
            return cached
        }
        let result = await walkMembers(
            of: qualifiedName, arguments: arguments, outer: outer, mode: mode, context: context, index: index,
            checkAccess: checkAccess, qualifier: qualifier
        )
        if isCacheable {
            await index.storeMemberSet(result, for: cacheKey)
        }
        return result
    }

    /// Members of a type variable: the members of its bounds, united when there are several
    /// (`T extends A & B` has what either offers, JLS 4.9). Bounds are
    /// resolved in the variable's scope first — a bound written as a bare name usually needs
    /// it — and a bound that is itself a variable recurses with `seen` cutting cycles.
    private static func members(
        ofVariable name: String, mode: JavaMemberLookupMode, context: JavaResolutionContext, index: JavaIndex,
        checkAccess: Bool, qualifier: JavaMemberQualifier, seen: Set<String>
    ) async -> [JavaResolvedMember] {
        let object = JavaTypeRef.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        guard let bounds = context.typeParameterBounds[name], !bounds.isEmpty else {
            return await members(of: object, mode: mode, context: context, index: index, checkAccess: checkAccess, qualifier: qualifier)
        }
        var perBound: [[JavaResolvedMember]] = []
        for bound in bounds {
            let resolved = await JavaTypeResolver.resolve(bound, context: context, index: index)
            switch resolved {
            case .typeVariable(let inner) where inner != name && !seen.contains(inner):
                perBound.append(await members(
                    ofVariable: inner, mode: mode, context: context, index: index,
                    checkAccess: checkAccess, qualifier: qualifier, seen: seen.union([inner])
                ))
            case .typeVariable:
                return await members(of: object, mode: mode, context: context, index: index, checkAccess: checkAccess, qualifier: qualifier)
            default:
                perBound.append(await members(
                    of: resolved, mode: mode, context: context, index: index, checkAccess: checkAccess, qualifier: qualifier
                ))
            }
        }
        guard perBound.count > 1 else { return perBound.first ?? [] }
        // The members of an intersection type are the members of every component (JLS 4.9): a
        // variable `T extends Number & Comparable<T>` has `intValue()` and `compareTo(T)`, which
        // javac accepts. A signature both bounds declare is listed once, the leftmost bound's.
        var seen = Set<String>()
        var union: [JavaResolvedMember] = []
        for member in perBound.joined() where seen.insert(signatureKey(of: member)).inserted {
            union.append(member)
        }
        return union
    }

    /// The same override key the member walk deduplicates on: fields by name, methods by
    /// name plus erased parameter list.
    private static func signatureKey(of member: JavaResolvedMember) -> String {
        switch member {
        case .field(let field, _):
            return "field:\(field.name)"
        case .method(let method, _):
            return "method:\(method.name)(\(method.parameters.map { erasedKey($0.type) }.joined(separator: ",")))"
        }
    }

    private static func walkMembers(
        of qualifiedName: String, arguments: [JavaTypeArgument], outer: JavaTypeRef?, mode: JavaMemberLookupMode,
        context: JavaResolutionContext, index: JavaIndex, checkAccess: Bool, qualifier: JavaMemberQualifier
    ) async -> [JavaResolvedMember] {
        let fileCache = DeclaringFileCache()
        var ancestorMemo: [String: Set<String>] = [:]
        let sites = await protectedSites(of: context, index: index, memo: &ancestorMemo)
        let receiverAncestors = await memoizedAncestors(of: qualifiedName, memo: &ancestorMemo, index: index)

        var seenSignatures = Set<String>()
        var result: [JavaResolvedMember] = []
        var fieldSlots: [String: Int] = [:]
        var ambiguousFields = Set<String>()
        var visitedClasses = Set<String>()
        // `implicitObject` marks `Object` queued by JLS 9.2 (an interface's public instance methods
        // only). A class that reaches `Object` as its superclass does not set it. That implicit
        // visit must not *consume* `Object`: an interface queued before a superclass is processed
        // first (the walk is a FIFO), and marking `Object` visited there used to drop `clone` and
        // `finalize` for a class receiver that can legally see them (JLS 6.6.2.1).
        var objectImplicitOnly = false
        var queue: [(qualifiedName: String, substitution: [String: JavaTypeRef], lowerOnly: Set<String>, implicitObject: Bool)] = [
            (qualifiedName,
             await substitutionMap(forTypeArguments: arguments, appliedTo: qualifiedName, index: index)
                .merging(await outerSubstitution(of: outer, index: index)) { own, _ in own },
             await lowerBoundedParameters(forTypeArguments: arguments, appliedTo: qualifiedName, index: index),
             false)
        ]
        // Processed as a FIFO queue (not a stack) so the class itself and its direct supertypes
        // are visited -- and their members recorded as "more derived" -- before Object/deeper
        // ancestors, which is what the dedup-by-override logic below relies on.
        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentName, substitution, lowerOnly, implicitObject) = queue[queueIndex]
            queueIndex += 1
            // A public-only `Object` visit leaves the name unvisited so the class chain can add
            // the protected members. A later full visit skips the public members already recorded,
            // so `toString` and `wait` are not built twice. With access checks off, the implicit
            // visit already keeps `clone` and `finalize`, and one visit is enough.
            var upgradingObject = false
            if currentName == "java.lang.Object", implicitObject, checkAccess {
                if visitedClasses.contains(currentName) || objectImplicitOnly { continue }
                objectImplicitOnly = true
            } else {
                if currentName == "java.lang.Object", objectImplicitOnly, !implicitObject {
                    upgradingObject = true
                }
                guard visitedClasses.insert(currentName).inserted else { continue }
            }
            guard let stub = await index.classStub(qualifiedName: currentName) else { continue }
            let implicitPublic = implicitObject && checkAccess
            // What a *read* of a type variable gives. `? super X` accepts an X going in, but only
            // its upper bound comes out (`List<? super Integer>.get(0)` is an `Object`, JLS 5.1.10).
            var readSubstitution = substitution
            for name in lowerOnly {
                readSubstitution[name] = stub.typeParameters.first { $0.name == name }?.bounds.first
                    ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            }
            // Source stubs keep type names as written (`List<StockSet>`); they must be resolved
            // against the *declaring* file's imports, not the file asking for completion.
            var declaringContext = await sourceDeclarationContext(of: stub, cache: fileCache)
            if JavaAnonymousClass.isLocal(currentName), let base = declaringContext {
                declaringContext = base.addingUnshadowedTypeParameters(from: context)
            }

            for field in stub.fields where !field.modifiers.contains(.synthetic) {
                guard mode == .instance || field.modifiers.contains(.staticFlag) || field.modifiers.contains(.enumConstant) else { continue }
                if implicitPublic, !field.modifiers.contains(.publicFlag) { continue }
                // The implicit visit already recorded every public field.
                if upgradingObject, field.modifiers.contains(.publicFlag) { continue }
                if checkAccess {
                    guard await isAccessible(
                        field.modifiers, declaringClass: currentName, declaringPackage: stub.packageName,
                        context: context, index: index, sites: sites, qualifier: qualifier,
                        receiverAncestors: receiverAncestors, restrictProtectedInstance: true
                    ) else { continue }
                }
                let substituted = substitute(await attachingOuter(await resolvedDeclaration(field.type, in: declaringContext, index: index), declaredIn: stub, index: index), using: readSubstitution)
                let member = JavaResolvedMember.field(
                    JavaFieldStub(name: field.name, type: substituted, modifiers: field.modifiers, javadoc: field.javadoc),
                    declaringClass: currentName
                )
                await absorbField(
                    member, name: field.name, declaringClass: currentName, stubKind: stub.kind,
                    into: &result, slots: &fieldSlots, ambiguous: &ambiguousFields, index: index
                )
            }
            for method in stub.methods where !method.isConstructor && !method.modifiers.contains(.synthetic) && !method.modifiers.contains(.bridge) && !method.name.hasPrefix("lambda$") {
                guard mode == .instance || method.modifiers.contains(.staticFlag) else { continue }
                // A static interface method is not inherited and can't be called through an
                // instance: `List.of(…)` only, never `users.of(…)` or `ArrayList.of(…)`.
                if stub.kind == .interfaceKind, method.modifiers.contains(.staticFlag),
                   mode == .instance || currentName != qualifiedName { continue }
                // JLS 9.2: an interface has `Object`'s public instance methods, not `clone` or `finalize`.
                if implicitPublic, !method.modifiers.contains(.publicFlag) || method.modifiers.contains(.staticFlag) { continue }
                // Public instance methods were recorded on the implicit visit. A public static
                // method was not (JLS 9.2 is instance methods only), so the full visit still sees it.
                if upgradingObject, method.modifiers.contains(.publicFlag), !method.modifiers.contains(.staticFlag) { continue }
                if checkAccess {
                    guard await isAccessible(
                        method.modifiers, declaringClass: currentName, declaringPackage: stub.packageName,
                        context: context, index: index, sites: sites, qualifier: qualifier,
                        receiverAncestors: receiverAncestors, restrictProtectedInstance: true
                    ) else { continue }
                }
                let methodContext = declaringContext?.entering(methodTypeParameters: method.typeParameters)
                var substitutedParams: [JavaParameterStub] = []
                for parameter in method.parameters {
                    let declared = await attachingOuter(await resolvedDeclaration(parameter.type, in: methodContext, index: index), declaredIn: stub, index: index)
                    substitutedParams.append(JavaParameterStub(name: parameter.name, type: substitute(declared, using: substitution)))
                }
                let declaredReturn = await attachingOuter(await resolvedDeclaration(method.returnType, in: methodContext, index: index), declaredIn: stub, index: index)
                let key = "method:\(method.name)(\(substitutedParams.map { erasedKey($0.type) }.joined(separator: ",")))"
                guard seenSignatures.insert(key).inserted else { continue }
                let substitutedMethod = JavaMethodStub(
                    name: method.name,
                    typeParameters: method.typeParameters,
                    parameters: substitutedParams,
                    returnType: substitute(declaredReturn, using: readSubstitution),
                    thrownTypes: method.thrownTypes,
                    modifiers: method.modifiers,
                    isConstructor: false,
                    javadoc: method.javadoc
                )
                result.append(.method(substitutedMethod, declaringClass: currentName))
            }

            if stub.kind != .interfaceKind, let superclass = stub.superclass {
                let substitutedSuper = substitute(superclass, using: substitution)
                let resolvedSuper = await resolveSupertype(substitutedSuper, declaredOn: stub, context: context, index: index, cache: fileCache)
                if case .classType(let superName, let superArgs, _) = resolvedSuper {
                    queue.append((
                        superName,
                        await substitutionMap(forTypeArguments: superArgs, appliedTo: superName, index: index),
                        await inheritedLowerBounded(declared: superclass, lowerOnly: lowerOnly, appliedTo: superName, index: index),
                        false
                    ))
                }
            } else if (stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind),
                      stub.superclass == nil, currentName != "java.lang.Object" {
                queue.append(("java.lang.Object", [:], [], false))
            }
            for iface in stub.interfaces {
                let substitutedIface = substitute(iface, using: substitution)
                let resolvedIface = await resolveSupertype(substitutedIface, declaredOn: stub, context: context, index: index, cache: fileCache)
                if case .classType(let ifaceName, let ifaceArgs, _) = resolvedIface {
                    queue.append((
                        ifaceName,
                        await substitutionMap(forTypeArguments: ifaceArgs, appliedTo: ifaceName, index: index),
                        await inheritedLowerBounded(declared: iface, lowerOnly: lowerOnly, appliedTo: ifaceName, index: index),
                        false
                    ))
                }
            }
            if stub.kind == .interfaceKind || stub.kind == .annotationKind, currentName != "java.lang.Object" {
                // An interface has the public methods of `Object` as implicit members (JLS 9.2):
                // `runnable.toString()` and `comparable.equals(x)` are legal and complete. Queued
                // after the superinterfaces, so a declaration of `equals` or `toString` on any
                // interface above wins. `clone` and `finalize` are not members; with access checks
                // off they stay, so an inspection can still tell "inaccessible" from "no such member".
                queue.append(("java.lang.Object", [:], [], true))
            }
        }
        // Two sibling interfaces declaring the same field are ambiguous (JLS 9.3). Drop the name
        // rather than keeping whichever interface was visited first.
        if !ambiguousFields.isEmpty {
            result.removeAll { member in
                if case .field(let field, _) = member { return ambiguousFields.contains(field.name) }
                return false
            }
        }
        return result
    }

    /// One field of `name`. The walk visits a class before its superinterfaces, so the first field
    /// is the one a class declares, and it hides an interface field of the same name. A
    /// subinterface redeclaration hides the superinterface field. Neither relationship means the
    /// two interfaces are siblings: the name is ambiguous and omitted.
    private static func absorbField(
        _ member: JavaResolvedMember, name: String, declaringClass: String, stubKind: JavaTypeKind,
        into result: inout [JavaResolvedMember], slots: inout [String: Int], ambiguous: inout Set<String>,
        index: JavaIndex
    ) async {
        if ambiguous.contains(name) { return }
        guard let slot = slots[name] else {
            slots[name] = result.count
            result.append(member)
            return
        }
        guard case .field(_, let existingClass) = result[slot] else { return }
        let existingKind = await index.classStub(qualifiedName: existingClass)?.kind
        let existingIsInterface = existingKind == .interfaceKind || existingKind == .annotationKind
        let newIsInterface = stubKind == .interfaceKind || stubKind == .annotationKind
        guard existingIsInterface && newIsInterface else { return }
        if await ancestorQualifiedNames(of: existingClass, index: index).contains(declaringClass) { return }
        if await ancestorQualifiedNames(of: declaringClass, index: index).contains(existingClass) {
            result[slot] = member
            return
        }
        ambiguous.insert(name)
    }

    /// Constructors declared on `type` itself (they are not inherited), visible from `context`.
    /// An empty result means the class has no written constructor — callers that are navigating
    /// `new Foo()` should land on the class name, which is the implicit constructor.
    public static func constructors(
        of type: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaMethodStub] {
        guard case .classType(let qualifiedName, _, _) = type else { return [] }
        guard let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        if stub.kind == .interfaceKind || stub.kind == .annotationKind { return [] }
        var ancestorMemo: [String: Set<String>] = [:]
        let sites = await protectedSites(of: context, index: index, memo: &ancestorMemo)
        var visible: [JavaMethodStub] = []
        for method in stub.methods where method.isConstructor {
            // A protected constructor has no qualifying expression (JLS 6.6.2, not 6.6.2.1).
            if await isAccessible(
                method.modifiers, declaringClass: qualifiedName, declaringPackage: stub.packageName,
                context: context, index: index, sites: sites, qualifier: .expression,
                receiverAncestors: [], restrictProtectedInstance: false
            ) {
                visible.append(method)
            }
        }
        return visible
    }

    /// The superclass `qualifiedName` actually extends, with a source stub's simple name resolved
    /// against that file's package and imports. Implicit `Object` is returned for a class that
    /// declares no superclass.
    public static func directSuperclass(
        of qualifiedName: String, context: JavaResolutionContext, index: JavaIndex
    ) async -> JavaTypeRef? {
        guard let stub = await index.classStub(qualifiedName: qualifiedName) else { return nil }
        if let superclass = stub.superclass {
            let resolved = await resolveSupertype(
                superclass, declaredOn: stub, context: context, index: index, cache: DeclaringFileCache()
            )
            if case .classType = resolved { return resolved }
            return nil
        }
        if qualifiedName != "java.lang.Object",
           stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind {
            return .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        }
        return nil
    }

    /// The interfaces `qualifiedName` directly implements or extends, simple names resolved
    /// against the declaring file. Type arguments written on the clause are kept. Indirect
    /// superinterfaces are not included: `I.super` is legal only for a direct one (JLS 15.12.1).
    public static func directSuperinterfaces(
        of qualifiedName: String, context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaTypeRef] {
        guard let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        let cache = DeclaringFileCache()
        var resolved: [JavaTypeRef] = []
        for interface in stub.interfaces {
            let supertype = await resolveSupertype(interface, declaredOn: stub, context: context, index: index, cache: cache)
            if case .classType = supertype { resolved.append(supertype) }
        }
        return resolved
    }

    private static func arrayMembers(elementType: JavaTypeRef) -> [JavaResolvedMember] {
        [
            .field(JavaFieldStub(name: "length", type: .primitive(.int), modifiers: [.publicFlag, .finalFlag]), declaringClass: "<array>"),
            .method(JavaMethodStub(name: "clone", parameters: [], returnType: .array(element: elementType), modifiers: [.publicFlag]), declaringClass: "<array>")
        ]
    }

    // MARK: - Access control

    private static func isAccessible(
        _ modifiers: JavaModifiers, declaringClass: String, declaringPackage: String,
        context: JavaResolutionContext, index: JavaIndex, sites: [ProtectedSite],
        qualifier: JavaMemberQualifier, receiverAncestors: Set<String>, restrictProtectedInstance: Bool
    ) async -> Bool {
        if modifiers.contains(.publicFlag) {
            return true
        }
        if modifiers.contains(.privateFlag) {
            guard let contextTopLevel = context.topLevelTypeQualifiedName else { return false }
            let declaringTopLevel = await topLevelQualifiedName(of: declaringClass, index: index)
            return declaringTopLevel == contextTopLevel
        }
        let samePackage = declaringPackage == context.packageName
        if modifiers.contains(.protectedFlag) {
            if samePackage { return true }
            // Static protected members, `super`, simple names and constructors need only that some
            // enclosing class is a subclass of the declaring class. An instance member through an
            // expression also needs the receiver to be that class or a subclass of it: `sub.secret`
            // is legal from `Sub`, `base.secret` is not (JLS 6.6.2.1). Enclosing classes are
            // innermost first, so an inner class that extends the declarer wins before its outer.
            let skipReceiver = !restrictProtectedInstance || modifiers.contains(.staticFlag) || qualifier != .expression
            for site in sites where !site.isInterface {
                guard site.ancestors.contains(declaringClass) else { continue }
                if skipReceiver || receiverAncestors.contains(site.name) { return true }
            }
            return false
        }
        // Package-private (none of public/private/protected).
        return samePackage
    }

    /// One enclosing class the access is attempted from, innermost first in the list that holds it.
    private struct ProtectedSite {
        var name: String
        var ancestors: Set<String>
        var isInterface: Bool
    }

    /// Enclosing types, innermost first. A missing stub is treated as a class: skipping it would
    /// hide a protected member of a source type the index has not finished. The ancestor set still
    /// contains the name itself.
    private static func protectedSites(
        of context: JavaResolutionContext, index: JavaIndex, memo: inout [String: Set<String>]
    ) async -> [ProtectedSite] {
        var sites: [ProtectedSite] = []
        for name in context.enclosingTypeQualifiedNames {
            let ancestors = await memoizedAncestors(of: name, memo: &memo, index: index)
            let kind = await index.classStub(qualifiedName: name)?.kind
            let isInterface = kind == .interfaceKind || kind == .annotationKind
            sites.append(ProtectedSite(name: name, ancestors: ancestors, isInterface: isInterface))
        }
        return sites
    }

    private static func memoizedAncestors(
        of name: String, memo: inout [String: Set<String>], index: JavaIndex
    ) async -> Set<String> {
        if let cached = memo[name] { return cached }
        let computed = await ancestorQualifiedNames(of: name, index: index)
        memo[name] = computed
        return computed
    }

    /// Walks `outerQualifiedName` up to the enclosing type with no further outer -- the real
    /// top-level type, used for private-member visibility (Java scopes `private` to the whole
    /// top-level type, not just one nested class body). Package dots and nesting dots both use
    /// `.` in a qualified name, so this can't be derived by splitting the string; it needs the
    /// stub's own `outerQualifiedName` chain.
    private static func topLevelQualifiedName(of qualifiedName: String, index: JavaIndex) async -> String {
        var current = qualifiedName
        var visited = Set<String>()
        while visited.insert(current).inserted, let stub = await index.classStub(qualifiedName: current), let outer = stub.outerQualifiedName {
            current = outer
        }
        return current
    }

    /// Every supertype of `qualifiedName` (itself included), transitively: superclasses and
    /// interfaces, erased. Used for assignability checks when ranking by expected type.
    public static func supertypeClosure(of qualifiedName: String, index: JavaIndex) async -> Set<String> {
        var closure = await ancestorQualifiedNames(of: qualifiedName, index: index)
        closure.insert(qualifiedName)
        closure.insert("java.lang.Object") // every reference type, interfaces included, converts to Object
        return closure
    }

    /// Every ancestor (superclass chain + interfaces, transitively) of `qualifiedName`, used only
    /// to decide protected-member visibility ("is the querying type a subclass of the declaring
    /// type"). Cycles are guarded; this only needs class identity, not member types, so it doesn't
    /// substitute generics. A class, enum or record with no recorded superclass is a subclass of
    /// `Object` (JLS 8.1.4); source stubs omit that implicit clause, and without it `this.clone()`
    /// would be invisible in a class that does not write `extends`.
    private static func ancestorQualifiedNames(of qualifiedName: String?, index: JavaIndex) async -> Set<String> {
        guard let qualifiedName else { return [] }
        let cache = DeclaringFileCache()
        var visited = Set<String>()
        var queue = [qualifiedName]
        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            guard let stub = await index.classStub(qualifiedName: next) else { continue }
            let fallback = JavaResolutionContext(packageName: stub.packageName, imports: [])
            if let superclass = stub.superclass {
                let resolved = await resolveSupertype(superclass, declaredOn: stub, context: fallback, index: index, cache: cache)
                if let name = resolved.erasedQualifiedName { queue.append(name) }
            } else if next != "java.lang.Object",
                      stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind {
                queue.append("java.lang.Object")
            }
            for interface in stub.interfaces {
                let resolved = await resolveSupertype(interface, declaredOn: stub, context: fallback, index: index, cache: cache)
                if let name = resolved.erasedQualifiedName { queue.append(name) }
            }
        }
        return visited
    }

    /// Source stubs store `extends Animal` as `.unresolved("Animal")`. Class files already carry a
    /// qualified `.classType`. Resolve the simple name in the declaring file's own package and
    /// imports (not the call site's — `import b.Animal` lives on Dog's file, not the caller's).
    private static func resolveSupertype(
        _ type: JavaTypeRef, declaredOn stub: JavaClassStub, context: JavaResolutionContext, index: JavaIndex, cache: DeclaringFileCache
    ) async -> JavaTypeRef {
        if case .classType = type { return type }
        guard case .unresolved = type else { return type }
        // A qualified supertype as written (`implements java.io.Serializable`): source stubs
        // spell it `.unresolved`, and no scope lookup applies — it names the stub directly.
        if case .unresolved(let dotted, let arguments) = type, dotted.contains("."),
           await index.classStub(qualifiedName: dotted) != nil {
            return .classType(qualifiedName: dotted, arguments: arguments, outer: nil)
        }
        if let fileContext = await contextOfDeclaringFile(stub, cache: cache) {
            let resolved = await JavaTypeResolver.resolve(type, context: fileContext, index: index)
            if case .classType = resolved { return resolved }
        }
        let resolvedAtCall = await JavaTypeResolver.resolve(type, context: context, index: index)
        if case .classType = resolvedAtCall { return resolvedAtCall }
        if case .unresolved(let simpleName, let arguments) = type {
            let samePackage = stub.packageName.isEmpty ? simpleName : "\(stub.packageName).\(simpleName)"
            if await index.classStub(qualifiedName: samePackage) != nil {
                return .classType(qualifiedName: samePackage, arguments: arguments, outer: nil)
            }
        }
        return resolvedAtCall
    }

    /// The resolution context of a source stub's own file (its package and imports), falling
    /// back to just its package when the file can't be read. `nil` for class-file stubs, whose
    /// types are already qualified.
    private static func sourceDeclarationContext(of stub: JavaClassStub, cache: DeclaringFileCache) async -> JavaResolutionContext? {
        guard case .source = stub.origin else { return nil }
        if let context = await contextOfDeclaringFile(stub, cache: cache) {
            return context
        }
        return JavaResolutionContext(
            packageName: stub.packageName, imports: [],
            enclosingTypeQualifiedNames: [stub.qualifiedName], typeParameterNames: Set(stub.typeParameters.map(\.name))
        )
    }

    /// `methods` (declared on `stub`) with their parameter types resolved against the declaring
    /// file, so overload choice can compare them with argument types.
    static func resolvingParameters(of methods: [JavaMethodStub], declaredOn stub: JavaClassStub, index: JavaIndex) async -> [JavaMethodStub] {
        guard let base = await sourceDeclarationContext(of: stub, cache: DeclaringFileCache()) else { return methods }
        var result: [JavaMethodStub] = []
        for method in methods {
            let context = base.entering(methodTypeParameters: method.typeParameters)
            var parameters: [JavaParameterStub] = []
            for parameter in method.parameters {
                parameters.append(JavaParameterStub(name: parameter.name, type: await resolvedDeclaration(parameter.type, in: context, index: index)))
            }
            result.append(JavaMethodStub(
                name: method.name, typeParameters: method.typeParameters, parameters: parameters, returnType: method.returnType,
                thrownTypes: method.thrownTypes, modifiers: method.modifiers, isConstructor: method.isConstructor, javadoc: method.javadoc
            ))
        }
        return result
    }

    /// The type variables of the enclosing types an inner class instance carries (`Outer<String>.Inner`
    /// maps `T` to `String`), walked outward through the `outer` links.
    private static func outerSubstitution(of outer: JavaTypeRef?, index: JavaIndex) async -> [String: JavaTypeRef] {
        guard case .classType(let name, let arguments, let next)? = outer else { return [:] }
        var map = await substitutionMap(forTypeArguments: arguments, appliedTo: name, index: index)
        for (variable, type) in await outerSubstitution(of: next, index: index) where map[variable] == nil { map[variable] = type }
        return map
    }

    /// A member class of a generic class, written by its simple name inside that class (`Inner`),
    /// is `Outer<T>.Inner`: the reference carries the enclosing type's variables, so a receiver
    /// `Outer<String>` hands `String` on to what it returns (`outer.inner().get()` is a `String`).
    /// Static member classes, interfaces, enums and records have no enclosing instance.
    private static func attachingOuter(_ type: JavaTypeRef, declaredIn stub: JavaClassStub, index: JavaIndex) async -> JavaTypeRef {
        guard !stub.typeParameters.isEmpty else { return type }
        switch type {
        case .classType(let name, let arguments, nil) where name.hasPrefix(stub.qualifiedName + "."):
            guard !name.dropFirst(stub.qualifiedName.count + 1).contains("."),
                  let member = await index.classStub(qualifiedName: name),
                  member.kind == .classKind, !member.modifiers.contains(.staticFlag) else { return type }
            let enclosing = JavaTypeRef.classType(
                qualifiedName: stub.qualifiedName,
                arguments: stub.typeParameters.map { .type(.typeVariable(name: $0.name)) },
                outer: nil
            )
            return .classType(qualifiedName: name, arguments: arguments, outer: enclosing)
        case .array(let element):
            return .array(element: await attachingOuter(element, declaredIn: stub, index: index))
        default:
            return type
        }
    }

    private static func resolvedDeclaration(_ type: JavaTypeRef, in context: JavaResolutionContext?, index: JavaIndex) async -> JavaTypeRef {
        guard let context, containsUnresolved(type) else { return type }
        return await JavaCompletionStageTimer.measure("members.resolve") { await JavaTypeResolver.resolve(type, context: context, index: index) }
    }

    private static func containsUnresolved(_ type: JavaTypeRef) -> Bool {
        switch type {
        case .unresolved: return true
        case .array(let element): return containsUnresolved(element)
        case .classType(_, let arguments, let outer):
            return (outer.map(containsUnresolved) ?? false) || arguments.contains {
                switch $0 {
                case .type(let t), .wildcard(.extends(let t)?), .wildcard(.superBound(let t)?): return containsUnresolved(t)
                case .wildcard(nil): return false
                }
            }
        case .wildcard(.extends(let t)?), .wildcard(.superBound(let t)?): return containsUnresolved(t)
        default: return false
        }
    }

    private static func contextOfDeclaringFile(_ stub: JavaClassStub, cache: DeclaringFileCache) async -> JavaResolutionContext? {
        guard case .source(let url, _) = stub.origin else { return nil }
        let key = url.standardizedFileURL.path
        let file: JavaSourceFileStubs
        if let cached = cache.files[key] {
            file = cached
        } else {
            guard let text = await JavaCompletionStageTimer.measure("members.declFileRead", { await sourceText(at: url) }) else { return nil }
            // The shared memo, not a parse of its own: resolving one simple name can walk the supertypes of
            // the class around it, and each walk used to parse every ancestor's file again (a 500-line
            // class cost ~110 ms the first time a file completed on it). Same text, same tree and stubs.
            file = JavaCompletionStageTimer.measure("members.declFileBuild") {
                JavaParseMemo.shared.parsed(source: text, url: url)?.stubs ?? JavaSourceFileStubs(packageName: "", imports: [], classes: [])
            }
            cache.files[key] = file
        }
        // A nested type sees the types declared in the classes around it (`Outer.Handler` from
        // `Outer.Mode`), innermost first.
        var enclosing = [stub.qualifiedName]
        var outer = stub.outerQualifiedName
        while let name = outer {
            enclosing.append(name)
            outer = nil
            if let dot = name.lastIndex(of: ".") {
                let parent = String(name[..<dot])
                if parent.count > file.packageName.count { outer = parent }
            }
        }
        return JavaResolutionContext(
            packageName: file.packageName,
            imports: file.imports,
            enclosingTypeQualifiedNames: enclosing,
            typeParameterNames: Set(stub.typeParameters.map(\.name))
        )
    }

    private static func sourceText(at url: URL) async -> String? {
        if let provider = sourceTextProvider, let text = await provider(url) {
            return text
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Generic substitution

    /// Builds the map from a declaring type's own type-parameter names to the concrete arguments a
    /// subtype applied when referencing it (e.g. descending from `ArrayList<String>` to its
    /// superclass `AbstractList<E>` builds `["E": String]`). Needs an index lookup for the
    /// declaring type's parameter *names* (the reference itself only carries argument values).
    private static func substitutionMap(forTypeArguments arguments: [JavaTypeArgument], appliedTo qualifiedName: String, index: JavaIndex) async -> [String: JavaTypeRef] {
        guard !arguments.isEmpty, let stub = await index.classStub(qualifiedName: qualifiedName), !stub.typeParameters.isEmpty else {
            return [:]
        }
        var map: [String: JavaTypeRef] = [:]
        for (parameter, argument) in zip(stub.typeParameters, arguments) {
            switch argument {
            case .type(let t):
                map[parameter.name] = t
            case .wildcard(.extends(let t)):
                map[parameter.name] = t
            case .wildcard(.superBound(let t)):
                map[parameter.name] = t
            case .wildcard(nil):
                map[parameter.name] = parameter.bounds.first ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            }
        }
        return map
    }

    /// Names of `qualifiedName`'s own type parameters that `arguments` bind to `? super X`.
    private static func lowerBoundedParameters(forTypeArguments arguments: [JavaTypeArgument], appliedTo qualifiedName: String, index: JavaIndex) async -> Set<String> {
        guard !arguments.isEmpty, let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        var names = Set<String>()
        for (parameter, argument) in zip(stub.typeParameters, arguments) {
            if case .wildcard(.superBound) = argument { names.insert(parameter.name) }
        }
        return names
    }

    /// A supertype written `AbstractList<E>` in a class whose `E` is `? super X` keeps that
    /// variable lower-bounded one level up: `ArrayList<? super Integer>.get` is declared on
    /// `AbstractList`, and must not turn `E` back into `Integer` there.
    private static func inheritedLowerBounded(declared: JavaTypeRef, lowerOnly: Set<String>, appliedTo qualifiedName: String, index: JavaIndex) async -> Set<String> {
        guard !lowerOnly.isEmpty, case .classType(_, let arguments, _) = declared,
              let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        var names = Set<String>()
        for (parameter, argument) in zip(stub.typeParameters, arguments) {
            if case .type(.typeVariable(let name)) = argument, lowerOnly.contains(name) { names.insert(parameter.name) }
        }
        return names
    }

    private static func substitute(_ type: JavaTypeRef, using map: [String: JavaTypeRef]) -> JavaTypeRef {
        JavaTypeSystem.substitute(type, using: map)
    }

    private static func erasedKey(_ type: JavaTypeRef) -> String {
        JavaTypeSystem.erasedName(of: type)
    }
}

// MARK: - Direct supertypes

extension JavaMemberLookup {
    /// `type` viewed as its supertype `target`, with type arguments carried through each level:
    /// `ArrayList<User>` as `java.util.Collection` is `Collection<User>`. `nil` when `target` is
    /// not a supertype. A raw `type` gives `target` with no arguments.
    public static func asSupertype(_ type: JavaTypeRef, named target: String, index: JavaIndex) async -> JavaTypeRef? {
        guard case .classType(let start, let arguments, _) = type else { return nil }
        let cache = DeclaringFileCache()
        var visited = Set<String>()
        // Empty arguments mean "raw" only when the type actually declares type parameters;
        // a non-generic start (empty because there is nothing to fill) views its supertypes
        // with their written arguments, not as raw.
        let startDeclaresParameters = await index.classStub(qualifiedName: start).map { !$0.typeParameters.isEmpty } ?? false
        var queue: [(name: String, substitution: [String: JavaTypeRef], isRaw: Bool)] = [
            (start, await substitutionMap(forTypeArguments: arguments, appliedTo: start, index: index), arguments.isEmpty && startDeclaresParameters)
        ]
        var position = 0
        while position < queue.count {
            let (name, substitution, isRaw) = queue[position]
            position += 1
            guard visited.insert(name).inserted, let stub = await index.classStub(qualifiedName: name) else { continue }
            if name == target {
                guard !isRaw else { return .classType(qualifiedName: name, arguments: [], outer: nil) }
                let viewed = stub.typeParameters.map { parameter -> JavaTypeArgument in
                    .type(substitution[parameter.name] ?? .typeVariable(name: parameter.name))
                }
                return .classType(qualifiedName: name, arguments: viewed, outer: nil)
            }
            let fallback = JavaResolutionContext(packageName: stub.packageName, imports: [])
            var supertypes: [JavaTypeRef] = []
            if stub.kind != .interfaceKind, let superclass = stub.superclass { supertypes.append(superclass) }
            supertypes += stub.interfaces
            for supertype in supertypes {
                let resolved = await resolveSupertype(substitute(supertype, using: substitution), declaredOn: stub, context: fallback, index: index, cache: cache)
                guard case .classType(let superName, let superArguments, _) = resolved else { continue }
                queue.append((superName, await substitutionMap(forTypeArguments: superArguments, appliedTo: superName, index: index), isRaw || superArguments.isEmpty))
            }
            if target == "java.lang.Object", stub.kind != .interfaceKind {
                queue.append(("java.lang.Object", [:], true))
            }
        }
        return nil
    }

    /// The simple names of every nested type declared anywhere in `qualifiedName`'s
    /// superclass/interface chain, or nil when the hierarchy is open: a reached class with no
    /// stub, a supertype that does not resolve to a class type, a source class in the chain
    /// whose file imports from `lombok` (generated members never appear in source stubs;
    /// compiled classes are fine), an unreadable source declaring file, or a missing
    /// `java.lang.Object`/`java.lang.annotation.Annotation`.
    ///
    /// The member walk silently drops a supertype it cannot resolve, which is harmless for
    /// completion but would make an "unresolved member" verdict report every inherited member
    /// of a class extending an unindexed jar, Kotlin or generated class.
    static func closedHierarchy(of qualifiedName: String, context: JavaResolutionContext, index: JavaIndex) async -> Set<String>? {
        let cache = DeclaringFileCache()
        var nested = Set<String>()
        var visited = Set<String>()
        var queue = [qualifiedName]
        while let name = queue.popLast() {
            guard visited.insert(name).inserted else { continue }
            guard let stub = await index.classStub(qualifiedName: name) else { return nil }
            if case .source = stub.origin {
                guard let fileContext = await contextOfDeclaringFile(stub, cache: cache),
                      !fileContext.imports.contains(where: { $0.qualifiedName == "lombok" || $0.qualifiedName.hasPrefix("lombok.") })
                else { return nil }
            }
            for inner in stub.innerTypeNames {
                nested.insert(String(inner.split(separator: ".").last ?? Substring(inner)))
            }
            if stub.kind != .interfaceKind, let superclass = stub.superclass {
                let resolved = await resolveSupertype(superclass, declaredOn: stub, context: context, index: index, cache: cache)
                guard case .classType(let superName, _, _) = resolved else { return nil }
                queue.append(superName)
            } else if name != "java.lang.Object" {
                switch stub.kind {
                case .classKind, .enumKind, .recordKind:
                    queue.append("java.lang.Object")
                case .interfaceKind:
                    // JLS 9.2 gives interfaces `Object`'s public methods.
                    queue.append("java.lang.Object")
                case .annotationKind:
                    queue.append("java.lang.annotation.Annotation")
                }
            }
            for iface in stub.interfaces {
                let resolved = await resolveSupertype(iface, declaredOn: stub, context: context, index: index, cache: cache)
                guard case .classType(let ifaceName, _, _) = resolved else { return nil }
                queue.append(ifaceName)
            }
        }
        return nested
    }

    /// The types `qualifiedName` directly extends or implements, superclass first, each resolved
    /// against the declaring file's package and imports. A class with no declared superclass
    /// extends `java.lang.Object`; an interface does not. Supertypes that cannot be resolved are
    /// left out.
    public static func directSupertypeNames(of qualifiedName: String, index: JavaIndex) async -> [String] {
        guard let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        let cache = DeclaringFileCache()
        let fallback = JavaResolutionContext(packageName: stub.packageName, imports: [])
        var names: [String] = []
        if let superclass = stub.superclass {
            let resolved = await resolveSupertype(superclass, declaredOn: stub, context: fallback, index: index, cache: cache)
            if let name = resolved.erasedQualifiedName { names.append(name) }
        } else if qualifiedName != "java.lang.Object",
                  stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind {
            names.append("java.lang.Object")
        }
        for interface in stub.interfaces {
            let resolved = await resolveSupertype(interface, declaredOn: stub, context: fallback, index: index, cache: cache)
            if let name = resolved.erasedQualifiedName, !names.contains(name) { names.append(name) }
        }
        return names
    }
}
