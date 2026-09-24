import EditorIntelligence
import Foundation

enum JavaUnresolvedTypeInspection {
    static func inspect(source: String, url: URL?, index: JavaIndex, walker: JavaSemanticWalker) async -> [JavaInspection] {
        let file = JavaSourceStubBuilder.build(tree: walker.syntaxTree, url: url ?? JavaNavigationSession.placeholderURL)
        var inspections: [JavaInspection] = []
        for name in walker.undeclaredTypeNames.sorted() {
            let candidates = await index.classes(simpleNamePrefix: name, limit: 50).filter { $0.simpleName == name }
            guard candidates.isEmpty || candidates.allSatisfy({ !isImportable($0, from: file.packageName) }) else { continue }
            guard let range = firstTypeReference(to: name, in: walker.syntaxTree) else { continue }
            let start = JavaImportInserter.textPosition(forByteOffset: range.lowerBound, in: walker.syntaxTree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: range.upperBound, in: walker.syntaxTree.sourceBytes)
            inspections.append(JavaInspection(
                id: "unresolved-type",
                message: "Cannot resolve type '\(name)'",
                severity: .warning,
                range: EditorIntelligence.TextRange(start: start, end: end),
                fixTitle: candidates.count == 1 ? "Import '\(candidates[0].qualifiedName)'" : nil
            ))
        }
        return inspections
    }

    private static func isImportable(_ stub: JavaClassStub, from packageName: String) -> Bool {
        stub.packageName != packageName && !stub.qualifiedName.hasPrefix("java.lang.")
    }

    private static func firstTypeReference(to name: String, in tree: JavaSyntaxTree) -> Range<Int>? {
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "type_identifier", node.text == name { return node.byteRange }
            if node.type == "scoped_type_identifier", node.text.hasSuffix(name), node.text.hasSuffix("." + name) || node.text == name {
                return node.byteRange
            }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return nil
    }
}
