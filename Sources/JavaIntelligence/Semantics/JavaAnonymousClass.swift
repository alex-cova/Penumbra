import Foundation

/// Anonymous class bodies as types (`new Runnable() { … }`, JLS 15.9.5).
///
/// An anonymous body has no name, so nothing in the index can resolve it, yet three things need it
/// to be a type: `this.` inside it (its own members plus the instantiated type's), unqualified
/// member completion inside it, and `var o = new Object() { int secret; }`, where `o` has the
/// anonymous type (JLS 14.4.1), `secret` included. A synthetic ``JavaClassStub`` serves all three:
/// it extends the instantiated class (or implements the instantiated interface) and declares the
/// body's members, and ``JavaIndex/classStub(qualifiedName:)`` finds it through the request's
/// ``registry``.
///
/// Only a caller that sets a registry gets this (the completion provider). Everyone else types
/// `new Foo() { … }` as `Foo`, as before. The registry lives for one request: stubs name a
/// position in a parse that the next keystroke replaces.
public enum JavaAnonymousClass {
    /// Appears in every synthetic anonymous name; the member-set cache must not hold such a type.
    static let marker = "$Anonymous"
    /// Site-keyed local classes (`Outer.$Local<start>.Acc`). Same cache rule as anonymous stubs.
    static let localMarker = "$Local"

    /// The request's anonymous stubs, and the file their members' type names resolve against.
    @TaskLocal public static var registry: Registry?

    public final class Registry: @unchecked Sendable {
        let fileURL: URL
        private let lock = NSLock()
        private var stubs: [String: JavaClassStub] = [:]

        public init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func stub(named qualifiedName: String) -> JavaClassStub? {
            lock.lock(); defer { lock.unlock() }
            return stubs[qualifiedName]
        }

        func register(_ stub: JavaClassStub) {
            lock.lock(); defer { lock.unlock() }
            stubs[stub.qualifiedName] = stub
        }
    }

    static func isAnonymous(_ qualifiedName: String) -> Bool {
        qualifiedName.contains(marker)
    }

    static func isLocal(_ qualifiedName: String) -> Bool {
        qualifiedName.contains(localMarker)
    }

    /// Request-scoped stubs (anonymous and local) must not enter the shared member-set cache.
    static func isSynthetic(_ qualifiedName: String) -> Bool {
        isAnonymous(qualifiedName) || isLocal(qualifiedName)
    }

