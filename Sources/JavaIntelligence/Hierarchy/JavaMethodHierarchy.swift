import EditorIntelligence
import Foundation

/// What a class does with the method a hierarchy is about.
public enum JavaMethodHierarchyStatus: String, Sendable {
    /// Declares the method (the first declaration, or an override).
    case defines
    /// Declares nothing of its own: the method comes from a superclass or interface.
    case inherits
    /// A concrete class whose nearest declaration is abstract and which does not implement it.
    case shouldDefine
}

/// The method a hierarchy is about, and the classes that declare it.
public struct JavaMethodHierarchySubject: Sendable, Hashable {
    /// `speak(int)`: name and the written parameter types.
    public let displayName: String
    public let name: String
    /// The class the hierarchy was asked from.
    public let currentClass: String
    /// Every class that declares the method (the topmost declaration, its overrides and the
    /// project methods that override them), by qualified name; the value says whether that
    /// declaration is abstract.
    public let declaringClasses: [String: Bool]
}

/// One class in a method hierarchy.
public struct JavaMethodHierarchyNode: Identifiable, Hashable, Sendable {
    public var id: String { type.id }
    public let type: JavaTypeHierarchyNode
    public let status: JavaMethodHierarchyStatus
    public let isCurrent: Bool
    public let subject: JavaMethodHierarchySubject
}

/// The hierarchy of one method (IntelliJ's Method Hierarchy): the classes from the topmost one that
/// declares it, down through its subtypes, each marked by what it does with the method. It is the
/// type hierarchy of those classes plus the method's family (``JavaMethodFamily``), so it expands
/// lazily like it and is as costly: a subtype expansion scans the project.
public struct JavaMethodHierarchyProvider: Sendable {
    private let typeHierarchy: JavaTypeHierarchyProvider
    private let index: JavaIndex

    public init(typeHierarchy: JavaTypeHierarchyProvider) {
        self.typeHierarchy = typeHierarchy
        self.index = typeHierarchy.index
    }

    // MARK: - Root

    /// The topmost class that declares the method at the caret (a declaration, or a call), marked
    /// as the root of its tree. `nil` when the caret is not on a method.
    public func rootNode(source: String, fileURL: URL?, utf16Offset: Int) async -> JavaMethodHierarchyNode? {
        guard let found = await typeHierarchy.methodAtCaret(source: source, fileURL: fileURL, utf16Offset: utf16Offset) else {
            return nil
        }
        let index = self.index
        let owner = found.owner
        let method = found.method
        return await typeHierarchy.scoped(fileURL) {
            let family = await JavaMethodFamily.family(of: method, declaringClass: owner, index: index)
            var declaring: [String: Bool] = [:]
            for member in family {
                let abstract = Self.isAbstract(member.method, ownerKind: await index.classStub(qualifiedName: member.declaringClass)?.kind)
                declaring[member.declaringClass] = abstract
            }
            let subject = JavaMethodHierarchySubject(
                displayName: Self.displayName(of: method), name: method.name, currentClass: owner, declaringClasses: declaring
            )
            guard let top = await Self.topmost(of: Set(declaring.keys), asSeenFrom: owner, index: index),
                  let stub = await index.classStub(qualifiedName: top) else { return nil }
            return await Self.makeNode(
                index: index, type: JavaTypeHierarchyProvider.node(for: stub, path: [top]), subject: subject, ancestors: []
            )
        }
    }

    // MARK: - Children

    public func subtypes(
        of node: JavaMethodHierarchyNode, file: URL?, scope: HierarchyScope = .all
    ) async -> [JavaMethodHierarchyNode] {
        var result: [JavaMethodHierarchyNode] = []
        for child in await typeHierarchy.subtypes(of: node.type, file: file, scope: scope) {
            result.append(await Self.makeNode(index: index, type: child, subject: node.subject, ancestors: node.type.path))
        }
        return result
    }

    public func supertypes(of node: JavaMethodHierarchyNode, file: URL?) async -> [JavaMethodHierarchyNode] {
        var result: [JavaMethodHierarchyNode] = []
        // Going up starts a path of its own: the classes above a node are in its downward path,
        // which would otherwise read as a cycle.
        var upward = node.type
        if let stub = await index.classStub(qualifiedName: node.type.qualifiedName) {
            upward = JavaTypeHierarchyProvider.node(for: stub, path: [node.type.qualifiedName])
        }
        for parent in await typeHierarchy.supertypes(of: upward, file: file) {
            // Going up, a class is judged by itself: it declares the method or it does not.
            result.append(await Self.makeNode(index: index, type: parent, subject: node.subject, ancestors: []))
        }
        return result
    }

    public func location(of node: JavaMethodHierarchyNode, file: URL?) async -> JavaTypeHierarchyLocation? {
        await typeHierarchy.location(of: node.type, file: file)
    }

    // MARK: - Status

