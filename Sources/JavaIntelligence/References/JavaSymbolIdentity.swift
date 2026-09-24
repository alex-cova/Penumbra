import Foundation

/// What reference resolution needs from its host: the class index, the JDK and cache locations
/// used for attached sources, the text of open editor buffers, and (optionally) a Gradle model
/// that scopes both resolution and search to the source sets that can see a symbol.
public struct JavaReferenceEnvironment: Sendable {
    public var index: JavaIndex
    public var jdkHome: URL?
    public var cacheRoot: URL
    public var openBuffer: (@Sendable (URL) async -> String?)?
    public var gradleModel: JavaGradleProjectModel?
    public var indexPaths: JavaIndexPaths?

    public init(
        index: JavaIndex,
        jdkHome: URL? = nil,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)? = nil,
        gradleModel: JavaGradleProjectModel? = nil,
        indexPaths: JavaIndexPaths? = nil
    ) {
        self.index = index
        self.jdkHome = jdkHome
        self.cacheRoot = cacheRoot
        self.openBuffer = openBuffer
        self.gradleModel = gradleModel
        self.indexPaths = indexPaths
    }

    /// The shards a file's resolution may see, when a model is available.
    func queryScope(for file: URL) -> Set<String>? {
        guard let gradleModel, let indexPaths else { return nil }
        return gradleModel.visibleShardPaths(forFile: file, paths: indexPaths)
    }

    /// Runs `body` with this environment's index scope and open-buffer reader installed.
    func withScope<T>(for file: URL, _ body: () async -> T) async -> T {
        let scope = queryScope(for: file)
        let reader = openBuffer
        return await JavaIndex.$queryScope.withValue(scope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(reader) {
                await body()
            }
        }
    }
}

/// Resolves the symbol under a caret to a ``JavaSymbolID``.
public enum JavaSymbolIdentity {
    /// The symbol at `utf16Offset` in `source`: the declaration when the caret is on a declaring
    /// name, otherwise what the reference resolves to. `nil` when the caret is not on a symbol
    /// this can identify (a type variable, a keyword, an unresolvable name). A call whose
    /// overload could not be pinned yields the first of the tied candidates.
    public static func symbolID(
        at utf16Offset: Int, in source: String, url: URL?, environment: JavaReferenceEnvironment
    ) async -> JavaSymbolID? {
        await symbolIDs(at: utf16Offset, in: source, url: url, environment: environment).first?.id
    }

    /// Every candidate identity at the caret (several for an ambiguous overload), best first.
    static func symbolIDs(
        at utf16Offset: Int, in source: String, url: URL?, environment: JavaReferenceEnvironment
    ) async -> [JavaResolvedID] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        let leaf = tree.node(atByteOffset: byteOffset)
        var token = leaf
        if !(leaf.byteRange.contains(byteOffset) && isNameToken(leaf)) {
            // A caret just after the identifier (`foo|`) still means that identifier.
            let before = tree.node(atByteOffset: max(0, byteOffset - 1))
            guard isNameToken(before), before.byteRange.upperBound == byteOffset else { return [] }
            token = before
        }
        guard let reference = JavaReferenceClassifier.classify(token: token) else { return [] }
        let file = JavaSourceStubBuilder.build(tree: tree, url: url ?? JavaNavigationSession.placeholderURL)
        let session = JavaNavigationSession(
            source: source, fileURL: url, tree: tree, byteOffset: token.startByte, fileStubs: file,
            index: environment.index, jdkHome: environment.jdkHome, cacheRoot: environment.cacheRoot,
            openBuffer: environment.openBuffer, decompile: JavaDecompileGate(policy: .denied)
        )
        let scope = url.flatMap { environment.queryScope(for: $0) }
        let reader = environment.openBuffer
        let resolved = await JavaIndex.$queryScope.withValue(scope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(reader) {
                await session.resolveReference(token: token, reference: reference)
            }
        }
        return resolved.ids
    }

    private static func isNameToken(_ node: SyntaxNode) -> Bool {
        node.type == "identifier" || node.type == "type_identifier" || node.type == "this" || node.type == "super"
    }
}

struct JavaResolvedID: Sendable {
    var id: JavaSymbolID
    var kind: JavaUsage.Kind
    var confidence: JavaUsage.Confidence = .exact
}

