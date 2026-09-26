import EditorIntelligence
import Foundation

/// Resolves "Go to Implementation" for the Java symbol at a caret: the project classes that
/// extend or implement a type, or that override a method.
enum JavaGoToImplementation {
    static func resolve(
        source: String,
        fileURL: URL?,
        utf16Offset: Int,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [JavaDefinitionHit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        guard let reference = JavaReferenceClassifier.classify(in: tree, atByteOffset: byteOffset) else { return [] }
        // Implementations are project sources, so there is never a reason to decompile.
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer, decompile: JavaDecompileGate(policy: .denied)
        )
        return await session.implementationHits(reference)
    }

    /// Whether the caret is on the name of a declaration that only makes sense through its
    /// implementations: an interface, an abstract class, an interface method that isn't `static`
    /// or `private`, or an abstract method. ⌘-click on one of these lists its implementations.
    static func isAbstractDeclaration(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> Bool {
        let leaf = tree.node(atByteOffset: byteOffset)
        guard let declaration = leaf.parent,
              declaration.child(byFieldName: "name")?.byteRange == leaf.byteRange else { return false }
        func hasModifier(_ keyword: String) -> Bool {
            declaration.namedChildren.first(where: { $0.type == "modifiers" })?.children.contains { $0.type == keyword } == true
        }
        switch declaration.type {
        case "interface_declaration":
            return true
        case "class_declaration":
            return hasModifier("abstract")
        case "method_declaration":
            if hasModifier("abstract") { return true }
            return declaration.parent?.type == "interface_body" && !hasModifier("static") && !hasModifier("private")
        default:
            return false
        }
    }
}

extension JavaNavigationSession {
    private enum ImplementationTarget {
        case type(String)
        case method(MethodTarget)
    }

    func implementationHits(_ reference: JavaReference) async -> [JavaDefinitionHit] {
        let targets = await implementationTargets(reference)
        guard !targets.isEmpty else { return [] }
        let projectClasses = await index.projectClassStubs()
        var hits: [JavaDefinitionHit] = []
        var closures: [String: Set<String>] = [:]
        // Every request shares one closure per class, and a class with no supertypes at all can
        // never be a subtype, so it is never walked.
        func closure(of stub: JavaClassStub) async -> Set<String> {
            if let cached = closures[stub.qualifiedName] { return cached }
            let computed: Set<String> = stub.superclass == nil && stub.interfaces.isEmpty
                ? [stub.qualifiedName]
                : await JavaMemberLookup.supertypeClosure(of: stub.qualifiedName, index: index)
            closures[stub.qualifiedName] = computed
            return computed
        }
        for target in targets {
            switch target {
            case .type(let qualifiedName):
                for stub in projectClasses where stub.qualifiedName != qualifiedName {
                    if await closure(of: stub).contains(qualifiedName) {
                        hits.append(contentsOf: await typeHits(qualifiedName: stub.qualifiedName))
                    }
                }
            case .method(let method):
                let ownerStub = await index.classStub(qualifiedName: method.declaringClass)
                    ?? currentClasses.first { $0.qualifiedName == method.declaringClass }
                let variables = Set((ownerStub?.typeParameters ?? []).map(\.name) + method.method.typeParameters.map(\.name))
                for stub in projectClasses where stub.qualifiedName != method.declaringClass {
                    guard await closure(of: stub).contains(method.declaringClass) else { continue }
                    let overrides = stub.methods.filter { candidate in
                        candidate.name == method.method.name
                            && !candidate.isConstructor
                            && !candidate.modifiers.contains(.abstractFlag)
                            && !candidate.modifiers.contains(.staticFlag)
                            // An interface method without `default` is a redeclaration, not a body.
                            && (stub.kind != .interfaceKind || candidate.modifiers.contains(.defaultMethod))
                            && Self.overrides(candidate: JavaTypeKeys.keys(of: candidate), target: method.method, typeVariables: variables)
                    }
                    hits.append(contentsOf: await methodHits(overrides.map {
                        MethodTarget(declaringClass: stub.qualifiedName, method: $0)
                    }, qualifiedOwner: true))
                }
            }
            hits.append(contentsOf: await anonymousHits(for: target, projectClasses: projectClasses, closure: closure))
        }
        return Self.ordered(dedupe(hits))
    }

