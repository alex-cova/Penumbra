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

enum JavaRedundantCloseInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantClose
    static let nodeTypes: Set<String> = ["try_with_resources_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let call = closeCall(in: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Redundant 'close()': the resource is closed automatically", node: call, fixTitle: "Remove 'close()'"
        ))
    }

    /// `name.close();` as the last statement of the body, where `name` is one of the resources.
    private static func closeCall(in node: SyntaxNode) -> SyntaxNode? {
        guard let resources = node.child(byFieldName: "resources"), let body = node.child(byFieldName: "body"),
              let last = body.namedChildren.last(where: { !["line_comment", "block_comment"].contains($0.type) }),
              last.type == "expression_statement", let call = last.namedChild(at: 0), call.type == "method_invocation",
              call.child(byFieldName: "name")?.text == "close", call.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = call.child(byFieldName: "object"), object.type == "identifier" else { return nil }
        let names = resources.namedChildren(ofType: "resource").compactMap { $0.child(byFieldName: "name")?.text }
        return names.contains(object.text) ? last : nil
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let statement = JavaInspectionSupport.node(of: "expression_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaJumpStatements.removeFix(title: "Remove 'close()'", node: statement, in: tree)
    }
}
