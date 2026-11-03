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
    /// Appears in every synthetic name; the member-set cache must not hold such a type.
    static let marker = "$Anonymous"

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
        // The name comes from the text, not the position: a `var` initializer is typed from a
        // re-parse of its own text, where the same expression sits at another offset.
        let owner = context.topLevelTypeQualifiedName ?? (context.packageName.isEmpty ? "" : context.packageName)
        let qualifiedName = "\(owner).\(marker)\(fingerprint(of: creation.text))"
        if let existing = registry.stub(named: qualifiedName) { return existing }

        let resolved = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: context, index: index)
        guard case .classType(let superName, _, _) = resolved else { return nil }
        let isInterface = await index.classStub(qualifiedName: superName)?.kind == .interfaceKind
        let stub = JavaSourceStubBuilder.anonymousStub(
            body: body, qualifiedName: qualifiedName, supertype: resolved, supertypeIsInterface: isInterface,
            packageName: context.packageName, url: registry.fileURL, nameRange: typeNode.byteRange
        )
        registry.register(stub)
        return stub
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
