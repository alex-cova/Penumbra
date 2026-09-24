import EditorIntelligence
import Foundation

/// Walks up from a method to the methods it overrides or implements. Shared by Go to Super Method
/// and ``JavaMethodFamily``. Type variables in the supertype's signature (`compareTo(T)`) match
/// whatever the subtype fixed them to, as in Go to Implementation.
enum JavaSuperMethods {
    /// The nearest declarations `method` (declared on `owner`) overrides: for each supertype
    /// branch, the first ancestor that declares a matching instance method. Nearest first.
    static func overridden(
        method: JavaMethodStub,
        owner: String,
        stub: (String) async -> JavaClassStub?,
        supertypes: (String) async -> [String]
    ) async -> [MethodTarget] {
        guard isOverridable(method) else { return [] }
        let keys = JavaTypeKeys.keys(of: method)
        var found: [MethodTarget] = []
        var queue = await supertypes(owner)
        var visited: Set<String> = [owner]
        var cursor = 0
        while cursor < queue.count {
            let name = queue[cursor]
            cursor += 1
            guard visited.insert(name).inserted, let candidate = await stub(name) else { continue }
            let variables = Set(candidate.typeParameters.map(\.name) + method.typeParameters.map(\.name))
            let matches = candidate.methods.filter { target in
                target.name == method.name && isOverridable(target)
                    && JavaNavigationSession.overrides(candidate: keys, target: target, typeVariables: variables)
            }
            if matches.isEmpty {
                queue.append(contentsOf: await supertypes(name))
            } else {
                found.append(contentsOf: matches.map { MethodTarget(declaringClass: name, method: $0) })
            }
        }
        return found
    }

    static func isOverridable(_ method: JavaMethodStub) -> Bool {
        !method.isConstructor && !method.modifiers.contains(.staticFlag) && !method.modifiers.contains(.privateFlag)
    }
}

enum JavaGoToSuperMethod {
    static func resolve(
        source: String,
        fileURL: URL?,
        utf16Offset: Int,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?,
        decompile: JavaDecompileGate
    ) async -> [JavaDefinitionHit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer, decompile: decompile
        )
        return await session.superMethodHits()
    }
}

extension JavaNavigationSession {
    /// Go to Super Method: on a method, the methods it overrides or implements; on a type, its
    /// superclass and interfaces. Targets in JARs or the JDK open attached sources, or the
    /// decompiled class when the user has agreed to that.
    func superMethodHits() async -> [JavaDefinitionHit] {
        var node: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let current = node {
            switch current.type {
            case "constructor_declaration", "compact_constructor_declaration":
                return []
            case "class_body":
                // An anonymous class or enum constant body has no name to look up.
                if let parent = current.parent, parent.type == "object_creation_expression" || parent.type == "enum_constant" {
                    return []
                }
            case "method_declaration":
                return await superMethodHits(forMethod: current)
            case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
                return await superTypeHits()
            default:
                break
            }
            node = current.parent
        }
        return []
    }

    private func superMethodHits(forMethod declaration: SyntaxNode) async -> [JavaDefinitionHit] {
        if let body = declaration.parent, let parent = body.parent,
           parent.type == "object_creation_expression" || parent.type == "enum_constant" {
            return []
        }
        guard let owner = context.enclosingTypeQualifiedNames.first,
              let name = declaration.child(byFieldName: "name")?.text,
              let stub = await liveStub(owner) else { return [] }
        let arity = declaration.child(byFieldName: "parameters")?.namedChildCount ?? 0
        let sameArity = stub.methods.filter { $0.name == name && !$0.isConstructor && $0.parameters.count == arity }
        let written = Self.parameterKeys(of: declaration)
        let exact = sameArity.filter { JavaTypeKeys.keys(of: $0) == written }
        guard let method = (exact.isEmpty ? sameArity : exact).first else { return [] }
        let targets = await JavaSuperMethods.overridden(
            method: method, owner: owner,
            stub: { await self.liveStub($0) },
            supertypes: { await self.directSupertypes(of: $0) }
        )
        return await methodHits(targets, qualifiedOwner: true)
    }

    private func superTypeHits() async -> [JavaDefinitionHit] {
        guard let owner = context.enclosingTypeQualifiedNames.first else { return [] }
        var hits: [JavaDefinitionHit] = []
        for name in await directSupertypes(of: owner) where name != "java.lang.Object" {
            hits.append(contentsOf: await typeHits(qualifiedName: name))
        }
        return dedupe(hits)
    }

    /// The buffer's own declaration wins over the indexed (possibly stale) one.
    private func liveStub(_ qualifiedName: String) async -> JavaClassStub? {
        if let current = currentClasses.first(where: { $0.qualifiedName == qualifiedName }) { return current }
        return await index.classStub(qualifiedName: qualifiedName)
    }