struct JavaResolvedReference: Sendable {
    var ids: [JavaResolvedID] = []
    /// A qualified member access whose receiver could not be typed: the name may still be the
    /// symbol being searched for.
    var receiverUnknown = false
}

extension JavaNavigationSession {
    static let placeholderURL = URL(fileURLWithPath: "/unsaved/Navigation.java")

    var localFileURL: URL { fileURL ?? Self.placeholderURL }

    /// Resolves the name `token` (already classified as `reference`) to the symbols it denotes.
    func resolveReference(token: SyntaxNode, reference: JavaReference) async -> JavaResolvedReference {
        var result = JavaResolvedReference()
        switch reference {
        case .declaration:
            result.ids = await declarationIDs(token)
        case .type(let typeToken):
            let symbols = await typeSymbols(components: JavaReferenceClassifier.typeComponents(endingAt: typeToken))
            result.ids = await ids(of: symbols, kind: .typeReference)
        case .constructor(let typeToken, _):
            let components = JavaReferenceClassifier.typeComponents(endingAt: typeToken)
            guard let name = await typeQualifiedName(components: components) else { return result }
            let creation = Self.ancestor(of: typeToken, type: "object_creation_expression")
            result.ids = await constructorIDs(of: name, arguments: creation?.child(byFieldName: "arguments"))
            // `new Foo(...)` also uses the type Foo.
            result.ids.append(JavaResolvedID(id: .type(qualifiedName: name), kind: .constructorCall))
        case .explicitConstructor(let isSuper, _):
            guard let owner = await constructorOwner(isSuper: isSuper), let name = owner.erasedQualifiedName else { return result }
            let invocation = Self.ancestor(of: token, type: "explicit_constructor_invocation")
            result.ids = await constructorIDs(of: name, arguments: invocation?.child(byFieldName: "arguments"))
        case .methodCall(let invocation):
            let (targets, known) = await methodCallResolution(invocation)
            result.receiverUnknown = !known && invocation.child(byFieldName: "object") != nil
            let arguments = invocation.child(byFieldName: "arguments")
            let narrowed = await refine(targets, arguments: arguments)
            result.ids = await ids(of: narrowed.targets, kind: .call, forceAmbiguous: narrowed.ambiguous)
        case .fieldAccess(let access):
            if let target = await fieldAccessTarget(access) {
                let kind = JavaLocalUsages.isWrite(access.child(byFieldName: "field") ?? token) ? JavaUsage.Kind.write : .read
                result.ids = [JavaResolvedID(id: .field(declaringClass: target.declaringClass, name: target.field.name), kind: kind)]
            } else if let components = Self.dottedComponents(access),
                      let name = await typeQualifiedName(components: components) {
                result.ids = [JavaResolvedID(id: .type(qualifiedName: name), kind: .typeReference)]
            } else {
                result.receiverUnknown = true
            }
        case .bareName(let name):
            if let range = JavaDeclarationLocator.localDeclarationRange(name: name.text, in: tree, atByteOffset: name.startByte) {
                let kind = JavaLocalUsages.isWrite(name) ? JavaUsage.Kind.write : .read
                result.ids = [JavaResolvedID(id: .local(file: localFileURL, declarationRange: range), kind: kind)]
            } else {
                let symbols = await bareNameSymbols(name.text)
                let kind = JavaLocalUsages.isWrite(name) ? JavaUsage.Kind.write : .read
                result.ids = await ids(of: symbols, kind: kind, typeKind: .typeReference)
            }
        case .keywordThis, .keywordSuper:
            result.ids = await ids(of: await resolveSymbols(reference), kind: .typeReference)
        case .import:
            result.ids = await ids(of: await resolveSymbols(reference), kind: .import)
        }
        return result
    }

    // MARK: - Declarations

