import Foundation

/// The external half of field lookup: fields a body inherits from supertypes the file does
/// not declare, resolved through the index.
///
/// Inside one file, `JavaDeclaredTypes` answers a field from the declaration it can see.
/// But in `class Inner extends ExternalBase`, a name the file never declares may still be
/// an inherited member of `Inner`, and Java resolves inherited members before enclosing
/// scope — so falling through to `Outer`'s field would be wrong. This prepass collects the
/// inherited field names from outside the file so the lookup can stop instead of guessing.
///
/// The pipeline runs `prepare` once per pass, before the node rules
/// (`JavaInspectionPipeline.inspect`). The result lives on `JavaDeclarationCache` as
/// `externalFields[bodyRange]`, either `.known` (the inherited names and their declared
/// types) or `.open` (a missing stub or an unresolvable supertype, using the same rule as
/// `JavaMemberLookup.closedHierarchy`: what cannot be seen may declare the name).
/// A body whose supertypes are all declared in the file gets no entry: the in-file walk
/// already answers it exactly.
///
/// `memberFieldType` consults the table after its own and in-file inherited fields, and
/// `variableType` stops (returns `nil`) instead of moving outward when the table is `.open`
/// — or, when no prepass ran (fix rebuilds, anything without an index), when the body
/// names an external supertype. `.known` without the name, and bodies with no entry,
/// continue outward as before. Top-level classes never change: nothing lies past their
/// body, so stopping and falling through both answer `nil`.
///
/// Implicit supertypes are skipped: `java.lang.Object` and `java.lang.Record` declare no
/// fields, and `java.lang.Enum`'s fields are all private (never inherited), so resolving
/// them would only add openness without answers.
enum JavaInheritedFields {
    /// Whether `variableType` must stop at `body` instead of searching enclosing scopes
    /// for a name the body and its visible supertypes do not declare.
    static func shadowsOuterScope(body: SyntaxNode) -> Bool {
        let cache = body.tree.declarationCache
        if cache.externalFieldsPrepared {
            if case .open = cache.externalFields(forBodyAt: body.startByte) { return true }
            return false
        }
        // No prepass ran: be conservative only for bodies that name an external supertype.
        return hasExternalSupertypes(body: body)
    }

    /// Whether the body's type names a supertype no declaration of this file answers.
    static func hasExternalSupertypes(body: SyntaxNode) -> Bool {
        !externalSupertypeRefs(of: owner(of: body), from: body).isEmpty
    }

    /// Collects external inherited fields for every body with an external supertype.
    static func prepare(context: JavaInspectionContext) async {
        let tree = context.tree
        var tables: [Int: JavaExternalFields] = [:]
        for (body, owner) in bodies(in: tree.rootNode) {
            let seeds = externalSupertypeRefs(of: owner, from: owner)
            guard !seeds.isEmpty else { continue }
            tables[body.startByte] = await collect(seeds: seeds, owner: owner, context: context)
        }
        tree.declarationCache.storeExternalFields(tables)
    }

    // MARK: - Bodies and seeds (synchronous)

    /// Every body that can inherit, with the node its supertypes are read from: type
    /// declarations, enum constant bodies (supertypes of the enclosing enum) and
    /// anonymous class bodies (the created type, or its declaration's supertypes).
    private static func bodies(in root: SyntaxNode) -> [(body: SyntaxNode, owner: SyntaxNode)] {
        var result: [(SyntaxNode, SyntaxNode)] = []
        var stack = [root]
        while let node = stack.popLast() {
            switch node.type {
            case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
                if let body = node.child(byFieldName: "body") { result.append((body, node)) }
                stack.append(contentsOf: node.namedChildren.reversed())
            case "enum_constant":
                if let body = node.children.first(where: { $0.type == "class_body" }),
                   let enumNode = enclosingEnum(of: node) { result.append((body, enumNode)) }
                stack.append(contentsOf: node.namedChildren.reversed())
            case "object_creation_expression":
                if let body = node.children.first(where: { $0.type == "class_body" }) { result.append((body, node)) }
                stack.append(contentsOf: node.namedChildren.reversed())
            default:
                stack.append(contentsOf: node.namedChildren.reversed())
            }
        }
        return result
    }

    private static func owner(of body: SyntaxNode) -> SyntaxNode {
        guard let parent = body.parent else { return body }
        if parent.type == "enum_constant", let enumNode = enclosingEnum(of: parent) { return enumNode }
        return parent
    }