    /// The anonymous class bodies around `offset`, innermost first, up to the nearest named type:
    /// past that, `this` belongs to the named type and the context already says so.
    static func enclosingCreations(in tree: JavaSyntaxTree, atByteOffset offset: Int) -> [SyntaxNode] {
        let named: Set<String> = [
            "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
        ]
        var result: [SyntaxNode] = []
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            if named.contains(node.type) { break }
            if node.type == "class_body", let creation = node.parent, creation.type == "object_creation_expression",
               node.byteRange.lowerBound < offset {
                result.append(creation)
            }
            current = node.parent
        }
        return result
    }

    /// The stub for `creation`'s body, registering it. `nil` without a registry, without a body, or
    /// when the instantiated type does not resolve (then the caller keeps the written type).
    static func stub(for creation: SyntaxNode, context: JavaResolutionContext, index: JavaIndex) async -> JavaClassStub? {
        guard let registry,
              let typeNode = creation.child(byFieldName: "type"),
              let body = creation.firstNamedChild(ofType: "class_body") else { return nil }
        let qualifiedName = anonymousQualifiedName(of: creation, context: context)
        if let existing = registry.stub(named: qualifiedName) { return existing }

        let resolved = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: context, index: index)
        guard case .classType(let superName, _, _) = resolved else { return nil }
        let isInterface = await index.classStub(qualifiedName: superName)?.kind == .interfaceKind
        // Private members are visible throughout the top-level type (JLS 6.6.1). The synthetic
        // name has no stub of its own, so the outer chain has to start at the real enclosing type.
        let (stub, nested) = JavaSourceStubBuilder.anonymousStub(
            body: body, qualifiedName: qualifiedName, supertype: resolved, supertypeIsInterface: isInterface,
            packageName: context.packageName, outerQualifiedName: context.topLevelTypeQualifiedName,
            url: registry.fileURL, nameRange: typeNode.byteRange
        )
        registry.register(stub)
        for nestedStub in nested { registry.register(nestedStub) }
        return stub
    }

    /// The synthetic name of the anonymous class `creation` declares. It comes from the text, not the
    /// position: a `var` initializer is typed from a re-parse of its own text, where the same
    /// expression sits at another offset.
    static func anonymousQualifiedName(of creation: SyntaxNode, context: JavaResolutionContext) -> String {
        let owner = context.topLevelTypeQualifiedName ?? (context.packageName.isEmpty ? "" : context.packageName)
        return "\(owner).\(marker)\(fingerprint(of: creation.text))"
    }

    /// The `new … { }` whose body declares `node` directly (a member type of an anonymous class).
    private static func anonymousCreation(declaring node: SyntaxNode) -> SyntaxNode? {
        guard let body = node.parent, body.type == "class_body",
              let creation = body.parent, creation.type == "object_creation_expression" else { return nil }
        return creation
    }

    /// Local classes visible at `offset`, registered under site-keyed names. `localTypes` maps each
    /// visible simple name to that stub (innermost declaration wins). `enclosing` replaces the
    /// context's enclosing-type list when a local class is in it, so `Outer.Acc` becomes the
    /// synthetic name instead of a qualified name no stub has. `nil` enclosing means nothing changed.
    static func bindLocalClasses(
        in tree: JavaSyntaxTree, atByteOffset offset: Int, context: JavaResolutionContext, fileURL: URL
    ) -> (localTypes: [String: String], enclosing: [String]?) {
        guard let registry else { return ([:], nil) }
        let sites = tree.visibleLocalTypeSites(atByteOffset: offset)
        guard !sites.isEmpty else { return ([:], nil) }
        var syntheticByStart: [Int: String] = [:]
        // Outermost first, so a local class nested in another can name its owner.
        for site in sites.reversed() {
            guard let node = typeDeclaration(in: tree, nameRange: site.declarationRange) else { continue }
            // A member type of an anonymous class is not local (JLS 14.3): it belongs to the anonymous
            // class, and ``stub(for:context:index:)`` registers it as `Owner.$Anonymous<hash>.Name`
            // from the same declaration. Binding it under that name, built the same way, keeps one
            // identity whether the name is written in the body (`Cell c`) or reached through the
            // anonymous class (`TreeMap<Cell, Cell>` on its field); a `$Local` name here gave the same
            // class two names in one request.
            if let creation = anonymousCreation(declaring: node) {
                let anonymous = anonymousQualifiedName(of: creation, context: context)
                for stub in JavaSourceStubBuilder.localClassStubs(node, packageName: context.packageName, outerQualifiedName: anonymous, url: fileURL) {
                    registry.register(stub)
                }
                syntheticByStart[node.startByte] = "\(anonymous).\(site.name)"
                continue
            }
            let owner = ownerQualifiedName(of: node, packageName: context.packageName, syntheticByStart: syntheticByStart)
            let siteOwner = owner.isEmpty ? "\(localMarker)\(node.startByte)" : "\(owner).\(localMarker)\(node.startByte)"
            let qualified = "\(siteOwner).\(site.name)"
            let stubs = JavaSourceStubBuilder.localClassStubs(
                node, packageName: context.packageName, outerQualifiedName: siteOwner, url: fileURL
            )
            for stub in stubs {
                let registered = stub.qualifiedName == qualified
                    ? stub.withOuterQualifiedName(owner.isEmpty ? nil : owner)
                    : stub
                registry.register(registered)
            }
            syntheticByStart[node.startByte] = qualified
        }
        var localTypes: [String: String] = [:]
        for site in sites {
            // Innermost first: the first site of a name is the one in scope.
            if localTypes[site.name] == nil, let qualified = syntheticByStart[declarationStart(in: tree, nameRange: site.declarationRange) ?? -1] {
                localTypes[site.name] = qualified
            }
        }
        // Sites that failed to find a node never entered the map; drop those names.
        if localTypes.isEmpty { return ([:], nil) }
        return (localTypes, enclosingQualifiedNames(in: tree, atByteOffset: offset, packageName: context.packageName, syntheticByStart: syntheticByStart))
    }

    private static let typeDeclarationTypes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
    ]
    private static let memberBodies: Set<String> = [
        "class_body", "interface_body", "enum_body", "annotation_type_body", "enum_body_declarations"
    ]

    /// A class, record or enum declared in a block. Top-level types and member types are not local.
    private static func isLocalClass(_ node: SyntaxNode) -> Bool {
        guard typeDeclarationTypes.contains(node.type), let parent = node.parent else { return false }
        if parent.type == "program" { return false }
        return !memberBodies.contains(parent.type)
    }

    private static func typeDeclaration(in tree: JavaSyntaxTree, nameRange: Range<Int>) -> SyntaxNode? {
        var current: SyntaxNode? = tree.node(atByteOffset: nameRange.lowerBound)
        while let node = current {
            if typeDeclarationTypes.contains(node.type), node.child(byFieldName: "name")?.byteRange == nameRange {
                return node
            }
            current = node.parent
        }
        return nil
    }

    private static func declarationStart(in tree: JavaSyntaxTree, nameRange: Range<Int>) -> Int? {
        typeDeclaration(in: tree, nameRange: nameRange)?.startByte
    }

    /// The nearest enclosing local class's synthetic name, else the real enclosing type
    /// (`pkg.Outer.Inner` for a member, the package alone when there is none).
    private static func ownerQualifiedName(of node: SyntaxNode, packageName: String, syntheticByStart: [Int: String]) -> String {
        var current = node.parent
        while let parent = current {
            if typeDeclarationTypes.contains(parent.type) {
                if isLocalClass(parent) || anonymousCreation(declaring: parent) != nil,
                   let synthetic = syntheticByStart[parent.startByte] { return synthetic }
                break
            }
            current = parent.parent
        }
        return realEnclosingQualifiedName(of: node, packageName: packageName)
    }

    private static func realEnclosingQualifiedName(of node: SyntaxNode, packageName: String) -> String {
        var simples: [String] = []
        var current = node.parent
        while let parent = current {
            if typeDeclarationTypes.contains(parent.type), !isLocalClass(parent),
               let name = parent.child(byFieldName: "name")?.text {
                simples.append(name)
            }
            current = parent.parent
        }
        simples.reverse()
        let body = simples.joined(separator: ".")
        if packageName.isEmpty { return body }
        if body.isEmpty { return packageName }
        return "\(packageName).\(body)"
    }

    /// Enclosing types at `offset`, innermost first, with local classes written as their synthetic names.
    private static func enclosingQualifiedNames(
        in tree: JavaSyntaxTree, atByteOffset offset: Int, packageName: String, syntheticByStart: [Int: String]
    ) -> [String] {
        var nodes: [SyntaxNode] = []
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            if typeDeclarationTypes.contains(node.type) { nodes.append(node) }
            current = node.parent
        }
        var prefix = packageName
        var outerFirst: [String] = []
        for node in nodes.reversed() {
            guard let simple = node.child(byFieldName: "name")?.text else { continue }
            if isLocalClass(node) || anonymousCreation(declaring: node) != nil, let synthetic = syntheticByStart[node.startByte] {
                prefix = synthetic
            } else {
                prefix = prefix.isEmpty ? simple : "\(prefix).\(simple)"
            }
            outerFirst.append(prefix)
        }
        return outerFirst.reversed()
    }

    /// FNV-1a: stable across runs, unlike `Hashable`.
    private static func fingerprint(of text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
