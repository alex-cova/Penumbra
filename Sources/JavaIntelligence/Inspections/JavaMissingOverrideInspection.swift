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
                let name = nameNode.text
                let keys = JavaTypeKeys.keys(of: methodNode)
                guard await shouldOverride(name: name, keys: keys, in: typeName, index: index) else { continue }
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

    private static func methodDeclarations(in typeNode: SyntaxNode) -> [SyntaxNode] {
        guard let body = typeNode.child(byFieldName: "body") else { return [] }
        var stack = [body]
        var methods: [SyntaxNode] = []
        while let node = stack.popLast() {
            if node.type == "method_declaration" { methods.append(node) }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
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
        if let modifiers = methodNode.child(byFieldName: "modifiers"), modifiers.text.contains("@Override") {
            return true
        }
        return false
    }

    private static func shouldOverride(name: String, keys: [String], in typeName: String, index: JavaIndex) async -> Bool {
        for superName in await JavaMemberLookup.directSupertypeNames(of: typeName, index: index) {
            guard let stub = await index.classStub(qualifiedName: superName) else { continue }
            if stub.methods.contains(where: { $0.name == name && JavaTypeKeys.keys(of: $0) == keys }) {
                return true
            }
        }
        return false
    }
}
