import EditorIntelligence
import Foundation

enum JavaDuplicateThrowsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.duplicateThrows
    static let nodeTypes: Set<String> = ["throws"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        var seen = Set<String>()
        for exception in node.namedChildren where !seen.insert(exception.text).inserted {
            report(JavaInspectionSupport.inspection(rule, message: "Duplicate exception '\(exception.text)' in throws list", node: exception, fixTitle: "Remove duplicate"))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        for type in ["type_identifier", "scoped_type_identifier"] {
            guard let node = JavaInspectionSupport.node(of: type, for: diagnostic, tree: tree, source: source),
                  let previous = node.previousNamedSibling else { continue }
            let edit = JavaInspectionSupport.edit(replacingBytes: previous.endByte..<node.endByte, with: "", in: tree)
            return [CodeAction(title: "Remove duplicate", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        return []
    }
}

enum JavaEmptyClassInitializerInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptyClassInitializer
    static let nodeTypes: Set<String> = ["block", "static_initializer"]
    private static let initializerParents: Set<String> = ["class_body", "enum_body_declarations"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let isEmpty: Bool
        switch node.type {
        case "block": isEmpty = node.parent.map { initializerParents.contains($0.type) } == true && node.namedChildCount == 0
        default: isEmpty = node.firstNamedChild(ofType: "block")?.namedChildCount == 0
        }
        guard isEmpty else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Empty class initializer", node: node, fixTitle: "Remove initializer"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        for type in nodeTypes {
            guard let node = JavaInspectionSupport.node(of: type, for: diagnostic, tree: tree, source: source) else { continue }
            return JavaJumpStatements.removeFix(title: "Remove initializer", node: node, in: tree)
        }
        return []
    }
}