    private func declarationIDs(_ token: SyntaxNode) async -> [JavaResolvedID] {
        guard let parent = token.parent else { return [] }
        let declaration = JavaUsage.Kind.declaration
        let owner = context.enclosingTypeQualifiedNames.first
        switch parent.type {
        case "variable_declarator":
            let holder = parent.parent?.type
            if holder == "field_declaration" || holder == "constant_declaration" {
                guard !isInsideAnonymousBody(parent), let owner else { return [] }
                return [JavaResolvedID(id: .field(declaringClass: owner, name: token.text), kind: declaration)]
            }
            return [JavaResolvedID(id: .local(file: localFileURL, declarationRange: token.byteRange), kind: declaration)]
        case "formal_parameter":
            if parent.parent?.parent?.type == "record_declaration" {
                guard let owner else { return [] }
                return [JavaResolvedID(id: .field(declaringClass: owner, name: token.text), kind: declaration)]
            }
            return [JavaResolvedID(id: .local(file: localFileURL, declarationRange: token.byteRange), kind: declaration)]
        case "enhanced_for_statement", "resource", "catch_formal_parameter", "lambda_expression", "inferred_parameters":
            return [JavaResolvedID(id: .local(file: localFileURL, declarationRange: token.byteRange), kind: declaration)]
        case "enum_constant":
            guard let owner else { return [] }
            return [JavaResolvedID(id: .field(declaringClass: owner, name: token.text), kind: declaration)]
        case "method_declaration", "constructor_declaration":
            guard !isInsideAnonymousBody(parent), let owner, let stub = await stub(named: owner) else { return [] }
            guard let method = declaredStub(for: parent, in: stub, name: token.text) else { return [] }
            return [JavaResolvedID(id: methodID(method, declaringClass: owner), kind: declaration)]
        case "type_parameter":
            return []
        default:
            let symbols = await declarationSymbols()
            return await ids(of: symbols, kind: declaration)
        }
    }

    /// The stub built from `declaration`: the n-th stub of the same kind and name, where n is the
    /// declaration's position among its same-named siblings (stubs keep source order).
    private func declaredStub(for declaration: SyntaxNode, in stub: JavaClassStub, name: String) -> JavaMethodStub? {
        let isConstructor = declaration.type == "constructor_declaration"
        let arity = declaration.child(byFieldName: "parameters")?.namedChildCount ?? 0
        let siblings = (declaration.parent?.namedChildren ?? []).filter {
            $0.type == declaration.type && $0.child(byFieldName: "name")?.text == name
        }
        let position = siblings.firstIndex { $0.startByte == declaration.startByte } ?? 0
        let candidates = stub.methods.filter { $0.isConstructor == isConstructor && (isConstructor || $0.name == name) }
        if position < candidates.count, candidates[position].parameters.count == arity {
            return candidates[position]
        }
        return candidates.first { $0.parameters.count == arity }
    }

    private func isInsideAnonymousBody(_ node: SyntaxNode) -> Bool {
        var current = node.parent
        while let next = current {
            if next.type == "class_body" {
                let owner = next.parent?.type
                return owner == "object_creation_expression" || owner == "enum_constant"
            }
            current = next.parent
        }
        return false
    }

    // MARK: - Mapping to IDs

    func methodID(_ method: JavaMethodStub, declaringClass: String) -> JavaSymbolID {
        let keys = JavaTypeKeys.keys(of: method)
        if method.isConstructor { return .constructor(declaringClass: declaringClass, parameterKeys: keys) }
        return .method(declaringClass: declaringClass, name: method.name, parameterKeys: keys)
    }

    /// The declared (unsubstituted) stub that a member-lookup result stands for; lookup results
    /// have their type variables replaced, which would change the parameter keys.
    func declaredMethod(_ target: MethodTarget) async -> JavaMethodStub {
        guard let stub = await stub(named: target.declaringClass) else { return target.method }
        let method = target.method
        let candidates = stub.methods.filter {
            $0.name == method.name && $0.isConstructor == method.isConstructor && $0.parameters.count == method.parameters.count
        }
        if candidates.count <= 1 { return candidates.first ?? method }
        let classVariables = Set(stub.typeParameters.map(\.name))
        return candidates.first { declared in
            let variables = classVariables.union(declared.typeParameters.map(\.name))
            return zip(declared.parameters, method.parameters).allSatisfy {
                Self.compatible(declared: $0.type, substituted: $1.type, variables: variables)
            }
        } ?? method
    }

    /// Source stubs keep a type variable as an unresolved simple name, class-file stubs as `.typeVariable`.
    private static func compatible(declared: JavaTypeRef, substituted: JavaTypeRef, variables: Set<String>) -> Bool {
        switch declared {
        case .typeVariable, .wildcard:
            return true
        case .unresolved(let name, _) where variables.contains(name):
            return true
        case .array(let element):
            if case .array(let other) = substituted { return compatible(declared: element, substituted: other, variables: variables) }
            return false
        default:
            return JavaTypeKeys.parameterKey(declared) == JavaTypeKeys.parameterKey(substituted)
        }
    }

