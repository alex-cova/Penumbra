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
        func closure(of stub: JavaClassStub) async -> Set<String> {
            if let cached = closures[stub.qualifiedName] { return cached }
            let computed = await JavaMemberLookup.supertypeClosure(of: stub.qualifiedName, index: index)
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
                let keys = JavaTypeKeys.keys(of: method.method)
                for stub in projectClasses where stub.qualifiedName != method.declaringClass {
                    guard await closure(of: stub).contains(method.declaringClass) else { continue }
                    let overrides = stub.methods.filter { candidate in
                        candidate.name == method.method.name
                            && !candidate.isConstructor
                            && !candidate.modifiers.contains(.abstractFlag)
                            && !candidate.modifiers.contains(.staticFlag)
                            // An interface method without `default` is a redeclaration, not a body.
                            && (stub.kind != .interfaceKind || candidate.modifiers.contains(.defaultMethod))
                            && JavaTypeKeys.keys(of: candidate) == keys
                    }
                    hits.append(contentsOf: await methodHits(overrides.map {
                        MethodTarget(declaringClass: stub.qualifiedName, method: $0)
                    }))
                }
            }
        }
        return dedupe(hits)
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
