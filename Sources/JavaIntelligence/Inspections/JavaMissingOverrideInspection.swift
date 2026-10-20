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
        for typeNode in typeNodes(in: parsedTree.rootNode) {
            guard let typeName = enclosingTypeName(of: typeNode, file: file) else { continue }
            for methodNode in methodDeclarations(in: typeNode) {
                guard let nameNode = methodNode.child(byFieldName: "name") else { continue }
                // A static or private method can only hide or shadow, and `@Override` on it is a compile error.
                guard !methodNode.hasModifier("static"), !methodNode.hasModifier("private") else { continue }
                let name = nameNode.text
                let keys = JavaTypeKeys.keys(of: methodNode)
                guard await shouldOverride(name: name, keys: keys, in: typeName, package: file.packageName, index: index) else { continue }
                guard !hasOverrideModifier(methodNode) else { continue }
                let start = JavaImportInserter.textPosition(forByteOffset: methodNode.startByte, in: parsedTree.sourceBytes)
                let end = JavaImportInserter.textPosition(forByteOffset: nameNode.endByte, in: parsedTree.sourceBytes)
                inspections.append(JavaInspection(
                    id: "missing-override",
                    message: "Method '\(name)' overrides a supertype method but lacks @Override",
                    severity: .warning,
                    range: EditorIntelligence.TextRange(start: start, end: end),
                    fixTitle: "Add @Override"
                ))
            }
        }
        return inspections
    }

    private static func typeNodes(in root: SyntaxNode) -> [SyntaxNode] {
        let types = ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"]
        var stack = [root]
        var nodes: [SyntaxNode] = []
        while let node = stack.popLast() {
            if types.contains(node.type) { nodes.append(node) }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return nodes
    }

    /// The type's own methods. Nested types are inspected as types of their own, and an anonymous class's
    /// methods belong to the anonymous class, so neither is reached through a method body or a member type.
    private static func methodDeclarations(in typeNode: SyntaxNode) -> [SyntaxNode] {
        guard let body = typeNode.child(byFieldName: "body") else { return [] }
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

    private static func enclosingTypeName(of typeNode: SyntaxNode, file: JavaSourceFileStubs) -> String? {
        guard let nameNode = typeNode.child(byFieldName: "name") else { return nil }
        let simple = nameNode.text
        if let outer = outerQualifiedName(of: typeNode) {
            return outer + "." + simple
        }
        if !file.packageName.isEmpty { return file.packageName + "." + simple }
        return simple
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

    private static func shouldOverride(name: String, keys: [String], in typeName: String, package typePackage: String, index: JavaIndex) async -> Bool {
        var superNames = await JavaMemberLookup.supertypeClosure(of: typeName, index: index)
        superNames.remove(typeName)
        for superName in superNames {
            guard let stub = await index.classStub(qualifiedName: superName) else { continue }
            let overridable = stub.methods.contains { method in
                guard method.name == name, !method.isConstructor, JavaTypeKeys.keys(of: method) == keys else { return false }
                if method.modifiers.contains(.staticFlag) || method.modifiers.contains(.privateFlag) || method.modifiers.contains(.synthetic) { return false }
                // A package-private method is only overridden from the same package.
                if method.modifiers.isPackagePrivate, stub.kind != .interfaceKind, stub.packageName != typePackage { return false }
                return true
            }
            if overridable { return true }
        }
        return false
    }
}
