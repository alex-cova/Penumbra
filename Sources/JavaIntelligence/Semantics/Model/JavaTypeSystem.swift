import Foundation

/// The one place for Java type operations (JLS 4–5): substitution, erasure and least upper
/// bounds over ``JavaTypeRef``, plus the `var` inference seam. Pure and synchronous except
/// where the index is needed (`asSuper` stays on `JavaMemberLookup` until Phase 4 attribution;
/// the lub reaches it through the public `asSupertype`/`supertypeClosure` queries).
///
/// Deliberately v1-narrow: no `JavaType` nominal yet (a resolved type with its declaration —
/// that needs the Phase 4 attributor), no contexts (strict/loose/casting), no capture
/// conversion, no generic lub arguments. Each site documents what it approximates.
public enum JavaTypeSystem {
    // MARK: - substitution

    /// Replaces type variables by name, recursing through arguments, arrays and bounds.
    /// Moved here from `JavaMemberLookup`, which delegates: one implementation, not two.
    public static func substitute(_ type: JavaTypeRef, using map: [String: JavaTypeRef]) -> JavaTypeRef {
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

    // MARK: - erasure (JLS 4.6)

    /// Erases a type: parameterized types go raw, arrays recurse, an unboundable type variable
    /// (whose bounds live on stubs, not on the reference) erases to `java.lang.Object`, and
    /// `? extends B` erases to the erasure of `B`. An unresolved name stays unresolved: erasure
    /// cannot qualify what attribution has not resolved yet.
    public static func erasure(of type: JavaTypeRef) -> JavaTypeRef {
        switch type {
        case .primitive, .void:
            return type
        case .classType(let qualifiedName, _, let outer):
            return .classType(qualifiedName: qualifiedName, arguments: [], outer: outer.map { erasure(of: $0) })
        case .array(let element):
            return .array(element: erasure(of: element))
        case .typeVariable:
            return .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        case .wildcard(.extends(let bound)):
            return erasure(of: bound)
        case .wildcard:
            return .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        case .unresolved:
            return type
        }
    }

    /// The erased name used for identity keys (`method:String(int)` style): primitives by
    /// keyword, everything class-like by qualified (or simple, when unresolved) name, arrays
    /// by element plus `[]`. Unbounded variables and wildcards read as `Object`.
    public static func erasedName(of type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let p): return p.rawValue
        case .void: return "void"
        case .classType(let qualifiedName, _, _): return qualifiedName
        case .array(let element): return "\(erasedName(of: element))[]"
        case .typeVariable: return "Object"
        case .wildcard: return "Object"
        case .unresolved(let simpleName, _): return simpleName
        }
    }

    // MARK: - least upper bound (JLS 4.10.4), v1: erased, for multi-catch

    /// The least upper bound of `alternatives`, erased: alternatives with one erasure yield it
    /// (the original reference, arguments preserved); otherwise the most specific common
    /// supertype found through the index, raw. `nil` when an alternative is not a resolvable
    /// class type or the hierarchies do not meet — callers keep today's behavior then (for
    /// multi-catch, the first alternative).
    ///
    /// Not a full JLS lub: no type arguments on the result (capture conversion is Phase 4),
    /// no interfacean lub cocktail beyond the erased meet. Sound for member lookup on the
    /// result, which is what multi-catch needs.
    public static func lub(of alternatives: [JavaTypeRef], index: JavaIndex) async -> JavaTypeRef? {
        let erased = alternatives.map { erasure(of: $0) }
        guard erased.allSatisfy({ $0.erasedQualifiedName != nil }) else { return nil }
        let names = erased.map { $0.erasedQualifiedName! }
        if Set(names).count == 1 { return alternatives[0] }
        // One alternative already above the rest: it is the bound, arguments and all.
        // `java.lang.Object` is above everything (JLS 4.10.2) without needing a stub for it.
        for (position, name) in names.enumerated() {
            if name == "java.lang.Object" { return alternatives[position] }
            var aboveAll = true
            for (otherPosition, _) in names.enumerated() where otherPosition != position {
                if await JavaMemberLookup.asSupertype(erased[otherPosition], named: name, index: index) == nil {
                    aboveAll = false
                    break
                }
            }
            if aboveAll { return alternatives[position] }
        }
        // Erased meet: intersect the supertype closures, keep the most specific member.
        var common: Set<String>? = nil
        for name in names {
            let closure = await JavaMemberLookup.supertypeClosure(of: name, index: index)
            common = common.map { $0.intersection(closure) } ?? closure
        }
        guard let meeting = common, !meeting.isEmpty else { return nil }
        // Prefer an alternative's own reference when the winner is among them.
        if let winner = await mostSpecific(in: meeting, index: index) {
            if let position = names.firstIndex(of: winner) { return alternatives[position] }
            return .classType(qualifiedName: winner, arguments: [], outer: nil)
        }
        return nil
    }

    /// The effective type of a multi-catch parameter: the lub of its alternatives, or the
    /// first alternative when the lub is unavailable. Empty alternatives read as
    /// `Throwable`, mirroring the scope tree's fallback for a missing `catch_type`.
    public static func effectiveCatchType(alternatives: [JavaTypeRef], index: JavaIndex) async -> JavaTypeRef {
        guard !alternatives.isEmpty else {
            return .unresolved(simpleName: "Throwable", arguments: [])
        }
        return await lub(of: alternatives, index: index) ?? alternatives[0]
    }

    /// The member of `candidates` that is a subtype of every other member, or `nil` when the
    /// index cannot order them. Pairwise `asSuper` checks, so callers keep the set small.
    static func mostSpecific(in candidates: Set<String>, index: JavaIndex) async -> String? {
        guard candidates.count <= 16 else { return nil }
        for candidate in candidates {
            let viewed = JavaTypeRef.classType(qualifiedName: candidate, arguments: [], outer: nil)
            var belowAll = true
            for other in candidates where other != candidate {
                // No stub needed: every reference type converts to `Object` (JLS 4.10.2).
                if other == "java.lang.Object" { continue }
                if await JavaMemberLookup.asSupertype(viewed, named: other, index: index) == nil {
                    belowAll = false
                    break
                }
            }
            if belowAll { return candidate }
        }
        return nil
    }

    // MARK: - `var` inference seam

    /// The declared type of a `var` local once its initializer is typed: the initializer type,
    /// unless it is still unknown. `JavaExpressionTyper.resolvingVarLocals` assigns through
    /// here, so Phase 4 attribution plugs richer inference (denotability, anonymous-class
    /// supertypes, poly expressions) in one place.
    public static func inferredVarType(initializerType: JavaTypeRef?) -> JavaTypeRef? {
        guard let initializerType else { return nil }
        if case .unresolved("var", _) = initializerType { return nil }
        return initializerType
    }
}
