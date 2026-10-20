import EditorIntelligence
import Foundation

enum JavaMissingOverrideInspection {
    static func inspect(source: String, url: URL?, index: JavaIndex, tree: JavaSyntaxTree? = nil) async -> [JavaInspection] {
        let parsedTree: JavaSyntaxTree
        if let tree {
            parsedTree = tree
        } else {
            guard let parsed = JavaSyntaxParser().parse(source), !parsed.rootNode.hasError else { return [] }
            parsedTree = parsed
        }
        let file = JavaSourceStubBuilder.build(tree: parsedTree, url: url ?? JavaNavigationSession.placeholderURL)
        var inspections: [JavaInspection] = []
        for item in await bodies(in: parsedTree, file: file, index: index) {
            let methods = methodDeclarations(in: item.body)
            var pending: [(node: SyntaxNode, keys: [String], typeParams: [String])] = []
            for methodNode in methods {
                guard methodNode.child(byFieldName: "name") != nil else { continue }
                // A static or private method can only hide or shadow, and `@Override` on it is a compile error.
                guard !methodNode.hasModifier("static"), !methodNode.hasModifier("private") else { continue }
                guard !hasOverrideModifier(methodNode) else { continue }
                pending.append((methodNode, JavaTypeKeys.keys(of: methodNode), methodTypeParameterNames(of: methodNode)))
            }
            guard !pending.isEmpty else { continue }
            // One supertype walk per (body, supertype): a class with 30 methods reuses the view.
            var viewCache: [String: [String: JavaTypeRef]?] = [:]
            for entry in pending {
                guard await shouldOverride(
                    name: entry.node.child(byFieldName: "name")!.text, keys: entry.keys,
                    bodyTypeParams: entry.typeParams, selfRef: item.selfRef,
                    typeName: item.typeName, typePackage: file.packageName, index: index,
                    includeSelf: item.includeSelf, viewCache: &viewCache
                ) else { continue }
                let nameNode = entry.node.child(byFieldName: "name")!
                let start = JavaImportInserter.textPosition(forByteOffset: entry.node.startByte, in: parsedTree.sourceBytes)
                let end = JavaImportInserter.textPosition(forByteOffset: nameNode.endByte, in: parsedTree.sourceBytes)
                inspections.append(JavaInspection(
                    id: "missing-override",
                    message: "Method '\(nameNode.text)' overrides a supertype method but lacks @Override",
                    severity: .warning,
                    range: EditorIntelligence.TextRange(start: start, end: end),
                    fixTitle: "Add @Override"
                ))
            }
        }
        return inspections
    }

    /// One method-bearing body: a named type's body, an enum constant's body (the self type
    /// is the enclosing enum), or an anonymous class body (the self type is the resolved
    /// created type with its type arguments). Constant and anonymous bodies subclass their
    /// self type, so it stays in the searched supertypes; a named type's own methods never
    /// override themselves, so it is removed.
    private struct BodyItem {
        let body: SyntaxNode
        let selfRef: JavaTypeRef
        let typeName: String
        let includeSelf: Bool
    }

