import EditorIntelligence
import Foundation

enum JavaClassFileNameInspection {
    static func inspect(context: JavaInspectionContext) -> [JavaInspection] {
        guard context.url.pathExtension.lowercased() == "java" else { return [] }
        let expected = context.url.deletingPathExtension().lastPathComponent
        guard let topLevel = context.file.classes.first(where: { $0.outerQualifiedName == nil && $0.modifiers.contains(.publicFlag) }) else {
            return []
        }
        guard topLevel.simpleName != expected else { return [] }
        guard let nameNode = context.tree.rootNode.namedChildren.first(where: { node in
            ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"].contains(node.type)
        })?.child(byFieldName: "name") else { return [] }
        let start = JavaImportInserter.textPosition(forByteOffset: nameNode.startByte, in: context.tree.sourceBytes)
        let end = JavaImportInserter.textPosition(forByteOffset: nameNode.endByte, in: context.tree.sourceBytes)
        return [JavaInspection(
            id: "class-file-name-mismatch",
            message: "Public type '\(topLevel.simpleName)' should be declared in '\(topLevel.simpleName).java'",
            severity: .warning,
            range: EditorIntelligence.TextRange(start: start, end: end)
        )]
    }
}
