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
        of type: JavaTypeRef, mode: JavaMemberLookupMode, context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaResolvedMember] {
        if case .array(let element) = type {
            return arrayMembers(elementType: element)
        }
        if case .typeVariable = type {
            // No bound information travels with a type variable reference; offer `Object`'s.
            return await members(of: .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil), mode: mode, context: context, index: index)
        }
        guard case .classType(let qualifiedName, let arguments, _) = type else {
            return []
        }
        let selfHierarchy = await ancestorQualifiedNames(of: context.topLevelTypeQualifiedName, index: index)
        let fileCache = DeclaringFileCache()

        var seenSignatures = Set<String>()
        var result: [JavaResolvedMember] = []
        var visitedClasses = Set<String>()
        var queue: [(qualifiedName: String, substitution: [String: JavaTypeRef])] = [
            (qualifiedName, await substitutionMap(forTypeArguments: arguments, appliedTo: qualifiedName, index: index))
        ]
        // Processed as a FIFO queue (not a stack) so the class itself and its direct supertypes
        // are visited -- and their members recorded as "more derived" -- before Object/deeper
        // ancestors, which is what the dedup-by-override logic below relies on.
        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentName, substitution) = queue[queueIndex]
            queueIndex += 1
            guard visitedClasses.insert(currentName).inserted else { continue }
            guard let stub = await index.classStub(qualifiedName: currentName) else { continue }
            // Source stubs keep type names as written (`List<StockSet>`); they must be resolved
            // against the *declaring* file's imports, not the file asking for completion.
            let declaringContext = await sourceDeclarationContext(of: stub, cache: fileCache)

            for field in stub.fields where !field.modifiers.contains(.synthetic) {
                guard mode == .instance || field.modifiers.contains(.staticFlag) || field.modifiers.contains(.enumConstant) else { continue }
                guard await isAccessible(field.modifiers, declaringClass: currentName, declaringPackage: stub.packageName, context: context, selfHierarchy: selfHierarchy, index: index) else { continue }
                let key = "field:\(field.name)"
                guard seenSignatures.insert(key).inserted else { continue }
                let substituted = substitute(await resolvedDeclaration(field.type, in: declaringContext, index: index), using: substitution)
                result.append(.field(JavaFieldStub(name: field.name, type: substituted, modifiers: field.modifiers, javadoc: field.javadoc), declaringClass: currentName))
            }
            for method in stub.methods where !method.isConstructor && !method.modifiers.contains(.synthetic) && !method.modifiers.contains(.bridge) && !method.name.hasPrefix("lambda$") {
                guard mode == .instance || method.modifiers.contains(.staticFlag) else { continue }
                guard await isAccessible(method.modifiers, declaringClass: currentName, declaringPackage: stub.packageName, context: context, selfHierarchy: selfHierarchy, index: index) else { continue }
                let methodContext = declaringContext?.entering(methodTypeParameters: method.typeParameters)
                var substitutedParams: [JavaParameterStub] = []
                for parameter in method.parameters {
                    let declared = await resolvedDeclaration(parameter.type, in: methodContext, index: index)
                    substitutedParams.append(JavaParameterStub(name: parameter.name, type: substitute(declared, using: substitution)))
                }
                let declaredReturn = await resolvedDeclaration(method.returnType, in: methodContext, index: index)
                let key = "method:\(method.name)(\(substitutedParams.map { erasedKey($0.type) }.joined(separator: ",")))"
                guard seenSignatures.insert(key).inserted else { continue }
                let substitutedMethod = JavaMethodStub(
                    name: method.name,
                    typeParameters: method.typeParameters,
                    parameters: substitutedParams,
                    returnType: substitute(declaredReturn, using: substitution),
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
                    queue.append((superName, await substitutionMap(forTypeArguments: superArgs, appliedTo: superName, index: index)))
                }
            } else if (stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind),
                      stub.superclass == nil, currentName != "java.lang.Object" {
                queue.append(("java.lang.Object", [:]))
            }
            for iface in stub.interfaces {
                let substitutedIface = substitute(iface, using: substitution)
                let resolvedIface = await resolveSupertype(substitutedIface, declaredOn: stub, context: context, index: index, cache: fileCache)
                if case .classType(let ifaceName, let ifaceArgs, _) = resolvedIface {
                    queue.append((ifaceName, await substitutionMap(forTypeArguments: ifaceArgs, appliedTo: ifaceName, index: index)))
                }
            }
        }
        return result
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
        let selfHierarchy = await ancestorQualifiedNames(of: context.topLevelTypeQualifiedName, index: index)
        var visible: [JavaMethodStub] = []
        for method in stub.methods where method.isConstructor {
            if await isAccessible(
                method.modifiers, declaringClass: qualifiedName, declaringPackage: stub.packageName,
                context: context, selfHierarchy: selfHierarchy, index: index
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

    private static func arrayMembers(elementType: JavaTypeRef) -> [JavaResolvedMember] {
        [
            .field(JavaFieldStub(name: "length", type: .primitive(.int), modifiers: [.publicFlag, .finalFlag]), declaringClass: "<array>"),
            .method(JavaMethodStub(name: "clone", parameters: [], returnType: .array(element: elementType), modifiers: [.publicFlag]), declaringClass: "<array>")
        ]
    }

    // MARK: - Access control

    private static func isAccessible(
        _ modifiers: JavaModifiers, declaringClass: String, declaringPackage: String,
        context: JavaResolutionContext, selfHierarchy: Set<String>, index: JavaIndex
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
            return samePackage || selfHierarchy.contains(declaringClass)
        }
        // Package-private (none of public/private/protected).
        return samePackage
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
    /// substitute generics.
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

    private static func resolvedDeclaration(_ type: JavaTypeRef, in context: JavaResolutionContext?, index: JavaIndex) async -> JavaTypeRef {
        guard let context, containsUnresolved(type) else { return type }
        return await JavaTypeResolver.resolve(type, context: context, index: index)
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
            guard let text = await sourceText(at: url) else { return nil }
            file = JavaSourceStubBuilder.build(source: text, url: url)
            cache.files[key] = file
        }
        return JavaResolutionContext(
            packageName: file.packageName,
            imports: file.imports,
            enclosingTypeQualifiedNames: [stub.qualifiedName],
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

    private static func substitute(_ type: JavaTypeRef, using map: [String: JavaTypeRef]) -> JavaTypeRef {
        guard !map.isEmpty else { return type }
        switch type {
        case .primitive, .void:
            return type
        case .typeVariable(let name):
            return map[name] ?? type
        case .array(let element):
            return .array(element: substitute(element, using: map))
        case .classType(let qualifiedName, let arguments, let outer):
            return .classType(
                qualifiedName: qualifiedName,
                arguments: arguments.map { substituteArgument($0, using: map) },
                outer: outer.map { substitute($0, using: map) }
            )
        case .wildcard(let bound):
            return .wildcard(bound: bound.map { substituteBound($0, using: map) })
        case .unresolved(let simpleName, let arguments):
            return .unresolved(simpleName: simpleName, arguments: arguments.map { substituteArgument($0, using: map) })
        }
    }

    private static func substituteArgument(_ argument: JavaTypeArgument, using map: [String: JavaTypeRef]) -> JavaTypeArgument {
        switch argument {
        case .type(let t): return .type(substitute(t, using: map))
        case .wildcard(let bound): return .wildcard(bound.map { substituteBound($0, using: map) })
        }
    }

    private static func substituteBound(_ bound: JavaWildcardBound, using map: [String: JavaTypeRef]) -> JavaWildcardBound {
        switch bound {
        case .extends(let t): return .extends(substitute(t, using: map))
        case .superBound(let t): return .superBound(substitute(t, using: map))
        }
    }

    private static func erasedKey(_ type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let p): return p.rawValue
        case .void: return "void"
        case .classType(let qualifiedName, _, _): return qualifiedName
        case .array(let element): return "\(erasedKey(element))[]"
        case .typeVariable: return "Object" // erasure of an unbounded/still-generic type variable
        case .wildcard: return "Object"
        case .unresolved(let simpleName, _): return simpleName
        }
    }
}