    /// The status of `type`, given the classes above it on the way from the root (`ancestors`).
    /// A class that declares the method defines it; otherwise the nearest ancestor that does decides
    /// whether a concrete class is missing an implementation.
    static func status(
        of type: JavaTypeHierarchyNode, isAbstractClass: Bool, subject: JavaMethodHierarchySubject, ancestors: [String]
    ) -> JavaMethodHierarchyStatus {
        if subject.declaringClasses[type.qualifiedName] != nil { return .defines }
        guard type.kind != .interfaceKind, type.kind != .annotationKind, !isAbstractClass,
              let nearest = ancestors.last(where: { subject.declaringClasses[$0] != nil }),
              subject.declaringClasses[nearest] == true else { return .inherits }
        return .shouldDefine
    }

    private static func makeNode(
        index: JavaIndex, type: JavaTypeHierarchyNode, subject: JavaMethodHierarchySubject, ancestors: [String]
    ) async -> JavaMethodHierarchyNode {
        let isAbstractClass = await index.classStub(qualifiedName: type.qualifiedName)?.modifiers.contains(.abstractFlag) ?? false
        return JavaMethodHierarchyNode(
            type: type,
            status: status(of: type, isAbstractClass: isAbstractClass, subject: subject, ancestors: ancestors),
            isCurrent: type.qualifiedName == subject.currentClass,
            subject: subject
        )
    }

    // MARK: - Helpers

    /// The declaring class no other declaring class is above, preferring one `asSeenFrom` inherits
    /// from; ties go to the lowest name so the choice is stable.
    private static func topmost(of declaring: Set<String>, asSeenFrom owner: String, index: JavaIndex) async -> String? {
        let ownerClosure = await JavaMemberLookup.supertypeClosure(of: owner, index: index)
        var candidates: [String] = []
        for name in declaring.sorted() where name == owner || ownerClosure.contains(name) {
            let closure = await JavaMemberLookup.supertypeClosure(of: name, index: index)
            if !declaring.contains(where: { $0 != name && closure.contains($0) }) {
                candidates.append(name)
            }
        }
        return candidates.first ?? (declaring.contains(owner) ? owner : declaring.sorted().first)
    }

    private static func isAbstract(_ method: JavaMethodStub, ownerKind: JavaTypeKind?) -> Bool {
        method.modifiers.contains(.abstractFlag)
            || (ownerKind == .interfaceKind && !method.modifiers.contains(.defaultMethod)
                && !method.modifiers.contains(.staticFlag) && !method.modifiers.contains(.privateFlag))
    }

    private static func displayName(of method: JavaMethodStub) -> String {
        method.name + method.parameterListDisplay
    }
}

extension JavaTypeHierarchyProvider {
    /// The method the caret is on, as the class that declares it and its stub: a call is resolved,
    /// a declaration (or anywhere in its body) is itself. `nil` for a constructor, an anonymous
    /// class's method, or anything that is not a method.
    func methodAtCaret(source: String, fileURL: URL?, utf16Offset: Int) async -> (owner: String, method: JavaMethodStub)? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        let session = makeSession(source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset)
        return await scoped(fileURL) { await session.methodAtCaret() }
    }
}

extension JavaNavigationSession {
    /// The method the caret is on: the one a call names, else the declaration the caret is inside.
    func methodAtCaret() async -> (owner: String, method: JavaMethodStub)? {
        let leaf = tree.node(atByteOffset: byteOffset)
        if leaf.type == "identifier", let invocation = leaf.parent, invocation.type == "method_invocation",
           invocation.child(byFieldName: "name")?.byteRange == leaf.byteRange,
           let target = await methodCallTargets(invocation).first {
            return (target.declaringClass, target.method)
        }
        var node: SyntaxNode? = leaf
        while let current = node {
            if current.type == "method_declaration" { return await declaredMethod(current) }
            if current.type == "class_declaration" || current.type == "interface_declaration"
                || current.type == "enum_declaration" || current.type == "record_declaration" {
                return nil
            }
            node = current.parent
        }
        return nil
    }

    /// The class and stub a `method_declaration` of the buffer stands for.
    func declaredMethod(_ declaration: SyntaxNode) async -> (owner: String, method: JavaMethodStub)? {
        if let body = declaration.parent, let parent = body.parent,
           parent.type == "object_creation_expression" || parent.type == "enum_constant" {
            return nil
        }
        guard let owner = context.enclosingTypeQualifiedNames.first,
              let name = declaration.child(byFieldName: "name")?.text,
              let stub = await liveStub(owner) else { return nil }
        let arity = declaration.child(byFieldName: "parameters")?.namedChildCount ?? 0
        let sameArity = stub.methods.filter { $0.name == name && !$0.isConstructor && $0.parameters.count == arity }
        let written = Self.parameterKeys(of: declaration)
        let exact = sameArity.filter { JavaTypeKeys.keys(of: $0) == written }
        guard let method = (exact.isEmpty ? sameArity : exact).first else { return nil }
        return (owner, method)
    }
}
