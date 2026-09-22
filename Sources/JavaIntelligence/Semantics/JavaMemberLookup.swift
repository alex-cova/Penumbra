import Foundation

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
    /// All members visible on `type` from the perspective of `context`, most-derived first,
    /// deduplicated so an override hides its superclass/interface original (matched by name +
    /// erased parameter list) and filtered by ``JavaMemberLookupMode`` and access.
    public static func members(
        of type: JavaTypeRef, mode: JavaMemberLookupMode, context: JavaResolutionContext, index: JavaIndex
    ) async -> [JavaResolvedMember] {
        if case .array(let element) = type {
            return arrayMembers(elementType: element)
        }
        guard case .classType(let qualifiedName, let arguments, _) = type else {
            return []
        }
        let selfHierarchy = await ancestorQualifiedNames(of: context.topLevelTypeQualifiedName, index: index)

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

            for field in stub.fields {
                guard mode == .instance || field.modifiers.contains(.staticFlag) || field.modifiers.contains(.enumConstant) else { continue }
                guard await isAccessible(field.modifiers, declaringClass: currentName, declaringPackage: stub.packageName, context: context, selfHierarchy: selfHierarchy, index: index) else { continue }
                let key = "field:\(field.name)"
                guard seenSignatures.insert(key).inserted else { continue }
                let substituted = substitute(field.type, using: substitution)
                result.append(.field(JavaFieldStub(name: field.name, type: substituted, modifiers: field.modifiers, javadoc: field.javadoc), declaringClass: currentName))
            }
            for method in stub.methods where !method.isConstructor {
                guard mode == .instance || method.modifiers.contains(.staticFlag) else { continue }
                guard await isAccessible(method.modifiers, declaringClass: currentName, declaringPackage: stub.packageName, context: context, selfHierarchy: selfHierarchy, index: index) else { continue }
                let substitutedParams = method.parameters.map { JavaParameterStub(name: $0.name, type: substitute($0.type, using: substitution)) }
                let key = "method:\(method.name)(\(substitutedParams.map { erasedKey($0.type) }.joined(separator: ",")))"
                guard seenSignatures.insert(key).inserted else { continue }
                let substitutedMethod = JavaMethodStub(
                    name: method.name,
                    typeParameters: method.typeParameters,
                    parameters: substitutedParams,
                    returnType: substitute(method.returnType, using: substitution),
                    thrownTypes: method.thrownTypes,
                    modifiers: method.modifiers,
                    isConstructor: false,
                    javadoc: method.javadoc
                )
                result.append(.method(substitutedMethod, declaringClass: currentName))
            }

            if let superclass = stub.superclass, stub.kind != .interfaceKind {
                let substitutedSuper = substitute(superclass, using: substitution)
                if case .classType(let superName, let superArgs, _) = substitutedSuper {
                    queue.append((superName, await substitutionMap(forTypeArguments: superArgs, appliedTo: superName, index: index)))
                }
            } else if (stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind),
                      stub.superclass == nil, currentName != "java.lang.Object" {
                queue.append(("java.lang.Object", [:]))
            }
            for iface in stub.interfaces {
                let substitutedIface = substitute(iface, using: substitution)
                if case .classType(let ifaceName, let ifaceArgs, _) = substitutedIface {
                    queue.append((ifaceName, await substitutionMap(forTypeArguments: ifaceArgs, appliedTo: ifaceName, index: index)))
                }
            }
        }
        return result
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

    /// Every ancestor (superclass chain + interfaces, transitively) of `qualifiedName`, used only
    /// to decide protected-member visibility ("is the querying type a subclass of the declaring
    /// type"). Cycles are guarded; this only needs class identity, not member types, so it doesn't
    /// substitute generics.
    private static func ancestorQualifiedNames(of qualifiedName: String?, index: JavaIndex) async -> Set<String> {
        guard let qualifiedName else { return [] }
        var visited = Set<String>()
        var queue = [qualifiedName]
        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            guard let stub = await index.classStub(qualifiedName: next) else { continue }
            if let superclassName = stub.superclass?.erasedQualifiedName {
                queue.append(superclassName)
            }
            queue.append(contentsOf: stub.interfaces.compactMap(\.erasedQualifiedName))
        }
        return visited
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