    private static func bodies(in tree: JavaSyntaxTree, file: JavaSourceFileStubs, index: JavaIndex) async -> [BodyItem] {
        var items: [BodyItem] = []
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            switch node.type {
            case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
                guard node.child(byFieldName: "name") != nil,
                      let body = node.child(byFieldName: "body") else {
                    stack.append(contentsOf: node.namedChildren.reversed())
                    continue
                }
                if let qualified = qualifiedName(of: node, file: file) {
                    items.append(BodyItem(body: body, selfRef: selfRef(for: qualified, file: file), typeName: qualified, includeSelf: false))
                }
                stack.append(contentsOf: node.namedChildren.reversed())
            case "enum_constant":
                // An enum constant body is a subclass of the enclosing enum, so the
                // supertypes searched are the enum itself plus its closure.
                if let body = node.namedChildren.first(where: { $0.type == "class_body" }),
                   let enumNode = enclosingEnum(of: node),
                   let qualified = qualifiedName(of: enumNode, file: file) {
                    items.append(BodyItem(body: body, selfRef: selfRef(for: qualified, file: file), typeName: qualified, includeSelf: true))
                }
                stack.append(contentsOf: node.namedChildren.reversed())
            case "object_creation_expression":
                // `new Comparator<Foo>() { ... }`: the supertypes are the created type
                // plus its closure. A type that does not resolve gives no findings.
                if let body = node.children.first(where: { $0.type == "class_body" }),
                   let typeNode = node.child(byFieldName: "type"),
                   let (selfRef, typeName) = await anonymousSelfRef(typeNode: typeNode, at: node, tree: tree, file: file, index: index) {
                    items.append(BodyItem(body: body, selfRef: selfRef, typeName: typeName, includeSelf: true))
                }
                stack.append(contentsOf: node.namedChildren.reversed())
            default:
                stack.append(contentsOf: node.namedChildren.reversed())
            }
        }
        return items
    }

    /// The created type of an anonymous class with its type arguments, resolved the same
    /// way Go to Implementation resolves it (`Navigation/JavaGoToImplementation.swift`):
    /// the file's stubs supply the context. `nil` when it does not resolve.
    private static func anonymousSelfRef(
        typeNode: SyntaxNode, at node: SyntaxNode, tree: JavaSyntaxTree,
        file: JavaSourceFileStubs, index: JavaIndex
    ) async -> (JavaTypeRef, String)? {
        let enclosing = JavaCompletionProvider.enclosingTypeContext(in: tree, atByteOffset: node.startByte)
        let qualified = enclosing.qualifiedNames.map { file.packageName.isEmpty ? $0 : "\(file.packageName).\($0)" }
        let context = JavaResolutionContext(
            packageName: file.packageName, imports: file.imports,
            enclosingTypeQualifiedNames: qualified, typeParameterNames: enclosing.typeParameterNames
        )
        let raw = JavaTypeNodeConverter.convert(typeNode)
        let resolved = await JavaTypeResolver.resolve(raw, context: context, index: index)
        guard case .classType(let name, let arguments, _) = resolved else { return nil }
        return (.classType(qualifiedName: name, arguments: arguments, outer: nil), name)
    }

    private static func enclosingEnum(of node: SyntaxNode) -> SyntaxNode? {
        var current = node.parent
        while let candidate = current {
            if candidate.type == "enum_declaration" { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private static func qualifiedName(of typeNode: SyntaxNode, file: JavaSourceFileStubs) -> String? {
        guard let nameNode = typeNode.child(byFieldName: "name") else { return nil }
        let simple = nameNode.text
        if let outer = outerQualifiedName(of: typeNode) {
            let prefix = file.packageName.isEmpty ? outer : file.packageName + "." + outer
            return prefix + "." + simple
        }
        if !file.packageName.isEmpty { return file.packageName + "." + simple }
        return simple
    }

    /// The body's own type viewed with its type variables, so `asSupertype` can carry them
    /// through each level (`ArrayList<User>` as `Collection` is `Collection<User>`).
    private static func selfRef(for qualifiedName: String, file: JavaSourceFileStubs) -> JavaTypeRef {
        if let stub = file.classes.first(where: { $0.qualifiedName == qualifiedName }), !stub.typeParameters.isEmpty {
            return .classType(
                qualifiedName: qualifiedName,
                arguments: stub.typeParameters.map { .type(.typeVariable(name: $0.name)) },
                outer: nil
            )
        }
        return .classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
    }

    /// The type's own methods. Nested types are inspected as types of their own, and an
    /// anonymous class's methods belong to the anonymous class, so neither is reached
    /// through a method body or a member type.
    private static func methodDeclarations(in body: SyntaxNode) -> [SyntaxNode] {
        var methods: [SyntaxNode] = []
        for member in body.namedChildren {
            if member.type == "method_declaration" {
                methods.append(member)
            } else if member.type == "enum_body_declarations" {
                methods.append(contentsOf: member.namedChildren.filter { $0.type == "method_declaration" })
            }
        }
        return methods
    }

    private static func outerQualifiedName(of node: SyntaxNode) -> String? {
        var parent = node.parent
        while let current = parent {
            if ["class_declaration", "interface_declaration", "enum_declaration"].contains(current.type) {
                guard let name = current.child(byFieldName: "name")?.text else { return nil }
                if let outer = outerQualifiedName(of: current) { return outer + "." + name }
                return name
            }
            parent = current.parent
        }
        return nil
    }

    private static func hasOverrideModifier(_ methodNode: SyntaxNode) -> Bool {
        methodNode.hasAnnotation(named: "Override")
    }

    private static func methodTypeParameterNames(of methodNode: SyntaxNode) -> [String] {
        guard let list = methodNode.child(byFieldName: "type_parameters") else { return [] }
        return list.namedChildren(ofType: "type_parameter").compactMap { $0.namedChild(at: 0)?.text }
    }

    private static func shouldOverride(
        name: String, keys: [String], bodyTypeParams: [String],
        selfRef: JavaTypeRef, typeName: String, typePackage: String, index: JavaIndex,
        includeSelf: Bool, viewCache: inout [String: [String: JavaTypeRef]?]
    ) async -> Bool {
        var superNames = await JavaMemberLookup.supertypeClosure(of: typeName, index: index)
        if !includeSelf { superNames.remove(typeName) }
        for superName in superNames {
            guard let stub = await index.classStub(qualifiedName: superName) else { continue }
            let classMap: [String: JavaTypeRef]?
            if let cached = viewCache[superName] {
                classMap = cached
            } else {
                classMap = await substitutionMap(selfRef: selfRef, superName: superName, stub: stub, index: index)
                viewCache[superName] = classMap
            }
            guard let classMap else { continue }
            let classParamNames = Set(stub.typeParameters.map(\.name))
            for candidate in stub.methods where candidate.name == name && isOverridable(candidate, stub: stub, typePackage: typePackage) {
                if exactMatch(candidate: candidate, bodyKeys: keys, bodyTypeParams: bodyTypeParams, classMap: classMap, classParamNames: classParamNames) {
                    return true
                }
            }
        }
        return false
    }

    /// The map from the supertype's type-parameter names to the body's own viewed arguments.
    /// A raw view maps each parameter to its erasure (its first bound, else `Object`).
    /// `nil` when the body's type is not a subtype of the supertype after all.
    private static func substitutionMap(
        selfRef: JavaTypeRef, superName: String, stub: JavaClassStub, index: JavaIndex
    ) async -> [String: JavaTypeRef]? {
        // Interfaces never view as `java.lang.Object` through `asSupertype` (it is not a
        // supertype), but JLS 9.2 still gives them `Object`'s public methods to override
        // (`equals`/`hashCode`/`toString` redeclared in an interface). `Object` declares
        // no type parameters, so the map is empty either way.
        if superName == "java.lang.Object" { return [:] }
        guard let viewed = await JavaMemberLookup.asSupertype(selfRef, named: superName, index: index) else { return nil }
        guard !stub.typeParameters.isEmpty else { return [:] }
        if case .classType(_, let arguments, _) = viewed, !arguments.isEmpty {
            var map: [String: JavaTypeRef] = [:]
            for (parameter, argument) in zip(stub.typeParameters, arguments) {
                switch argument {
                case .type(let inner): map[parameter.name] = inner
                case .wildcard(.extends(let inner)): map[parameter.name] = inner
                case .wildcard(.superBound(let inner)): map[parameter.name] = inner
                case .wildcard(nil):
                    map[parameter.name] = parameter.bounds.first ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
                }
            }
            return map
        }
        var map: [String: JavaTypeRef] = [:]
        for parameter in stub.typeParameters {
            map[parameter.name] = erasedBound(parameter.bounds.first)
        }
        return map
    }

    private static func erasedBound(_ bound: JavaTypeRef?) -> JavaTypeRef {
        guard let bound else {
            return .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
        }
        let normalized = normalize(bound, classParamNames: [], methodParamNames: [])
        let erased = JavaTypeSystem.erasure(of: normalized)
        // Erasure leaves source-level names unresolved; keep the simple name rather than
        // dropping the bound entirely.
        return erased
    }

    private static func isOverridable(_ method: JavaMethodStub, stub: JavaClassStub, typePackage: String) -> Bool {
        guard !method.isConstructor, !method.modifiers.contains(.synthetic) else { return false }
        guard JavaSuperMethods.isOverridable(method) else { return false }
        // A package-private method is only overridden from the same package.
        if method.modifiers.isPackagePrivate, stub.kind != .interfaceKind, stub.packageName != typePackage { return false }
        return true
    }

    /// Whether the candidate's parameters match the body's written parameter keys after
    /// substituting the supertype's type arguments. Generic methods match their type
    /// variables by position; when the counts differ, there is no match.
    private static func exactMatch(
        candidate: JavaMethodStub, bodyKeys: [String], bodyTypeParams: [String],
        classMap: [String: JavaTypeRef], classParamNames: Set<String>
    ) -> Bool {
        guard candidate.parameters.count == bodyKeys.count else { return false }
        let methodParamNames = Set(candidate.typeParameters.map(\.name))
        if !candidate.typeParameters.isEmpty || !bodyTypeParams.isEmpty {
            guard candidate.typeParameters.count == bodyTypeParams.count else { return false }
            var combined = classMap
            for (candidateName, bodyName) in zip(candidate.typeParameters, bodyTypeParams) {
                combined[candidateName.name] = .typeVariable(name: bodyName)
            }
            for (parameter, bodyKey) in zip(candidate.parameters, bodyKeys) {
                let normalized = normalize(parameter.type, classParamNames: classParamNames, methodParamNames: methodParamNames)
                let substituted = JavaTypeSystem.substitute(normalized, using: combined)
                guard exactKey(of: substituted) == bodyKey else { return false }
            }
            return true
        }
        for (parameter, bodyKey) in zip(candidate.parameters, bodyKeys) {
            let normalized = normalize(parameter.type, classParamNames: classParamNames, methodParamNames: methodParamNames)
            let substituted = JavaTypeSystem.substitute(normalized, using: classMap)
            guard exactKey(of: substituted) == bodyKey else { return false }
        }
        return true
    }

    /// Source stubs leave type variables as `.unresolved`; resolve the ones in scope to
    /// `.typeVariable` so substitution can carry them, recursing through arguments, arrays
    /// and bounds. Anything else keeps its written form: keys compare by simple name.
    private static func normalize(_ type: JavaTypeRef, classParamNames: Set<String>, methodParamNames: Set<String>) -> JavaTypeRef {
        switch type {
        case .primitive, .void, .typeVariable:
            return type
        case .array(let element):
            return .array(element: normalize(element, classParamNames: classParamNames, methodParamNames: methodParamNames))
        case .classType(let qualifiedName, let arguments, let outer):
            return .classType(
                qualifiedName: qualifiedName,
                arguments: arguments.map { normalizeArgument($0, classParamNames: classParamNames, methodParamNames: methodParamNames) },
                outer: outer.map { normalize($0, classParamNames: classParamNames, methodParamNames: methodParamNames) }
            )
        case .wildcard(let bound):
            return .wildcard(bound: bound.map { normalizeBound($0, classParamNames: classParamNames, methodParamNames: methodParamNames) })
        case .unresolved(let simpleName, let arguments):
            if classParamNames.contains(simpleName) || methodParamNames.contains(simpleName) {
                return .typeVariable(name: simpleName)
            }
            return .unresolved(
                simpleName: simpleName,
                arguments: arguments.map { normalizeArgument($0, classParamNames: classParamNames, methodParamNames: methodParamNames) }
            )
        }
    }

    private static func normalizeArgument(_ argument: JavaTypeArgument, classParamNames: Set<String>, methodParamNames: Set<String>) -> JavaTypeArgument {
        switch argument {
        case .type(let inner):
            return .type(normalize(inner, classParamNames: classParamNames, methodParamNames: methodParamNames))
        case .wildcard(let bound):
            return .wildcard(bound.map { normalizeBound($0, classParamNames: classParamNames, methodParamNames: methodParamNames) })
        }
    }

    private static func normalizeBound(_ bound: JavaWildcardBound, classParamNames: Set<String>, methodParamNames: Set<String>) -> JavaWildcardBound {
        switch bound {
        case .extends(let inner):
            return .extends(normalize(inner, classParamNames: classParamNames, methodParamNames: methodParamNames))
        case .superBound(let inner):
            return .superBound(normalize(inner, classParamNames: classParamNames, methodParamNames: methodParamNames))
        }
    }

    /// The comparison key for a substituted parameter: like `JavaTypeKeys.parameterKey`
    /// except a type variable keeps its name, so `T` never equals `Foo` and an overload
    /// such as `accept(Integer)` next to `Consumer<String>.accept(String)` stays silent.
    private static func exactKey(of type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let primitive):
            return primitive.rawValue
        case .void:
            return "void"
        case .array(let element):
            return exactKey(of: element) + "[]"
        case .typeVariable(let name):
            return name
        case .wildcard:
            return "Object"
        case .classType(let qualifiedName, _, _):
            return String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
        case .unresolved(let simpleName, _):
            return String(simpleName.split(separator: ".").last ?? Substring(simpleName))
        }
    }
}