    private func directSupertypes(of qualifiedName: String) async -> [String] {
        guard let current = currentClasses.first(where: { $0.qualifiedName == qualifiedName }) else {
            return await JavaMemberLookup.directSupertypeNames(of: qualifiedName, index: index)
        }
        var names: [String] = []
        func resolve(_ type: JavaTypeRef) async -> String? {
            switch type {
            case .classType(let name, _, _): return name
            case .unresolved(let simple, _):
                return await resolveType(components: simple.split(separator: ".").map(String.init))?.erasedQualifiedName
            default: return nil
            }
        }
        if let superclass = current.superclass {
            if let name = await resolve(superclass) { names.append(name) }
        } else if current.kind == .classKind || current.kind == .enumKind || current.kind == .recordKind {
            names.append("java.lang.Object")
        }
        for interface in current.interfaces {
            if let name = await resolve(interface), !names.contains(name) { names.append(name) }
        }
        return names
    }
}

/// One declaration in a ``JavaMethodFamily``.
public struct JavaMethodFamilyMember: Hashable, Sendable {
    public let declaringClass: String
    public let method: JavaMethodStub
    public let origin: JavaStubOrigin?

    public init(declaringClass: String, method: JavaMethodStub, origin: JavaStubOrigin?) {
        self.declaringClass = declaringClass
        self.method = method
        self.origin = origin
    }
}

/// Every declaration that must change together when a method is renamed: the method itself, the
/// methods it overrides or implements (transitively, upward), and the project methods that
/// override any of those (downward). Anonymous classes and enum constant bodies are not included
/// because they have no stubs.
public enum JavaMethodFamily {
    /// The first element is `method` itself. Upward members follow, nearest first, then project
    /// overriders sorted by class name. A static, private or constructor method is its own family.
    public static func family(
        of method: JavaMethodStub, declaringClass: String, index: JavaIndex
    ) async -> [JavaMethodFamilyMember] {
        let ownerStub = await index.classStub(qualifiedName: declaringClass)
        var members: [JavaMethodFamilyMember] = [
            JavaMethodFamilyMember(declaringClass: declaringClass, method: method, origin: ownerStub?.origin)
        ]
        guard JavaSuperMethods.isOverridable(method) else { return members }
        var seen: Set<String> = [key(declaringClass, method)]

        // Upward, transitively.
        var pending = [(declaringClass, method)]
        var upward: [(String, JavaMethodStub)] = [(declaringClass, method)]
        while !pending.isEmpty {
            let (owner, current) = pending.removeFirst()
            let supers = await JavaSuperMethods.overridden(
                method: current, owner: owner,
                stub: { await index.classStub(qualifiedName: $0) },
                supertypes: { await JavaMemberLookup.directSupertypeNames(of: $0, index: index) }
            )
            for target in supers where seen.insert(key(target.declaringClass, target.method)).inserted {
                let origin = await index.classStub(qualifiedName: target.declaringClass)?.origin
                members.append(JavaMethodFamilyMember(declaringClass: target.declaringClass, method: target.method, origin: origin))
                pending.append((target.declaringClass, target.method))
                upward.append((target.declaringClass, target.method))
            }
        }

        // Downward from every member found so far.
        let projectClasses = await index.projectClassStubs()
        var closures: [String: Set<String>] = [:]
        for stub in projectClasses where !(stub.superclass == nil && stub.interfaces.isEmpty) {
            closures[stub.qualifiedName] = await JavaMemberLookup.supertypeClosure(of: stub.qualifiedName, index: index)
        }
        var overriders: [JavaMethodFamilyMember] = []
        for (owner, target) in upward {
            let ownerStub = await index.classStub(qualifiedName: owner)
            let variables = Set((ownerStub?.typeParameters ?? []).map(\.name) + target.typeParameters.map(\.name))
            for stub in projectClasses where stub.qualifiedName != owner {
                guard closures[stub.qualifiedName]?.contains(owner) == true else { continue }
                for candidate in stub.methods
                where candidate.name == target.name && JavaSuperMethods.isOverridable(candidate)
                    && JavaNavigationSession.overrides(candidate: JavaTypeKeys.keys(of: candidate), target: target, typeVariables: variables)
                    && seen.insert(key(stub.qualifiedName, candidate)).inserted {
                    overriders.append(JavaMethodFamilyMember(declaringClass: stub.qualifiedName, method: candidate, origin: stub.origin))
                }
            }
        }
        overriders.sort { $0.declaringClass < $1.declaringClass }
        return members + overriders
    }

    private static func key(_ owner: String, _ method: JavaMethodStub) -> String {
        "\(owner)#\(method.name)(\(JavaTypeKeys.keys(of: method).joined(separator: ",")))"
    }
}