    private static func enclosingEnum(of node: SyntaxNode) -> SyntaxNode? {
        var current = node.parent
        while let candidate = current {
            if candidate.type == "enum_declaration" { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// The supertype references of `owner` that no declaration of this file answers,
    /// following in-file supertypes transitively (an in-file `Mid` may itself extend an
    /// external `Base`). Empty when everything is declared in the file — or when there
    /// are no explicit supertypes at all, since the implicit ones declare no fields.
    /// `scope` anchors `typeDeclaration(named:from:)` for duplicate type names.
    private static func externalSupertypeRefs(of owner: SyntaxNode, from scope: SyntaxNode, depth: Int = 0) -> [JavaTypeRef] {
        guard depth < 8 else { return [] }
        if owner.type == "object_creation_expression" {
            guard let typeNode = owner.child(byFieldName: "type") else { return [] }
            return externalSupertypeRefs(ofTypeNode: typeNode, owner: owner, depth: depth)
        }
        var refs: [JavaTypeRef] = []
        for typeNode in JavaDeclaredTypes.supertypeTypeNodes(of: owner) {
            refs += externalSupertypeRefs(ofTypeNode: typeNode, owner: scope, depth: depth)
        }
        return refs
    }

    private static func externalSupertypeRefs(ofTypeNode typeNode: SyntaxNode, owner: SyntaxNode, depth: Int) -> [JavaTypeRef] {
        let simple = JavaDeclaredTypes.simpleName(of: typeNode)
        if let declaration = JavaDeclaredTypes.typeDeclaration(named: simple, from: owner),
           declaration.byteRange != owner.byteRange {
            return externalSupertypeRefs(of: declaration, from: owner, depth: depth + 1)
        }
        return [JavaTypeNodeConverter.convert(typeNode)]
    }

    // MARK: - Collection (async, through the index)

    /// Resolves the seed supertypes as in missing-override and walks the index
    /// transitively, collecting visible (non-private, non-synthetic) inherited field
    /// names. `.open` when a seed does not resolve or a reached type has no stub or an
    /// unresolvable supertype.
    private static func collect(
        seeds: [JavaTypeRef], owner: SyntaxNode, context: JavaInspectionContext
    ) async -> JavaExternalFields {
        let enclosing = JavaCompletionProvider.enclosingTypeContext(in: context.tree, atByteOffset: owner.startByte)
        let file = context.file
        let resolution = JavaResolutionContext(
            packageName: file.packageName, imports: file.imports,
            enclosingTypeQualifiedNames: enclosing.qualifiedNames.map {
                file.packageName.isEmpty ? $0 : "\(file.packageName).\($0)"
            },
            typeParameterNames: enclosing.typeParameterNames
        )
        var queue: [String] = []
        for seed in seeds {
            let resolved = await JavaTypeResolver.resolve(seed, context: resolution, index: context.index)
            if case .classType(let name, _, _) = resolved {
                queue.append(name)
            } else if case .unresolved(let dotted, _) = resolved, dotted.contains("."),
                      await context.index.classStub(qualifiedName: dotted) != nil {
                // A qualified supertype as written (`java.io.Serializable`): used as-is
                // everywhere else, so the walk starts from it directly.
                queue.append(dotted)
            } else {
                return .open
            }
        }
        var visited = Set<String>()
        var table: [String: JavaDeclaredType] = [:]
        var nested: Set<String> = []
        var isOpen = false
        while let name = queue.popLast() {
            guard visited.insert(name).inserted else { continue }
            // `Object` (and `@interface`'s root) declare no fields; not requiring their
            // stubs keeps files without a JDK index from going `.open` everywhere.
            if name == "java.lang.Object" || name == "java.lang.annotation.Annotation" { continue }
            guard let stub = await context.index.classStub(qualifiedName: name) else { isOpen = true; continue }
            let typeParameters = Set(stub.typeParameters.map(\.name))
            for field in stub.fields where !field.modifiers.contains(.privateFlag) && !field.modifiers.contains(.synthetic) {
                if table[field.name] == nil, let type = declaredType(from: field.type, typeParameters: typeParameters) {
                    table[field.name] = type
                }
            }
            // Over-approximates toward silence: private nested types cannot clash, but
            // their flags do not travel with the name, so they count too.
            nested.formUnion(stub.innerTypeNames.map { simple($0) })
            let rawCount = (stub.superclass != nil ? 1 : 0) + stub.interfaces.count
            let supers = await JavaMemberLookup.directSupertypeNames(of: name, index: context.index)
            // `directSupertypeNames` drops what it cannot resolve; fewer names back than
            // supertypes declared means something unseen above us.
            if supers.count < rawCount { isOpen = true }
            queue += supers
        }
        if isOpen { return .open }
        return .known(fields: table, nestedTypes: nested)
    }

    /// A field stub's type as a declared type: its simple name, whether it is an array,
    /// and whether it was declared with type arguments. No substitution is applied, so
    /// `List<T> items` reads as `List` (member names never depend on arguments).
    /// A bare type variable (`T value`, `T[] values`) has no entry: downstream member
    /// lookup answers such a receiver with `Object`'s members, which false-positives on
    /// any real member, so leaving the name out keeps the lookup silent as before.
    private static func declaredType(from ref: JavaTypeRef, typeParameters: Set<String>) -> JavaDeclaredType? {
        switch ref {
        case .array(let element):
            guard let inner = declaredType(from: element, typeParameters: typeParameters) else { return nil }
            return JavaDeclaredType(name: inner.name, isArray: true, hasTypeArguments: inner.hasTypeArguments)
        case .classType(let qualifiedName, let arguments, _):
            return JavaDeclaredType(name: simple(qualifiedName), isArray: false, hasTypeArguments: !arguments.isEmpty)
        case .unresolved(let simpleName, let arguments):
            if arguments.isEmpty, typeParameters.contains(simpleName) { return nil }
            return JavaDeclaredType(name: simple(simpleName), isArray: false, hasTypeArguments: !arguments.isEmpty)
        case .primitive(let primitive):
            return JavaDeclaredType(name: primitive.rawValue, isArray: false)
        case .void:
            return JavaDeclaredType(name: "void", isArray: false)
        case .typeVariable:
            return nil
        case .wildcard:
            return JavaDeclaredType(name: "Object", isArray: false)
        }
    }

    private static func simple(_ dotted: String) -> String {
        String(dotted.split(separator: ".").last ?? Substring(dotted))
    }
}

/// External inherited members of one class body: the field names and nested type names
/// the index walk found, or `.open` when something above was unseen and may declare
/// the name. Nested names answer "would adding this import clash" exactly; `.open`
/// (or no prepass over a body with an external supertype) clashes instead.
enum JavaExternalFields: Sendable {
    case known(fields: [String: JavaDeclaredType], nestedTypes: Set<String>)
    case open
}