    private func ids(
        of targets: [MethodTarget], kind: JavaUsage.Kind, forceAmbiguous: Bool = false
    ) async -> [JavaResolvedID] {
        var result: [JavaResolvedID] = []
        var seen = Set<JavaSymbolID>()
        for target in targets {
            let id = methodID(await declaredMethod(target), declaringClass: target.declaringClass)
            if seen.insert(id).inserted { result.append(JavaResolvedID(id: id, kind: kind)) }
        }
        if forceAmbiguous || result.count > 1 {
            for position in result.indices { result[position].confidence = .ambiguous }
        }
        return result
    }

    private func ids(
        of symbols: [JavaResolvedSymbol], kind: JavaUsage.Kind, typeKind: JavaUsage.Kind? = nil
    ) async -> [JavaResolvedID] {
        var result: [JavaResolvedID] = []
        var methodTargets: [MethodTarget] = []
        for symbol in symbols {
            switch symbol {
            case .type(let stub):
                result.append(JavaResolvedID(id: .type(qualifiedName: stub.qualifiedName), kind: typeKind ?? kind))
            case .field(let field, let declaringClass):
                result.append(JavaResolvedID(id: .field(declaringClass: declaringClass, name: field.name), kind: kind))
            case .method(let method, let declaringClass):
                methodTargets.append(MethodTarget(declaringClass: declaringClass, method: method))
            case .local:
                break
            }
        }
        let methodKind: JavaUsage.Kind = kind == .declaration || kind == .import ? kind : .call
        result.append(contentsOf: await ids(of: methodTargets, kind: methodKind))
        return result
    }

    private func constructorIDs(of qualifiedName: String, arguments: SyntaxNode?) async -> [JavaResolvedID] {
        let type = JavaTypeRef.classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
        var declared = await JavaMemberLookup.constructors(of: type, context: context, index: index)
        if let owner = await stub(named: qualifiedName) {
            declared = await JavaMemberLookup.resolvingParameters(of: declared, declaredOn: owner, index: index)
        }
        let count = arguments?.namedChildCount ?? 0
        let targets = choose(
            primary: declared.map { MethodTarget(declaringClass: qualifiedName, method: $0) }, secondary: [], argumentCount: count
        )
        let narrowed = await refine(targets, arguments: arguments)
        return await ids(of: narrowed.targets, kind: .constructorCall, forceAmbiguous: narrowed.ambiguous)
    }

    // MARK: - Overloads

    /// Narrows arity-matched `targets` with the argument expressions' types. `ambiguous` when the
    /// types still could not pick one.
    private func refine(_ targets: [MethodTarget], arguments: SyntaxNode?) async -> (targets: [MethodTarget], ambiguous: Bool) {
        guard targets.count > 1, let arguments else { return (targets, false) }
        let argumentNodes = arguments.namedChildren
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: tree, atByteOffset: arguments.startByte), context: context, index: index
        )
        var types: [JavaTypeRef?] = []
        for argument in argumentNodes {
            if JavaExpressionTyper.isFunctionalArgument(argument) {
                types.append(nil)
            } else {
                types.append(await JavaExpressionTyper.typed(argument, locals: locals, context: context, index: index)?.type)
            }
        }
        let best = JavaExpressionTyper.bestOverloads(targets.map(\.method), argumentTypes: types)
        let narrowed = targets.filter { best.contains($0.method) }
        guard !narrowed.isEmpty else { return (targets, true) }
        return (narrowed, narrowed.count > 1)
    }

    // MARK: - Helpers

    static func ancestor(of node: SyntaxNode, type: String) -> SyntaxNode? {
        var current = node.parent
        while let next = current {
            if next.type == type { return next }
            current = next.parent
        }
        return nil
    }

    /// `a.b.C` as components when the expression is a chain of plain names.
    static func dottedComponents(_ node: SyntaxNode) -> [String]? {
        switch node.type {
        case "identifier", "type_identifier":
            return [node.text]
        case "field_access":
            guard let object = node.child(byFieldName: "object"), let field = node.child(byFieldName: "field"),
                  let head = dottedComponents(object) else { return nil }
            return head + [field.text]
        case "scoped_identifier", "scoped_type_identifier":
            let parts = JavaReferenceClassifier.pathComponents(node).map(\.name)
            return parts.isEmpty ? nil : parts
        default:
            return nil
        }
    }
}