    /// In file order, so the list reads the same every time.
    private static func ordered(_ hits: [JavaDefinitionHit]) -> [JavaDefinitionHit] {
        hits.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            let lp = l.url?.standardizedFileURL.path ?? "", rp = r.url?.standardizedFileURL.path ?? ""
            if lp != rp { return lp < rp }
            if l.range.start.utf16Offset != r.range.start.utf16Offset { return l.range.start.utf16Offset < r.range.start.utf16Offset }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Whether a subtype's method with parameter keys `candidate` overrides `target`. A parameter
    /// the target declares as a type variable (`compareTo(T)`) matches whatever type the subtype
    /// fixed it to (`compareTo(Foo)`), without resolving the supertype's type arguments; an
    /// array of a type variable matches any array.
    static func overrides(candidate: [String], target: JavaMethodStub, typeVariables: Set<String> = []) -> Bool {
        guard candidate.count == target.parameters.count else { return false }
        let primitives: Set<String> = ["int", "long", "double", "float", "boolean", "char", "byte", "short"]
        for (key, declared) in zip(candidate, target.parameters) {
            // Source stubs leave a type variable as an unresolved simple name.
            var parameter = declared
            if case .unresolved(let name, _) = declared.type, typeVariables.contains(name) {
                parameter = JavaParameterStub(name: declared.name, type: .typeVariable(name: name))
            } else if case .array(let element) = declared.type, case .unresolved(let name, _) = element, typeVariables.contains(name) {
                parameter = JavaParameterStub(name: declared.name, type: .array(element: .typeVariable(name: name)))
            }
            switch parameter.type {
            case .typeVariable:
                if primitives.contains(key) { return false }
            case .array(let element):
                if case .typeVariable = element {
                    if !key.hasSuffix("[]") { return false }
                } else if key != JavaTypeKeys.parameterKey(parameter.type) {
                    return false
                }
            default:
                if key != JavaTypeKeys.parameterKey(parameter.type) { return false }
            }
        }
        return true
    }

    // MARK: - Anonymous classes and enum constant bodies

    /// `new Foo() { ... }` and `CONSTANT { ... }` bodies in project sources, which stubs do not
    /// describe. Only files that mention the target's simple name are parsed. Lambdas are not
    /// searched.
    private func anonymousHits(
        for target: ImplementationTarget,
        projectClasses: [JavaClassStub],
        closure: (JavaClassStub) async -> Set<String>
    ) async -> [JavaDefinitionHit] {
        let targetType: String
        let method: JavaMethodStub?
        switch target {
        case .type(let name):
            targetType = name
            method = nil
        case .method(let found):
            targetType = found.declaringClass
            method = found.method
        }
        let simpleName = String(targetType.split(separator: ".").last ?? Substring(targetType))
        let ownerStub = await index.classStub(qualifiedName: targetType) ?? currentClasses.first { $0.qualifiedName == targetType }
        let variables = Set((ownerStub?.typeParameters ?? []).map(\.name) + (method?.typeParameters ?? []).map(\.name))
        var urls: [URL] = []
        var seen = Set<String>()
        for stub in projectClasses {
            if case .source(let url, _) = stub.origin, seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) }
        }
        var hits: [JavaDefinitionHit] = []
        var subtypeCache: [String: Bool] = [:]
        func isSubtype(_ qualifiedName: String) async -> Bool {
            if qualifiedName == targetType { return true }
            if let cached = subtypeCache[qualifiedName] { return cached }
            var result = false
            if let stub = await index.classStub(qualifiedName: qualifiedName) {
                result = await closure(stub).contains(targetType)
            }
            subtypeCache[qualifiedName] = result
            return result
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let text = await load(url), text.contains(simpleName), let parsed = JavaSyntaxParser().parse(text) else { continue }
            let file = JavaSourceStubBuilder.build(tree: parsed, url: url)
            var stack = [parsed.rootNode]
            while let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                guard node.type == "object_creation_expression" || node.type == "enum_constant",
                      let body = node.children.first(where: { $0.type == "class_body" }) else { continue }
                let enclosing = JavaCompletionProvider.enclosingTypeContext(in: parsed, atByteOffset: node.startByte)
                let qualified = enclosing.qualifiedNames.map { file.packageName.isEmpty ? $0 : "\(file.packageName).\($0)" }
                let fileContext = JavaResolutionContext(
                    packageName: file.packageName, imports: file.imports,
                    enclosingTypeQualifiedNames: qualified, typeParameterNames: enclosing.typeParameterNames
                )
                let label: String
                let implemented: String
                if node.type == "enum_constant" {
                    // The body is a subclass of the enum it sits in.
                    guard method != nil, let enumName = qualified.first else { continue }
                    implemented = enumName
                    label = node.child(byFieldName: "name")?.text ?? "constant"
                } else {
                    guard let typeNode = node.child(byFieldName: "type") else { continue }
                    let components = Self.typeComponents(of: typeNode.text)
                    guard let resolved = await resolveType(components: components, in: fileContext),
                          let name = resolved.erasedQualifiedName else { continue }
                    implemented = name
                    label = "new \(components.last ?? "?")() {…}"
                }
                guard await isSubtype(implemented) else { continue }
                guard let method else {
                    // A type target: the anonymous class itself is the implementation.
                    if node.type == "object_creation_expression", let typeNode = node.child(byFieldName: "type") {
                        hits.append(hit(text: text, url: url, byteRange: typeNode.byteRange, displayName: label))
                    }
                    continue
                }
                for member in body.namedChildren where member.type == "method_declaration" {
                    guard let nameNode = member.child(byFieldName: "name"), nameNode.text == method.name else { continue }
                    let keys = Self.parameterKeys(of: member)
                    guard Self.overrides(candidate: keys, target: method, typeVariables: variables) else { continue }
                    hits.append(hit(
                        text: text, url: url, byteRange: nameNode.byteRange,
                        displayName: "\(label).\(method.name)(\(keys.joined(separator: ", ")))"
                    ))
                }
            }
        }
        return hits
    }

    /// `java.util.Map.Entry<K, V>` -> `["java", "util", "Map", "Entry"]`.
    static func typeComponents(of text: String) -> [String] {
        var depth = 0
        var plain = ""
        for character in text {
            if character == "<" { depth += 1 } else if character == ">" { depth -= 1 } else if depth == 0 { plain.append(character) }
        }
        return plain.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Parameter keys of a `method_declaration` from the type text as written (`List<String>` -> `List`).
    static func parameterKeys(of method: SyntaxNode) -> [String] {
        guard let parameters = method.child(byFieldName: "parameters") else { return [] }
        return parameters.namedChildren.compactMap { parameter in
            guard parameter.type == "formal_parameter" || parameter.type == "spread_parameter" else { return nil }
            guard let typeNode = parameter.child(byFieldName: "type")
                    ?? parameter.namedChildren.first(where: { $0.type != "modifiers" && $0.type != "variable_declarator" }) else { return nil }
            var key = typeComponents(of: typeNode.text).last ?? typeNode.text
            key += String(repeating: "[]", count: typeNode.text.components(separatedBy: "[]").count - 1)
            if parameter.type == "spread_parameter" { key += "[]" }
            return key
        }
    }

    private func implementationTargets(_ reference: JavaReference) async -> [ImplementationTarget] {
        switch reference {
        case .declaration:
            return await declarationTargets()
        case .type(let token):
            guard let name = await qualifiedTypeName(components: JavaReferenceClassifier.typeComponents(endingAt: token)) else {
                return []
            }
            return [.type(name)]
        case .constructor(let type, _):
            guard let name = await qualifiedTypeName(components: JavaReferenceClassifier.typeComponents(endingAt: type)) else {
                return []
            }
            return [.type(name)]
        case .methodCall(let invocation):
            return await methodCallTargets(invocation).map { .method($0) }
        case .keywordThis:
            guard let name = context.enclosingTypeQualifiedNames.first else { return [] }
            return [.type(name)]
        default:
            return []
        }
    }

    private func qualifiedTypeName(components: [String]) async -> String? {
        guard let resolved = await resolveType(components: components),
              case .classType(let qualifiedName, _, _) = resolved else { return nil }
        return qualifiedName
    }

    /// The caret is on a declaration name: a type declaration targets that type, a method
    /// declaration targets that method of the enclosing type. Fields, locals and parameters have
    /// no implementations.
    private func declarationTargets() async -> [ImplementationTarget] {
        let leaf = tree.node(atByteOffset: byteOffset)
        guard let declaration = leaf.parent,
              declaration.child(byFieldName: "name")?.byteRange == leaf.byteRange else { return [] }
        let owner = context.enclosingTypeQualifiedNames.first
        switch declaration.type {
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
            guard let name = owner else { return [] }
            return [.type(name)]
        case "method_declaration":
            guard let owner else { return [] }
            let declared = currentClasses.first(where: { $0.qualifiedName == owner })
            let indexed = await index.classStub(qualifiedName: owner)
            guard let stub = declared ?? indexed else { return [] }
            let arity = declaration.child(byFieldName: "parameters")?.namedChildCount ?? 0
            return stub.methods
                .filter { $0.name == leaf.text && !$0.isConstructor && $0.parameters.count == arity }
                .map { .method(MethodTarget(declaringClass: owner, method: $0)) }
        default:
            return []
        }
    }
}
